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

如果只是让域名跟随 Lightsail 的公网 IPv4，在 Lightsail 本机运行上面的普通安装命令即可。安装会启用开机自启的 DDNS 定时器。从 AWS 控制台停机并重新启动后，定时器会检测新的公网 IPv4 并更新域名。

## Lightsail TCP 探测与动态 IPv4 换址

在一台独立的 Linux 探测机上运行。选择和目标用户网络条件相近的探测点，探测 Lightsail 实际对外服务的 TCP 端口。连接失败表示该探测点到端口不可达，可能与应用监听、防火墙或线路有关。该流程适用于使用动态公网 IPv4 的 Lightsail 实例。停机和重新启动期间，实例上的服务会中断。 [Lightsail 公网地址](https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-public-ip-and-private-ip-addresses-in-amazon-lightsail.html)

1. 在探测机安装 AWS CLI，配置 root 可用的凭证，并在 profile 中保存目标 Lightsail 的区域。IAM 中为 `lightsail:GetInstance` 使用 `Resource: "*"`，为 `lightsail:StopInstance` 和 `lightsail:StartInstance` 使用目标实例的 ARN。给 `lightsail:GetInstances` 授予 `Resource: "*"` 可让安装脚本按现有 A 记录自动匹配实例。 [AWS CLI profile](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html) · [Lightsail IAM 权限](https://docs.aws.amazon.com/service-authorization/latest/reference/list_lightsail.html)
2. 如果原来在 Lightsail 上有相同域名的 DDNS 定时器，按下面的换机步骤停止它，把 DNS 更新交给探测机。
3. 在探测机的 FinalShell 终端执行安装命令，输入域名和 Cloudflare Token。按提示确认 TCP 端口。若业务用 `443/TCP` 且当前探测可连通，直接回车。

```bash
curl -fsSL --retry 3 https://raw.githubusercontent.com/joeykini/ddnsip/main/cloudflare-ddns.sh -o cloudflare-ddns.sh && sh cloudflare-ddns.sh --lightsail
```

可以用 `sudo -H aws configure --profile lightsail-ddns` 创建探测机上的 profile。脚本自动采用已选定或唯一的 profile，并读取已配置的 Region。如果 Cloudflare A 记录的实际 IPv4 能匹配该区域的一台 Lightsail，实例名也会自动带出。需要选择 profile、缺少 Region 或匹配不到实例时再填写相应信息。重新安装时可以回车沿用保存的目标，或输入 `r` 重选。

探测机每分钟查一次实例状态并尝试连接端口。连续三轮失败后，脚本请求停机，等到 Lightsail 报告 `stopped` 再请求启动。实例重新运行且拿到公网 IPv4 后，脚本会更新配置的 Cloudflare A 记录，并继续检查端口。每次故障最多执行一次停启，端口恢复且上一次停启已超过一小时后，才允许处理下一次故障。 [Lightsail 停机 API](https://docs.aws.amazon.com/cli/latest/reference/lightsail/stop-instance.html) · [Lightsail 启动 API](https://docs.aws.amazon.com/cli/latest/reference/lightsail/start-instance.html)

Lightsail 模式下，下面的手动 `update` 命令也会进行一次探测和故障判断。维护实例前，先确认上一次停启流程已经结束，再暂停探测机上的定时任务。

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
