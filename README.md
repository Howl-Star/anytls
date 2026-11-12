# AnyTLS 一键安装脚本

基于 [sing-box](https://sing-box.sagernet.org) 的 **AnyTLS** 一键安装与管理脚本，TLS 证书由 **acme.sh** 自动申请并自动续期。

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Howl-Star/anytls/main/anytls.sh)
```

装好后随时输入下面的命令打开管理菜单：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Howl-Star/anytls/main/anytls.sh) menu
```

> 已安装后也可以只用本地副本：`bash anytls.sh menu`

## 特性

- **AnyTLS 协议**：sing-box 官方内核，自动识别 amd64 / arm64 / armv7 / armv6 / 386 / s390x；musl 系统（Alpine）自动选 `-musl` 版本（armv6 / s390x 无 musl 资产，脚本会明确报错而不是 404）
- **内核自检回滚**：替换内核后先跑 `sing-box version` 自检，架构不符或文件损坏时自动回滚到旧版本
- **监听地址自适应**：有 IPv6 时监听 `::`（dual-stack），内核禁用 IPv6 时自动改用 `0.0.0.0`
- **真证书**：域名 + Let's Encrypt（acme.sh），自动续期并通过 `--reloadcmd` 重启服务
- **零依赖装**：自动识别 apt / dnf / yum / apk / pacman / zypper 安装 `curl tar openssl socat`
- **服务管理**：systemd 与 OpenRC 双支持
- **分享链接**：直接输出 `anytls://` 链接与 Clash / mihomo 配置片段
- **完整管理菜单**：查看节点、改端口、改密码、重签证书、更新内核、重启、看日志、卸载
- **非交互安装**：全部参数可用命令行传入，适合自动化

## 前置条件

1. 一台 VPS（root 权限）
2. **一个解析到该 VPS 的域名**（脚本只用域名 + ACME，IP 直连无法通过证书校验）
3. 放行 **80 端口**（standalone 验证）或 **443 端口**（TLS-ALPN 验证）用于签发；已占用时可用 `--webroot` 走站点验证
4. 放行脚本监听的 AnyTLS 端口（默认 `8443`）

## 使用

```bash
# 交互安装（未安装时直接运行即可）
bash anytls.sh

# 非交互安装
bash anytls.sh install --domain tls.example.com --port 8443 --email me@example.com

# 用已有站点的 webroot 做 ACME 验证
bash anytls.sh install --domain tls.example.com --webroot /var/www/html

# 指定内核版本
bash anytls.sh install --domain tls.example.com --version 1.14.4
```

### 命令

| 命令 | 说明 |
| --- | --- |
| `install` | 安装 / 重装（已安装需确认，`--force` 跳过确认） |
| `menu` | 管理菜单（默认行为） |
| `info` | 输出节点信息与分享链接 |
| `status` | 查看安装与运行状态 |
| `restart` | 重启服务 |
| `update` | 更新 sing-box 内核到最新版 |
| `renew` | 强制重新申请证书 |
| `uninstall` | 卸载（移除服务、配置与 acme 续期任务） |
| `help` | 帮助 |

### 安装选项

| 选项 | 说明 |
| --- | --- |
| `--domain <域名>` | 证书域名，必须已解析到本机 |
| `--port <端口>` | 监听端口，默认 `8443` |
| `--password <密码>` | AnyTLS 密码，默认随机 32 位十六进制 |
| `--name <节点名>` | 节点显示名，默认 `AnyTLS-<域名>` |
| `--email <邮箱>` | acme.sh 注册邮箱，可留空 |
| `--webroot <目录>` | 用 webroot 方式验证（默认自动 standalone / TLS-ALPN） |
| `--version <版本>` | 指定 sing-box 版本，如 `1.14.4` |
| `--force` | 已安装时不再询问，直接重装 |

## 客户端配置

脚本安装完会打印，并保存到 `/etc/anytls/anytls.txt`：

```
anytls://<password>@<域名>:<端口>?idle_session_check_interval=30s&idle_session_timeout=30s&min_idle_session=5&security=tls&sni=<域名>&fp=chrome#<节点名>
```

Clash / mihomo：

```yaml
- name: "AnyTLS-tls.example.com"
  type: anytls
  server: tls.example.com
  port: 8443
  password: xxxxxxxx
  client-fingerprint: chrome
  sni: tls.example.com
  udp: true
  idle-session-check-interval: 30
  idle-session-timeout: 30
  skip-cert-verify: false
```

支持的客户端：sing-box、mihomo / Clash Meta、v2rayN、NekoBox、Shadowrocket 等（需支持 AnyTLS，较旧版本不支持）。

> **注意**：链接里填的是域名而不是 IP。Let's Encrypt 证书的 SAN 只包含域名，用 IP 连接会证书校验失败。若域名解析不通，才临时改用 IP 并在客户端打开 `skip-cert-verify`。

## 文件位置

| 路径 | 内容 |
| --- | --- |
| `/etc/anytls/sing-box` | 内核二进制 |
| `/etc/anytls/config.json` | 服务端配置（权限 600） |
| `/etc/anytls/anytls.env` | 安装参数（域名/端口/密码/节点名，权限 600） |
| `/etc/anytls/cert/` | 证书与私钥 |
| `/etc/anytls/anytls.txt` | 节点信息与分享链接（权限 600） |
| `/etc/systemd/system/anytls.service` | systemd 单元 |
| `/etc/init.d/anytls` | OpenRC 服务（Alpine） |

查看日志：`journalctl -u anytls -f`（OpenRC：`tail -f /var/log/anytls.log`）

## 常见问题

**证书申请失败怎么办？**

- 确认域名 A / AAAA 记录已生效：`dig +short tls.example.com`
- 确认 80 或 443 未被占用；被占用时改用 `--webroot /var/www/html`
- **云服务器要同时放行安全组和系统防火墙的 80/TCP**（standalone 验证必需）；AWS 安全组默认不放行 80，这是最常见的失败原因
- 脚本在签发失败时会直接退出并给出对应提示，不会用旧证书「假装成功」
- Let's Encrypt 有频率限制，失败后不要反复重试

**服务起不来？**

```bash
/etc/anytls/sing-box check -c /etc/anytls/config.json   # 配置自检
journalctl -u anytls -n 50 --no-pager                   # 看日志
```

**如何手动续期证书？**

acme.sh 已自动安装 cron 任务，一般无需干预；需要强制重签时执行 `bash anytls.sh renew`。

## 免责声明

仅供个人学习与合法用途。请遵守所在国家 / 地区的法律法规，使用者自行承担因使用本脚本产生的一切后果。

## 致谢

结构设计参考 [fscarmen/sing-box](https://github.com/fscarmen/sing-box)。

## License

MIT
