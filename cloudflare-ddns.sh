#!/bin/sh
(
    set -eu
    case "$#:${1-}" in
        0:) cf_ddns_action=install ;;
        1:--lightsail) cf_ddns_action=install-lightsail ;;
        *)
            printf '%s\n' '用法 sh cloudflare-ddns.sh [--lightsail]' >&2
            exit 2
            ;;
    esac
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
import socket
import subprocess
import sys
import tempfile
import time
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
TCP_FAILURE_LIMIT = 3
TCP_FAILURE_WINDOW = 240
LIGHTSAIL_RESTART_COOLDOWN = 3600
LIGHTSAIL_STOP_WAIT = 900
LIGHTSAIL_START_RETRY_DELAY = 120


class DDNSError(Exception):
    pass


class ZoneLookupError(DDNSError):
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


def list_zones(token, account_id=""):
    filters = {}
    if account_id:
        if not re.fullmatch(r"[0-9a-f]{32}", account_id, re.I):
            raise DDNSError("Cloudflare Account ID 应为 32 位十六进制字符。")
        filters["account.id"] = account_id
    return list(list_entries(token, "/zones", filters))


def find_zone(hostname, zones):
    matches = {}
    for zone in zones:
        name = zone.get("name")
        if not isinstance(name, str):
            continue
        try:
            zone_name = hostname_from_input(name)
        except DDNSError:
            continue
        if hostname == zone_name or hostname.endswith("." + zone_name):
            matches.setdefault(zone_name, []).append(zone)

    if not matches:
        raise ZoneLookupError(
            "当前 Token 可见的 Zone 中找不到该域名。请确认 Token 的资源范围包含目标 Zone，"
            "并授予 Zone Read 权限。"
        )
    zone_name = max(matches, key=len)
    zones = matches[zone_name]
    active = [zone for zone in zones if zone.get("status") == "active"]
    if not active:
        statuses = ", ".join(sorted({str(zone.get("status") or "unknown") for zone in zones}))
        raise DDNSError(f"已找到 Zone {zone_name}，状态为 {statuses}。请在 Cloudflare 确认它已激活。")
    if len(active) > 1:
        raise ZoneLookupError("找到多个同名的 Active Zone。请按 Account ID 缩小查询范围。")
    return cloudflare_id(active[0].get("id")), zone_name


def sync_record(token, target, ip, source):
    zone_id, name = target["zone_id"], target["hostname"]
    endpoint = f"/zones/{cloudflare_id(zone_id)}/dns_records"
    entries = [
        record for record in list_entries(token, endpoint, {"name.exact": name})
        if record.get("name", "").lower() == name
    ]
    if any(record.get("type") in ("CNAME", "NS") for record in entries):
        raise DDNSError("有同名 CNAME 或 NS 记录，请选择用于 DDNS 的 A 记录域名。")
    records = [record for record in entries if record.get("type") == "A"]
    if len(records) > 1:
        raise DDNSError("有多条同名 A 记录，请选择只有一条 A 记录的域名。")

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


def sync_records(config, ip=None, source=None):
    if ip is None:
        ip, source = current_ipv4()
    errors = []
    for target in config["records"]:
        try:
            sync_record(config["token"], target, ip, source)
        except DDNSError as error:
            errors.append(f'{target["hostname"]}：{error}')
    if errors:
        raise DDNSError("\n".join(errors))


def read_config():
    with (STATE_DIR / "config.json").open(encoding="utf-8") as handle:
        config = json.load(handle)
    if "records" not in config:
        config["records"] = [{"hostname": config.pop("hostname"), "zone_id": config.pop("zone_id")}]
    return config


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


def lightsail_request(settings, operation):
    args = [
        settings["aws"], "--region", settings["region"], "--profile", settings["profile"],
        "--output", "json", "--cli-connect-timeout", "5", "--cli-read-timeout", "10",
        "lightsail", operation, "--instance-name", settings["instance_name"],
    ]
    env = {**os.environ, "AWS_PAGER": "", "AWS_CLI_AUTO_PROMPT": "off", "AWS_MAX_ATTEMPTS": "1"}
    try:
        result = subprocess.run(
            args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            encoding="utf-8", env=env, timeout=22,
        )
    except subprocess.TimeoutExpired:
        raise DDNSError(f"Lightsail {operation} 请求超时，请查看实例状态。") from None
    except (OSError, UnicodeError):
        raise DDNSError("无法运行 AWS CLI，请检查探测机上的安装。") from None
    if result.returncode:
        aws_code = re.search(r"An error occurred \(([a-zA-Z0-9_-]+)\)", result.stderr)
        code = f"（{aws_code.group(1)}）" if aws_code else ""
        raise DDNSError(f"Lightsail {operation} 失败{code}，请检查 AWS CLI profile、区域和权限。")
    try:
        response = json.loads(result.stdout)
        if not isinstance(response, dict):
            raise ValueError("unexpected response")
    except ValueError:
        raise DDNSError(f"Lightsail {operation} 返回了无法解析的响应。") from None
    if any(item.get("status") == "Failed" for item in response.get("operations", [])):
        raise DDNSError(f"Lightsail {operation} 报告操作失败，请在 AWS 控制台查看实例状态。")
    return response


def lightsail_instance(settings):
    instance = lightsail_request(settings, "get-instance").get("instance", {})
    arn = instance.get("arn")
    region = re.escape(settings["region"])
    expected_arn = settings.get("instance_arn")
    if (
        not isinstance(arn, str)
        or not re.fullmatch(rf"arn:[a-z0-9-]+:lightsail:{region}:[0-9]{{12}}:Instance/[A-Za-z0-9_-]+", arn)
        or instance.get("name") != settings["instance_name"]
        or (expected_arn and arn != expected_arn)
    ):
        raise DDNSError("Lightsail 实例标识与配置不一致。")
    return instance


def lightsail_ipv4(instance):
    try:
        return public_ipv4(instance.get("publicIpAddress") or "")
    except ValueError:
        raise DDNSError("Lightsail 当前没有可用的公网 IPv4。") from None


def check_observer(address):
    try:
        observer_address, _ = current_ipv4()
    except DDNSError:
        return
    if observer_address == address:
        raise DDNSError("请把 Lightsail 换址任务安装到另一台探测机，目标实例停机后任务仍需运行。")


def tcp_reachable(address, port):
    try:
        with socket.create_connection((address, port), timeout=4):
            return True
    except OSError:
        return False


def prompt_lightsail(previous):
    aws = shutil.which("aws")
    if not aws:
        raise DDNSError("请先在探测机安装 AWS CLI 并配置运行定时任务的 AWS profile。")

    def ask(key, label, default=""):
        default = str(previous.get(key, default))
        prompt = f"{label} [{default}]" if default else label
        return input(prompt + "：").strip() or default

    region = ask("region", "Lightsail AWS Region")
    instance_name = ask("instance_name", "Lightsail 实例名称")
    profile = ask("profile", "AWS CLI profile", "default")
    port = ask("port", "要探测的 TCP 服务端口")
    if not re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-[0-9]+", region):
        raise DDNSError("请输入 AWS Region，例如 ap-northeast-1。")
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_-]*[A-Za-z0-9_]", instance_name):
        raise DDNSError("请输入 Lightsail 控制台中的实例名称。")
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", profile):
        raise DDNSError("请输入有效的 AWS CLI profile 名称。")
    if not re.fullmatch(r"[0-9]{1,5}", port) or not 1 <= int(port) <= 65535:
        raise DDNSError("TCP 端口必须介于 1 和 65535。")

    settings = {
        "aws": aws, "region": region, "instance_name": instance_name,
        "profile": profile, "port": int(port),
    }
    instance = lightsail_instance(settings)
    if instance.get("state", {}).get("name") != "running" or instance.get("isStaticIp") is not False:
        raise DDNSError("启用自动换址需要一台正在运行、使用动态公网 IPv4 的 Lightsail 实例。")
    address = lightsail_ipv4(instance)
    check_observer(address)
    settings["instance_arn"] = instance["arn"]
    print(f"已找到 {instance_name}，当前公网 IPv4 为 {address}。", flush=True)
    return settings, address


def read_lightsail_state(path, settings):
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        state = {}
    if state.get("instance_arn") != settings["instance_arn"]:
        return {"instance_arn": settings["instance_arn"]}
    return state


def start_stopped_lightsail(settings, state, save, now):
    if now - state.get("last_start_attempt", 0) < LIGHTSAIL_START_RETRY_DELAY:
        print("等待 Lightsail 更新上一次启动请求的状态。", flush=True)
        return
    state["last_start_attempt"] = now
    save()
    lightsail_request(settings, "start-instance")
    print("Lightsail 已请求启动，等待新的公网 IPv4。", flush=True)


def update_lightsail(config):
    settings = config["lightsail"]
    instance = lightsail_instance(settings)
    instance_name = settings["instance_name"]
    status = instance.get("state", {}).get("name", "unknown")
    state_path = STATE_DIR / "lightsail-state.json"
    state = read_lightsail_state(state_path, settings)
    now = int(time.time())

    def save():
        write_file(state_path, json.dumps(state) + "\n", 0o600)

    pending_ip = state.get("pending_ip")
    if pending_ip and status == "stopped":
        start_stopped_lightsail(settings, state, save, now)
        return
    if status != "running":
        print(f"Lightsail {instance_name} 当前为 {status}，等待运行。", flush=True)
        return
    address = lightsail_ipv4(instance)
    if pending_ip and address == pending_ip and now - state["last_restart"] < LIGHTSAIL_STOP_WAIT:
        print(f"等待 Lightsail {instance_name} 的公网 IPv4 更新。", flush=True)
        return

    sync_records(config, address, "Lightsail 公网 IPv4")
    if pending_ip:
        if address == pending_ip:
            print(f"Lightsail {instance_name} 仍显示原公网 IPv4。请在 AWS 控制台检查停启操作。", flush=True)
        else:
            print(f"Lightsail {instance_name} 公网 IPv4 已切换为 {address}，DNS 已同步。", flush=True)
        state.pop("pending_ip", None)
        state.pop("last_start_attempt", None)

    port = settings["port"]
    if tcp_reachable(address, port):
        if state.get("failures") or state.get("attempted"):
            state.update(failures=0, attempted=False)
            save()
        print(f"Lightsail TCP {address}:{port} 可连通。", flush=True)
        return

    same_probe = (
        state.get("probe_ip") == address
        and state.get("probe_port") == port
        and 0 <= now - state.get("last_failure", 0) <= TCP_FAILURE_WINDOW
    )
    failures = state.get("failures", 0) + 1 if same_probe else 1
    state.update(probe_ip=address, probe_port=port, last_failure=now, failures=min(failures, TCP_FAILURE_LIMIT))
    save()
    if instance.get("isStaticIp") is not False:
        print("Lightsail 已绑定静态 IP，TCP 探测失败，保留现有地址。", flush=True)
        return
    if failures < TCP_FAILURE_LIMIT:
        print(f"Lightsail TCP {address}:{port} 连续失败 {failures}/{TCP_FAILURE_LIMIT} 次。", flush=True)
        return
    if state.get("attempted") or now - state.get("last_restart", 0) < LIGHTSAIL_RESTART_COOLDOWN:
        print("Lightsail TCP 仍不可达。再次自动换址需要 TCP 恢复且满足停启间隔。", flush=True)
        return

    check_observer(address)
    # Keep enough state to start the instance even if the stop response is lost.
    state.update(pending_ip=address, last_restart=now, attempted=True)
    save()
    print(f"Lightsail {instance_name} 的 TCP {address}:{port} 连续失败，正在请求停机换址。", flush=True)
    lightsail_request(settings, "stop-instance")


def install(enable_lightsail=False):
    if not SYSTEMD_RUNTIME.is_dir() or not shutil.which("systemctl"):
        raise DDNSError("请在使用 systemd 的 Linux 主机上运行。")
    if not sys.stdin.isatty():
        raise DDNSError("请在 FinalShell 或其他交互式 SSH 终端中运行。")

    previous = read_config() if (STATE_DIR / "config.json").is_file() else {}
    old_names = ", ".join(record["hostname"] for record in previous.get("records", []))
    name_prompt = "完整域名（多个用逗号分隔）"
    if old_names:
        name_prompt += f" [{old_names}]"
    value = input(name_prompt + "：").strip() or old_names
    names = [hostname_from_input(name) for name in re.split(r"[,，\s]+", value) if name]
    if not names:
        raise DDNSError("请输入至少一个完整域名。")
    hostnames = list(dict.fromkeys(names))
    old_token = previous.get("token", "")
    token_prompt = "Cloudflare API Token（回车沿用已有 Token）：" if old_token else "Cloudflare API Token："
    token = getpass.getpass(token_prompt).strip() or old_token
    if not re.fullmatch(r"[A-Za-z0-9._~+/=-]+", token):
        raise DDNSError("请输入有效的 Cloudflare API Token。")

    zones = list_zones(token)
    account_zones = None
    records = []
    for hostname in hostnames:
        try:
            zone_id, zone_name = find_zone(hostname, zones)
        except ZoneLookupError as error:
            if account_zones is None:
                print(f"DDNS：{hostname}：{error}", file=sys.stderr, flush=True)
                account_id = input("Cloudflare Account ID（可选，输入后重试，回车退出）：").strip()
                if not account_id:
                    raise DDNSError("确认 Token 的 Zone 权限后可重新运行安装。") from None
                account_zones = list_zones(token, account_id)
            try:
                zone_id, zone_name = find_zone(hostname, account_zones)
            except ZoneLookupError as error:
                raise DDNSError(f"{hostname}：{error}") from None
        records.append({"hostname": hostname, "zone_id": zone_id})
        print(f"{hostname} 的 Cloudflare Zone：{zone_name}", flush=True)
    config = {"token": token, "records": records}
    lightsail_address = None
    if enable_lightsail or previous.get("lightsail"):
        config["lightsail"], lightsail_address = prompt_lightsail(previous.get("lightsail", {}))

    interpreter = sys.executable.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")
    service = f"""[Unit]
Description=Update Cloudflare DDNS records
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=PYTHONIOENCODING=utf-8
ExecStart="{interpreter}" {PROGRAM} update
TimeoutStartSec={max(90, (90 if lightsail_address else 30) + 30 * len(records))}
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
        sync_records(config, lightsail_address, "Lightsail 公网 IPv4")
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
    if sys.argv[1:] in (["install"], ["install-lightsail"]):
        install(enable_lightsail=sys.argv[1] == "install-lightsail")
    elif sys.argv[1:] == ["update"]:
        with config_lock():
            config = read_config()
            if config.get("lightsail"):
                update_lightsail(config)
            else:
                sync_records(config)
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

    cf_ddns_run env PYTHONIOENCODING=utf-8 "$(command -v python3)" "$cf_ddns_installer" "$cf_ddns_action" < /dev/tty
)
