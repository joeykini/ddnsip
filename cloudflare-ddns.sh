#!/bin/sh
(
    set -eu
    cf_ddns_uid=$(id -u)
    cf_ddns_run() {
        if [ "$cf_ddns_uid" -eq 0 ]; then
            "$@"
        else
            sudo -- "$@"
        fi
    }
    if ! command -v python3 >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            cf_ddns_run apt-get update
            cf_ddns_run env DEBIAN_FRONTEND=noninteractive apt-get install -y python3 ca-certificates
        elif command -v dnf >/dev/null 2>&1; then
            cf_ddns_run dnf install -y python3 ca-certificates
        elif command -v yum >/dev/null 2>&1; then
            cf_ddns_run yum install -y python3 ca-certificates
        else
            printf '%s\n' '请先用系统包管理器安装 Python 3。' >&2
            exit 1
        fi
    fi
    if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 6))'; then
        printf '%s\n' '需要 Python 3.6 或更新版本。' >&2
        exit 1
    fi

    umask 077
    cf_ddns_installer=$(mktemp)
    trap 'rm -f "$cf_ddns_installer"' 0
    cat > "$cf_ddns_installer" <<'DDNS_PYTHON'
#!/usr/bin/env python3
import fcntl
import getpass
import http.client
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from contextlib import closing, contextmanager
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import ProxyHandler, build_opener


STATE_DIR = Path("/etc/cloudflare-ddns")
UNIT_DIR = Path("/etc/systemd/system")
SYSTEMD_RUNTIME = Path("/run/systemd/system")
PROGRAM = Path("/usr/local/sbin/cloudflare-ddns")
SERVICE = "cloudflare-ddns.service"
TIMER = "cloudflare-ddns.timer"


class DDNSError(Exception):
    pass


def hostname_from_input(value):
    try:
        name = value.strip().encode("idna").decode("ascii").lower()
    except UnicodeError:
        raise DDNSError("请输入完整域名，例如 node.example.com。") from None
    if name.endswith("."):
        name = name[:-1]
    labels = name.split(".")
    if (
        len(name) > 253
        or len(labels) < 2
        or not all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", part) for part in labels)
        or labels[-1].isdigit()
    ):
        raise DDNSError("请输入完整域名，例如 node.example.com。")
    return name


def public_ipv4(value):
    address = ipaddress.IPv4Address(value.strip())
    if not address.is_global or address.is_multicast:
        raise ValueError("not a public unicast IPv4 address")
    return str(address)


def ec2_ipv4():
    with closing(http.client.HTTPConnection("169.254.169.254", timeout=2)) as connection:
        connection.request(
            "PUT", "/latest/api/token", headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"}
        )
        response = connection.getresponse()
        if response.status != 200:
            raise ValueError("IMDSv2 is unavailable")
        token = response.read(4096).decode("ascii").strip()

        connection.request(
            "GET", "/latest/meta-data/public-ipv4", headers={"X-aws-ec2-metadata-token": token}
        )
        response = connection.getresponse()
        if response.status != 200:
            raise ValueError("instance has no public IPv4 in metadata")
        return public_ipv4(response.read(64).decode("ascii"))


def current_ipv4():
    try:
        return ec2_ipv4(), "EC2 实例公网 IPv4"
    except (OSError, ValueError, http.client.HTTPException):
        pass

    try:
        opener = build_opener(ProxyHandler({}))
        with opener.open("https://api.ipify.org", timeout=8) as response:
            return public_ipv4(response.read(64).decode("ascii")), "公网出口 IPv4"
    except (OSError, ValueError, http.client.HTTPException):
        raise DDNSError("无法取得有效的公网 IPv4，检查实例网络后重试。") from None


def cf_request(token, method, path, query=None, data=None):
    if query:
        path += "?" + urlencode(query)
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    body = None
    if data is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(data).encode("utf-8")

    try:
        with closing(http.client.HTTPSConnection("api.cloudflare.com", timeout=12)) as connection:
            connection.request(method, "/client/v4" + path, body=body, headers=headers)
            response = connection.getresponse()
            status = response.status
            raw = response.read()
    except (OSError, http.client.HTTPException):
        raise DDNSError("无法连接 Cloudflare API，检查服务器网络后重试。") from None

    try:
        result = json.loads(raw)
    except (ValueError, UnicodeError):
        raise DDNSError(f"Cloudflare API 返回了无法解析的响应（HTTP {status}）。") from None
    if not isinstance(result, dict):
        raise DDNSError("Cloudflare API 返回了无法识别的响应。")
    if status >= 300 or result.get("success") is not True:
        codes = [
            str(error["code"]) for error in result.get("errors") or []
            if isinstance(error, dict) and isinstance(error.get("code"), int)
        ]
        detail = f"，错误码 {', '.join(codes)}" if codes else ""
        if status in (401, 403):
            raise DDNSError(f"Cloudflare 授权失败（HTTP {status}{detail}），请检查 Token 和域名权限。")
        raise DDNSError(f"Cloudflare DNS 请求失败（HTTP {status}{detail}）。")
    return result


def list_entries(token, path, filters):
    page = 1
    while True:
        response = cf_request(token, "GET", path, {**filters, "page": page, "per_page": 50})
        entries = response.get("result")
        if not isinstance(entries, list) or any(not isinstance(entry, dict) for entry in entries):
            raise DDNSError("Cloudflare API 返回了无法识别的记录列表。")
        yield from entries
        pages = (response.get("result_info") or {}).get("total_pages")
        if not entries or (isinstance(pages, int) and page >= pages):
            return
        if pages is None and len(entries) < 50:
            return
        page += 1


def cloudflare_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{32}", value, re.I):
        raise DDNSError("Cloudflare API 返回了无效的记录或 Zone ID。")
    return value


def find_zone(token, hostname):
    labels = hostname.split(".")
    for start in range(len(labels) - 1):
        candidate = ".".join(labels[start:])
        zones = [
            zone for zone in list_entries(token, "/zones", {"name": candidate, "status": "active"})
            if zone.get("name", "").lower() == candidate
        ]
        if len(zones) > 1:
            raise DDNSError("找到多个同名 Zone。请使用仅授权目标 Zone 的 API Token。")
        if zones:
            return cloudflare_id(zones[0].get("id")), candidate
    raise DDNSError("找不到该域名所属的 Cloudflare Zone，请检查域名和 Zone Read 权限。")


def sync_record(config):
    token, zone_id, name = config["token"], config["zone_id"], config["hostname"]
    endpoint = f"/zones/{cloudflare_id(zone_id)}/dns_records"
    entries = [
        record for record in list_entries(token, endpoint, {"name.exact": name})
        if record.get("name", "").lower() == name
    ]
    if any(record.get("type") in ("CNAME", "NS") for record in entries):
        raise DDNSError(f"{name} 有同名 CNAME 或 NS 记录，请选择用于 DDNS 的 A 记录域名。")
    records = [record for record in entries if record.get("type") == "A"]
    if len(records) > 1:
        raise DDNSError(f"{name} 有多条同名 A 记录，请选择只有一条 A 记录的域名。")

    ip, source = current_ipv4()
    if records and records[0].get("content") == ip:
        print(f"{name} 已指向 {ip}（{source}）。", flush=True)
        return

    payload = {"type": "A", "name": name, "content": ip}
    if records:
        record = records[0]
        payload["ttl"] = record["ttl"]
        if "proxied" in record:
            payload["proxied"] = record["proxied"]
        record_id = cloudflare_id(record.get("id"))
        cf_request(token, "PATCH", f"{endpoint}/{record_id}", data=payload)
        print(f"{name} 已更新为 {ip}（{source}）。", flush=True)
    else:
        cf_request(token, "POST", endpoint, data={**payload, "ttl": 1, "proxied": False})
        print(f"已创建 {name} → {ip}（{source}）。", flush=True)


def read_config():
    with (STATE_DIR / "config.json").open(encoding="utf-8") as handle:
        return json.load(handle)


def write_file(path, content, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=path.parent) as staging_dir:
        staging = Path(staging_dir) / path.name
        staging.write_text(content, encoding="utf-8")
        staging.chmod(mode)
        staging.replace(path)


@contextmanager
def config_lock():
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (STATE_DIR / "lock").open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def install():
    if not SYSTEMD_RUNTIME.is_dir() or not shutil.which("systemctl"):
        raise DDNSError("请在使用 systemd 的 Linux 主机上运行。")
    if not sys.stdin.isatty():
        raise DDNSError("请在 FinalShell 或其他交互式 SSH 终端中运行。")

    previous = read_config() if (STATE_DIR / "config.json").is_file() else {}
    old_name = previous.get("hostname", "")
    name_prompt = f"完整域名 [{old_name}]：" if old_name else "完整域名（例如 node.example.com）："
    hostname = hostname_from_input(input(name_prompt).strip() or old_name)
    old_token = previous.get("token", "")
    token_prompt = "Cloudflare API Token（回车沿用已有 Token）：" if old_token else "Cloudflare API Token："
    token = getpass.getpass(token_prompt).strip() or old_token
    if not re.fullmatch(r"[A-Za-z0-9._~+/=-]+", token):
        raise DDNSError("请输入有效的 Cloudflare API Token。")

    zone_id, zone_name = find_zone(token, hostname)
    config = {"hostname": hostname, "zone_id": zone_id, "token": token}
    print(f"Cloudflare Zone：{zone_name}", flush=True)

    interpreter = sys.executable.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")
    service = f"""[Unit]
Description=Update Cloudflare DDNS record
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=PYTHONIOENCODING=utf-8
ExecStart="{interpreter}" {PROGRAM} update
TimeoutStartSec=90
"""
    timer = f"""[Unit]
Description=Refresh Cloudflare DDNS every minute

[Timer]
OnActiveSec=1min
OnUnitInactiveSec=1min
AccuracySec=1s
Unit={SERVICE}

[Install]
WantedBy=timers.target
"""
    with config_lock():
        sync_record(config)
        write_file(PROGRAM, Path(__file__).read_text(encoding="utf-8"), 0o755)
        write_file(UNIT_DIR / SERVICE, service, 0o644)
        write_file(UNIT_DIR / TIMER, timer, 0o644)
        write_file(STATE_DIR / "config.json", json.dumps(config) + "\n", 0o600)
        try:
            subprocess.run(["systemctl", "daemon-reload"], check=True)
            subprocess.run(["systemctl", "enable", "--now", TIMER], check=True)
        except subprocess.CalledProcessError:
            raise DDNSError("DNS 已同步，定时器启动失败。修复 systemd 后可重新运行安装。") from None

    print("DDNS 已安装，每分钟检查一次。日志可用 journalctl -u cloudflare-ddns.service 查看。")


def main():
    if os.geteuid() != 0:
        raise DDNSError("请用 root 或 sudo 运行。")
    os.umask(0o077)
    if sys.argv[1:] == ["install"]:
        install()
    elif sys.argv[1:] == ["update"]:
        with config_lock():
            sync_record(read_config())
    else:
        raise DDNSError("请运行安装脚本，或执行 cloudflare-ddns update 手动同步。")


if __name__ == "__main__":
    try:
        main()
    except (DDNSError, EOFError, KeyboardInterrupt) as error:
        print(f"DDNS：{error or '操作已取消。'}", file=sys.stderr)
        sys.exit(1)
    except (OSError, KeyError, TypeError, ValueError, AttributeError):
        print("DDNS：无法读取配置或保存安装文件，请检查权限与磁盘状态后重试。", file=sys.stderr)
        sys.exit(1)
DDNS_PYTHON

    cf_ddns_run env PYTHONIOENCODING=utf-8 "$(command -v python3)" "$cf_ddns_installer" install < /dev/tty
)
