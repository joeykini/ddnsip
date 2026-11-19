# Cloudflare DDNS

这个脚本为一台 AWS 或其他 Linux 服务器维护一条或多条 Cloudflare DNS A 记录。运行需要 systemd、Python 3.6 或更新版本，以及 root 或 sudo 权限。若缺少 Python，安装脚本会尝试使用 apt、dnf 或 yum 安装。

## 安装

在 Cloudflare 创建用户或账户级 API Token，把资源范围设为所有要更新的域名所属的 Zone，授予 **Zone → Zone → Read** 和 **Zone → DNS → Edit** 权限。安装时根据完整域名查找 Zone，支持中文域名和 Punycode。自动查找失败时，可以输入 Account ID 按账户重试。

在新机器的 FinalShell 终端运行这一条命令。

```bash
curl -fsSL --retry 3 https://raw.githubusercontent.com/joeykini/ddnsip/main/cloudflare-ddns.sh -o cloudflare-ddns.sh && sh cloudflare-ddns.sh
```

按提示输入完整域名和 API Token。多个域名填在一行，用逗号分隔，例如 `node.example.com,node.example.net`。同一台机器上的域名共用一个 Token 和一个定时器。Token 输入时隐藏。也可以单独下载 `cloudflare-ddns.sh`，上传到服务器再执行。

```bash
sh cloudflare-ddns.sh
```

脚本优先从 EC2 IMDSv2 读取实例公网 IPv4，否则使用检测到的公网出口 IPv4。同名 A 记录会更新为当前地址，并沿用它的 TTL 和 Cloudflare 代理设置。无同名 A 记录时会创建 DNS only 记录，TTL 设为 Auto。已有记录可以是任意地址，`1.1.1.1` 只是文章里的占位值。

安装时会同步一次 DNS，并启用每分钟检查的 systemd 定时器。每次检查只检测一次当前 IPv4，并逐条更新域名。Token 存在服务器的 `/etc/cloudflare-ddns/config.json` 中，文件权限为 `0600`。

给已安装的机器加域名时，重新运行安装脚本，把原域名和新域名一起填入。域名和 Token 的提示都支持回车沿用当前值。旧版的单域名设置会自动读取。

## 换机和检查

换机复用同一域名时，先停止旧机器上的更新任务，再在新机器运行安装脚本。

```bash
sudo systemctl disable --now cloudflare-ddns.timer
sudo systemctl stop cloudflare-ddns.service
```

在新机器上可以查看定时器和日志，或手动同步一次。

```bash
systemctl list-timers cloudflare-ddns.timer
sudo journalctl -u cloudflare-ddns.service -n 30 --no-pager
sudo /usr/local/sbin/cloudflare-ddns update
```

如果实例只有共享的 NAT 出口，DNS 会指向检测到的出口地址，入站访问还需要可用的公网端口转发。
