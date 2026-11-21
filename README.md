# AnyTLS 一键安装脚本

在使用 systemd 或 OpenRC 的 Linux VPS 上安装和管理基于 [sing-box](https://sing-box.sagernet.org) 的 AnyTLS 服务。脚本使用 [acme.sh](https://github.com/acmesh-official/acme.sh) 申请和续期 Let's Encrypt 证书。

## 安装和管理

从 [GitHub Releases](https://github.com/Howl-Star/anytls/releases) 下载指定版本的 `anytls.sh`，检查后以 root 运行。开发版可从仓库下载 `anytls.sh` 后以同样的方式运行。

```bash
sudo bash anytls.sh
```

**安装成功后直接输入 `menu` 打开管理菜单。** 非 root 用户可运行 `sudo menu`。入口保存在 `/usr/local/bin/menu`，菜单从本地磁盘运行。如果该路径已存在其他程序，安装会提示处理冲突。

```bash
menu
menu status
menu info
menu update
menu update --version 1.14.4
menu renew
menu uninstall
```

旧版升级运行 `sudo bash anytls.sh upgrade`。脚本会保留域名、端口、密码、webroot 和在线证书，安装 `menu`，并更新现有 acme.sh 的续期部署设置。未创建 `menu` 的旧安装也可以直接运行 `sudo bash anytls.sh` 进入升级流程。执行 `menu info` 会显示密码和分享链接，复制时请妥善保管。

## 安装条件

- 具有 root 权限的 Linux VPS，支持 systemd 或 OpenRC。
- 域名的 A 或 AAAA 记录指向 VPS。使用域名连接以校验证书。
- 向公网开放 ACME 验证端口 `80/TCP` 或 `443/TCP`。已有 HTTP 站点时建议使用 `--webroot`。
- 防火墙和云安全组放行服务的 TCP 端口，默认 `8443`。
- 能访问 GitHub 和 Let's Encrypt。安装程序会尝试补齐 `curl`、`tar`、`openssl`、`socat`、`jq`、`sha256sum`、`flock` 和 `ss`。

## 非交互安装

```bash
sudo bash anytls.sh install --non-interactive --domain tls.example.com
sudo bash anytls.sh install --non-interactive --domain tls.example.com --webroot /var/www/html
```

非交互模式可省略邮箱和端口等可选参数。端口冲突会直接报错。重装需要额外传入 `--force`。脚本会将凭据保存在本机 `anytls.txt` 中，非交互安装成功时可通过 `menu info` 查看。

| 选项 | 说明 |
| --- | --- |
| `--domain <域名>` | 用于签发证书的域名 |
| `--port <端口>` | 服务监听端口，默认 `8443` |
| `--password <密码>` | 6 至 64 位 URL 安全字符，默认随机生成 |
| `--name <节点名>` | 默认 `AnyTLS-<域名>` |
| `--email <邮箱>` | 可选的 ACME 注册邮箱 |
| `--webroot <目录>` | 现有站点的绝对路径，用 HTTP 文件完成验证 |
| `--version <版本>` | 覆盖脚本固定的默认 sing-box 版本 |
| `--force` | 确认重装。也可用于 `menu uninstall --force` |
| `--non-interactive` | 使用默认值并禁止读取输入 |

## 更新和续期

- 更新从 sing-box 的 GitHub Release 下载对应架构的二进制文件，校验 Release 提供的 SHA-256，检查现有配置，然后重启服务。启动检查失败时恢复旧文件，并尝试恢复原服务状态。
- 指定 `--webroot` 时只尝试该站点验证。未指定时优先使用 `80/TCP` 的 HTTP 验证。若端口被占用，或 CA 返回可识别的 HTTP 连通性错误，则尝试 `443/TCP` 的 TLS-ALPN 验证。DNS、限流和其他无法识别的错误会保留 ACME 日志并停止回退。
- acme.sh 的 cron 任务续期后，将证书交给本地管理脚本检查和部署。`menu renew` 优先重试部署有效的候选证书。需要重新签发时，会优先沿用已记录的 TLS-ALPN 或配置的 webroot。未确认 cron 正常运行时，安装会提示检查。
- 如果 AnyTLS 使用 `80` 或 `443`，请确保续期时所选的验证端口可用。可用独立 HTTP 站点提供 `--webroot`，或使用 `menu renew` 手动重签。
- sing-box 的架构和 musl 资产由对应 Release 决定。资产缺失或缺少校验值时，脚本会停止并指出文件名。

## 卸载

运行 `sudo menu uninstall`，或在管理菜单中选择「卸载」。确认后先取消当前域名的自动续期，再移除服务、本地配置和本项目的 `menu` 入口。共享的 acme.sh、其他域名证书和 acme.sh 中的证书原件会保留。若续期记录清理失败，修复后可重新运行卸载。自动化可用 `sudo menu uninstall --force` 跳过确认。

## 文件位置

| 路径 | 内容 |
| --- | --- |
| `/usr/local/bin/menu` | 管理入口，指向本地脚本 |
| `/etc/anytls/manage.sh` | 本地管理脚本和续期入口 |
| `/etc/anytls/sing-box` | 内核二进制 |
| `/etc/anytls/config.json` | sing-box 配置 |
| `/etc/anytls/anytls.env` | 安装参数和节点凭据 |
| `/etc/anytls/anytls.txt` | AnyTLS 链接和 Clash / mihomo 配置片段 |
| `/etc/anytls/cert/` | 证书和私钥 |
| `/etc/systemd/system/anytls.service` | systemd 服务 |
| `/etc/init.d/anytls` | OpenRC 服务 |

服务启动失败时，可以运行 `menu status` 或从管理菜单查看日志。也可在 VPS 上直接检查配置。

```bash
sudo /etc/anytls/sing-box check -c /etc/anytls/config.json
sudo journalctl -u anytls -n 50 --no-pager
```

OpenRC 日志位于 `/var/log/anytls.log`。证书签发失败时，请检查 DNS、防火墙、云安全组和 ACME 验证端口。签发受 Let's Encrypt 频率限制。

## 维护

```bash
bash -n anytls.sh
shellcheck -x anytls.sh tests/regression.sh
bash tests/regression.sh
```

CI 在提交和 PR 上运行以上检查。打 `v*` 标签时，发布流程上传版本化脚本和 `SHA256SUMS`。

## 免责声明

仅供个人学习与合法用途。请遵守所在地的法律法规。

结构设计参考 [fscarmen/sing-box](https://github.com/fscarmen/sing-box)。项目使用 MIT 许可证。
