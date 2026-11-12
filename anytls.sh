#!/usr/bin/env bash
#
# AnyTLS 一键安装脚本
# 内核：sing-box（AnyTLS 协议）
# 证书：域名 + acme.sh 自动申请与续期
#
# 用法：
#   bash anytls.sh                          交互菜单（未安装则进入安装）
#   bash anytls.sh install --domain a.com    非交互安装
#   bash anytls.sh info | status | restart | update | renew | uninstall | menu | help
#
# 远程一键安装：
#   bash <(curl -Ls https://raw.githubusercontent.com/Howl-Star/anytls/main/anytls.sh)

set -o pipefail

# ==================== 全局常量 ====================
WORK_DIR='/etc/anytls'
BIN_FILE="${WORK_DIR}/sing-box"
CONF_FILE="${WORK_DIR}/config.json"
ENV_FILE="${WORK_DIR}/anytls.env"
CERT_DIR="${WORK_DIR}/cert"
CERT_FILE="${CERT_DIR}/cert.pem"
KEY_FILE="${CERT_DIR}/private.key"
INFO_FILE="${WORK_DIR}/anytls.txt"
SERVICE_NAME='anytls'
SYSTEMD_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
OPENRC_FILE="/etc/init.d/${SERVICE_NAME}"

DEFAULT_PORT='8443'
DEFAULT_FP='chrome'
GH_API='https://api.github.com/repos/SagerNet/sing-box/releases/latest'

# ==================== 输出函数 ====================
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[36m'; BOLD=$'\033[1m'; PLAIN=$'\033[0m'

info()  { printf '%s\n' "${GREEN}${BOLD}$*${PLAIN}"; }
warn()  { printf '%s\n' "${YELLOW}${BOLD}$*${PLAIN}"; }
# 多行错误信息用 %b 解析 \n（%s 会把 \n 原样打印出来）
error() { printf '%b\n' "${RED}${BOLD}$*${PLAIN}"; exit 1; }
line()  { printf '%s\n' "${BLUE}----------------------------------------------------------------${PLAIN}"; }

# 交互读取：兼容 `curl | bash` 场景（stdin 是管道时改从终端读）
reading() {
  local prompt="$1" var="$2" default="$3" answer='' rc=0
  if [ -n "$default" ]; then
    prompt="${prompt} [${default}] "
  fi
  if [ -t 0 ]; then
    read -rp "$prompt" answer || rc=1
  elif [ -r /dev/tty ]; then
    read -rp "$prompt" answer < /dev/tty || rc=1
  else
    read -rp "$prompt" answer || rc=1
  fi
  # 非交互环境下读不到输入：不能死循环，直接报错退出
  if [ "$rc" -ne 0 ] && [ -z "$answer" ]; then
    error "当前环境无法交互输入，请改用命令行参数（bash $0 help 查看用法）"
  fi
  [ -z "$answer" ] && answer="$default"
  printf -v "$var" '%s' "$answer"
}

confirm() {
  local prompt="$1" answer
  # 默认值由 reading 负责追加，这里不要再写死 [n]，否则会显示成 "[y/N] [n]"
  reading "${prompt} (y/N)" answer 'n'
  [[ "$answer" =~ ^[Yy]$ ]]
}

# ==================== 基础检测 ====================
need_root() {
  [ "$(id -u)" = '0' ] || error "请使用 root 用户运行本脚本（sudo -i 后重试）"
}

detect_os() {
  OS_ID='unknown'; OS_LIKE=''; OS_NAME=''
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_NAME="${PRETTY_NAME:-$OS_ID}"
  elif [ -r /etc/redhat-release ]; then
    OS_ID='centos'; OS_NAME=$(cat /etc/redhat-release)
  fi

  case "$OS_ID $OS_LIKE" in
    *debian*|*ubuntu*|*kali*|*raspbian*) PKG_FAMILY='deb' ;;
    *alpine*)                            PKG_FAMILY='apk' ;;
    *arch*|*manjaro*)                    PKG_FAMILY='pacman' ;;
    *suse*|*opensuse*|*sles*)            PKG_FAMILY='zypper' ;;
    *rhel*|*centos*|*fedora*|*rocky*|*almalinux*|*ol*) PKG_FAMILY='rpm' ;;
    *)                                   PKG_FAMILY='unknown' ;;
  esac
}

pkg_install() {
  case "$PKG_FAMILY" in
    deb)    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 ;;
    rpm)    if command -v dnf >/dev/null 2>&1; then dnf install -y -q "$@" >/dev/null 2>&1; else yum install -y -q "$@" >/dev/null 2>&1; fi ;;
    apk)    apk add --no-cache "$@" >/dev/null 2>&1 ;;
    pacman) pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1 ;;
    zypper) zypper -q install -y "$@" >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
}

pkg_update() {
  case "$PKG_FAMILY" in
    deb)    apt-get update -qq >/dev/null 2>&1 ;;
    rpm)    command -v dnf >/dev/null 2>&1 && dnf makecache -q >/dev/null 2>&1 || yum makecache -q >/dev/null 2>&1 ;;
    apk)    apk update >/dev/null 2>&1 ;;
    pacman) pacman -Sy >/dev/null 2>&1 ;;
    zypper) zypper -q refresh >/dev/null 2>&1 ;;
  esac
}

detect_init() {
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    INIT='systemd'
  elif command -v rc-update >/dev/null 2>&1 && [ -d /etc/init.d ]; then
    INIT='openrc'
  else
    INIT='unknown'
  fi
}

detect_arch() {
  local musl=''
  # Alpine / 部分精简系统是 musl，需要用 -musl 版本的二进制
  if [ "$PKG_FAMILY" = 'apk' ] || { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; }; then
    musl='-musl'
  fi
  case "$(uname -m)" in
    x86_64|amd64)   ARCH="amd64${musl}" ;;
    aarch64|arm64)  ARCH="arm64${musl}" ;;
    armv7l|armv7)   ARCH="armv7${musl}" ;;
    armv6l)
      # sing-box 只提供 armv6 的 glibc 版，没有 armv6-musl 资产
      [ -n "$musl" ] && error "sing-box 未提供 armv6 的 musl 版本，Alpine 等 musl 系统请改用 armv7 或 glibc 发行版"
      ARCH="armv6"
      ;;
    i386|i686)      ARCH="386${musl}" ;;
    s390x)
      # 同上：s390x 只有 glibc 版
      [ -n "$musl" ] && error "sing-box 未提供 s390x 的 musl 版本，请改用 glibc 发行版"
      ARCH="s390x"
      ;;
    *)              error "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

# ==================== 依赖 ====================
# acme.sh 安装器要求系统已有 crontab，否则直接判 Install error 退出
install_cron() {
  command -v crontab >/dev/null 2>&1 && return 0
  pkg_update
  case "$PKG_FAMILY" in
    deb)    pkg_install cron ;;
    rpm)    pkg_install cronie ;;
    apk)    pkg_install dcron ;;
    pacman) pkg_install cronie ;;
    zypper) pkg_install cron ;;
    *)      return 1 ;;
  esac
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
  elif command -v rc-update >/dev/null 2>&1; then
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || true
  fi
  command -v crontab >/dev/null 2>&1
}

check_deps() {
  local need=() c
  if [ "$PKG_FAMILY" = 'unknown' ]; then
    warn "未能识别系统包管理器，请手动确保已安装：curl tar openssl socat ca-certificates cron"
  else
    for c in curl tar openssl socat; do
      command -v "$c" >/dev/null 2>&1 || need+=("$c")
    done
    if [ "${#need[@]}" -gt 0 ]; then
      info "安装依赖：${need[*]}"
      pkg_update
      local mapped=()
      for c in "${need[@]}"; do
        case "$c" in
          socat) mapped+=('socat') ;;
          openssl) mapped+=('openssl') ;;
          tar) mapped+=('tar') ;;
          curl) mapped+=('curl') ;;
        esac
      done
      pkg_install "${mapped[@]}" || warn "自动安装依赖失败，请手动安装后重试"
      pkg_install ca-certificates >/dev/null 2>&1 || true
    fi
  fi

  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || error "缺少 curl / wget，无法继续"

  # acme.sh 安装器强制要求 crontab，缺失会直接 Install error
  if ! install_cron; then
    warn "未能安装 cron，将使用 --force 跳过自动续期任务（需自行再次运行脚本 renew 续期）"
  fi
}

# 统一的下载函数（优先 curl，回退 wget）
fetch() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$out" ]; then curl -fsSL --max-time 60 -o "$out" "$url"; else curl -fsSL --max-time 30 "$url"; fi
  else
    if [ -n "$out" ]; then wget -q --timeout=60 -O "$out" "$url"; else wget -q --timeout=30 -O - "$url"; fi
  fi
}

# ==================== 网络信息 ====================
get_public_ip() {
  local u ip
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip https://ip.sb; do
    ip=$(fetch "$u" '' 2>/dev/null | tr -d ' \r\n')
    if printf '%s' "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -Htln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$" && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$" && return 0
  fi
  return 1
}

# 域名解析结果（用于安装前的 DNS 提醒，不阻断流程）
resolve_domain() {
  local d="$1"
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$d" 2>/dev/null | awk '{print $1}' | tr '\n' ' '
  elif command -v dig >/dev/null 2>&1; then
    dig +short A "$d" 2>/dev/null | tr '\n' ' '
  else
    ping -c1 -W2 "$d" 2>/dev/null | sed -n '1s/.*(\([0-9.]*\)).*/\1/p'
  fi
}

# ==================== 版本与内核 ====================
get_latest_version() {
  local json v
  json=$(fetch "$GH_API" '' 2>/dev/null)
  # 不依赖 JSON 的换行格式：直接抓第一个 tag_name（API 按发布时间倒序）
  v=$(printf '%s' "$json" | tr -d ' \r\n' | grep -o '"tag_name":"v\{0,1\}[^"]*"' | head -n1 | sed 's/.*:"v\{0,1\}\(.*\)"/\1/')
  if [ -z "$v" ]; then
    v=$(fetch 'https://github.com/SagerNet/sing-box/releases.atom' '' 2>/dev/null \
      | sed -n 's#.*/releases/tag/v\([^"]*\)".*#\1#p' | sort -Vr | head -n1)
  fi
  printf '%s' "$v"
}

install_core() {
  local ver="${1:-}" tmp url dir bak="${BIN_FILE}.bak"
  if [ -z "$ver" ]; then
    info "获取 sing-box 最新版本..."
    ver=$(get_latest_version)
  fi
  # 归一化：允许 --version v1.14.4，否则会拼出 download/vv1.14.4/ 与 sing-box-v1.14.4-... 两个错地址
  ver="${ver#v}"
  [ -n "$ver" ] || error "无法获取 sing-box 版本号，请检查网络后重试（也可手动指定：--version 1.12.0）"

  tmp=$(mktemp -d)
  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${ARCH}.tar.gz"
  info "下载 sing-box v${ver} (linux-${ARCH})"
  if ! fetch "$url" "${tmp}/sb.tar.gz"; then
    rm -rf "$tmp"
    error "下载失败：$url\n可尝试手动下载后放到 ${BIN_FILE}"
  fi
  tar xzf "${tmp}/sb.tar.gz" -C "$tmp" >/dev/null 2>&1 || { rm -rf "$tmp"; error "解压失败"; }
  dir=$(find "$tmp" -maxdepth 2 -type f -name 'sing-box' -print -quit)
  [ -n "$dir" ] || { rm -rf "$tmp"; error "压缩包内未找到 sing-box 可执行文件"; }

  mkdir -p "$WORK_DIR"
  # 先备份旧内核：替换后若新内核跑不起来，还能回滚，不至于把服务搞成「更新完就起不来」
  rm -f "$bak"
  [ -x "$BIN_FILE" ] && cp -f "$BIN_FILE" "$bak" 2>/dev/null || true
  # 先装到同目录的临时文件名，再 mv 原子替换：
  # 直接覆盖/删除正在运行的二进制会 ETXTBSY，mv 只替换目录项，运行中的进程持有旧 inode
  install -m 0755 "$dir" "${BIN_FILE}.new" || { rm -rf "$tmp"; error "安装内核失败"; }
  mv -f "${BIN_FILE}.new" "$BIN_FILE" || { rm -rf "$tmp"; error "替换内核失败"; }
  rm -rf "$tmp"
  # 自检：下载到的是不是能给本机跑的可执行文件（架构不符/文件损坏都会在这里暴露）
  if ! "$BIN_FILE" version >/dev/null 2>&1; then
    if [ -s "$bak" ]; then
      mv -f "$bak" "$BIN_FILE"
      error "新内核无法在本机运行（架构不匹配或文件损坏），已回滚到旧版本"
    fi
    error "新内核无法在本机运行（架构不匹配或文件损坏）"
  fi
  rm -f "$bak"
  printf '%s' "$ver" > "${WORK_DIR}/version"
  info "内核安装完成：v${ver}"
}

core_version() {
  # sing-box 的首行是 "sing-box version 1.14.4"，并非 "version 1.14.4"，
  # 用 /^version/ 匹配会永远得到空字符串
  [ -x "$BIN_FILE" ] || return 0
  "$BIN_FILE" version 2>/dev/null | sed -n '1s/.* version \([0-9][^ ]*\).*/\1/p' | head -n1
}

# ==================== 证书（acme.sh） ====================
ACME_HOME="${HOME}/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"

install_acme() {
  [ -x "$ACME_BIN" ] && return 0
  info "安装 acme.sh..."
  mkdir -p "$ACME_HOME"
  local email_arg=''
  [ -n "$EMAIL" ] && email_arg="email=${EMAIL}"
  local installer="${ACME_HOME}/get.sh"

  # acme.sh 安装器没有 crontab 会直接 Install error，必须先备好 cron 或用 --force
  local force_arg=''
  if ! command -v crontab >/dev/null 2>&1; then
    warn "系统未安装 crontab，acme.sh 将以 --force 方式安装（不注册自动续期任务）"
    force_arg='--force'
  fi

  # 方式一：官方安装器（保留输出，失败原因可见）
  fetch https://get.acme.sh "$installer" || true
  if [ -s "$installer" ]; then
    sh "$installer" $email_arg $force_arg || true
  fi

  # 方式二：直接下载 acme.sh 单文件后本地 install（不再二次联网）
  if [ ! -x "$ACME_BIN" ]; then
    warn "官方安装器未成功，改用直接下载 acme.sh"
    fetch "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh" "$ACME_BIN" || true
    if [ -s "$ACME_BIN" ]; then
      chmod +x "$ACME_BIN"
      "$ACME_BIN" --install --home "$ACME_HOME" $force_arg >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$installer"

  if [ ! -x "$ACME_BIN" ]; then
    error "acme.sh 安装失败：无法访问 get.acme.sh 或 GitHub
 请先手动确认出网：curl -I https://raw.githubusercontent.com
 或手动安装后重跑本脚本：
  mkdir -p ~/.acme.sh
  curl -L https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh -o ~/.acme.sh/acme.sh
  chmod +x ~/.acme.sh/acme.sh"
  fi
  "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
}

# issue_cert <domain> <webroot> ；webroot 为空时自动选择 standalone(80) / alpn(443)
issue_cert() {
  local domain="$1" webroot="$2" extra='' stopped='0'
  [ -n "$domain" ] || error "缺少域名，无法申请证书"

  install_acme

  # 已有帐篷记录时强制重签
  [ "$FORCE_RENEW" = '1' ] && extra='--force'

  line
  info "为 ${domain} 申请 Let's Encrypt 证书"
  if [ -n "$webroot" ]; then
    [ -d "$webroot" ] || error "webroot 目录不存在：$webroot"
    info "验证方式：webroot（${webroot}）"
    # 必须检查返回值：acme.sh 签发失败时返回非 0，
    # 若继续往下走 install_cert，机器上残留的旧证书会让"文件非空"判据误判为成功
    if ! "$ACME_BIN" --issue -d "$domain" -w "$webroot" --keylength ec-256 --server letsencrypt $extra; then
      error "webroot 方式验证失败。请确认：
  1) http://${domain}/.well-known/acme-challenge/ 能被外网访问（80/TCP 已放行）
  2) ${webroot} 是 Web 站点的根目录（如 /var/www/html），且 Nginx/Apache 已运行"
    fi
  elif ! port_in_use 80; then
    info "验证方式：standalone（80 端口）"
    if ! "$ACME_BIN" --issue -d "$domain" --standalone --httpport 80 --keylength ec-256 --server letsencrypt $extra; then
      error "standalone 验证失败。请确认：
  1) 云厂商安全组与系统防火墙均已放行 80/TCP
  2) 域名 ${domain} 已解析到本机公网 IP
  3) 80 端口没有其它程序占用
若 80 端口不便开放，可改用 --webroot /var/www/html（需已有 Web 服务）"
    fi
  else
    # 80 已被占用，退到 TLS-ALPN(443)。若 443 正是本服务在监听（续期时的常见情况），
    # 必须先停服务，否则 acme.sh 绑不上 443，验证必然失败。
    if svc_active; then
      warn "443 端口由 AnyTLS 自身监听，临时停止服务以完成 TLS-ALPN 验证"
      svc_stop
      stopped='1'
      sleep 1
    fi
    if port_in_use 443; then
      [ "$stopped" = '1' ] && svc_start
      error "80 与 443 端口均被占用，无法完成 ACME 验证。\n请释放端口，或使用 --webroot /var/www/html 指定站点根目录"
    fi
    info "验证方式：TLS-ALPN（443 端口）"
    if ! "$ACME_BIN" --issue -d "$domain" --alpn --tlsport 443 --keylength ec-256 --server letsencrypt $extra; then
      [ "$stopped" = '1' ] && svc_start
      error "TLS-ALPN 验证失败，请确认 443 可被外网访问、域名已解析到本机"
    fi
    [ "$stopped" = '1' ] && svc_start
  fi

  install_cert "$domain"
}

install_cert() {
  local domain="$1"
  mkdir -p "$CERT_DIR"
  # acme.sh 的 --install-cert 会立即执行 reloadcmd；此时服务可能尚未创建
  # （首次安装场景），因此 reloadcmd 必须自带容错，否则会误判为“证书安装失败”。
  "$ACME_BIN" --install-cert -d "$domain" --ecc \
    --key-file "$KEY_FILE" \
    --fullchain-file "$CERT_FILE" \
    --reloadcmd "$(reload_cmd)" || true

  [ -s "$KEY_FILE" ] && [ -s "$CERT_FILE" ] || error "证书安装失败：${CERT_FILE} 或 ${KEY_FILE} 为空"

  chmod 600 "$KEY_FILE"
  chmod 644 "$CERT_FILE"
  info "证书已部署：${CERT_FILE}"
}

# 续期时用于重载服务的命令（写入 acme.sh 的 reloadcmd）
# 末尾的 || true 是必需的：acme.sh 在 --install-cert 阶段就会执行该命令，
# 首次安装时 anytls.service 还不存在，不能因此中断安装流程。
reload_cmd() {
  if [ "$INIT" = 'systemd' ]; then
    printf 'systemctl restart %s >/dev/null 2>&1 || true' "$SERVICE_NAME"
  else
    printf 'rc-service %s restart >/dev/null 2>&1 || true' "$SERVICE_NAME"
  fi
}

# ==================== 配置文件 ====================
write_config() {
  mkdir -p "$WORK_DIR"
  # listen 选择：有 IPv6 时用 "::"（Linux 下默认 dual-stack，同时收 IPv4/IPv6），
  # 内核禁用了 IPv6（ipv6.disable=1）时 "::" 会绑定失败导致服务起不来，改用 0.0.0.0
  local listen_addr='::'
  [ -f /proc/net/if_inet6 ] || listen_addr='0.0.0.0'
  # 密码由 valid_password 约束为 [A-Za-z0-9._~-]，不含引号与反斜杠，可安全直接嵌入
  cat > "$CONF_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "${listen_addr}",
      "listen_port": ${PORT},
      "users": [
        {
          "password": "${PASSWORD}"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
  chmod 600 "$CONF_FILE"
}

# 单引号安全写入 env 文件（值里的 ' 转义为 '\''）
sq() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

save_env() {
  cat > "$ENV_FILE" <<EOF
DOMAIN='$(sq "${DOMAIN}")'
PORT='$(sq "${PORT}")'
PASSWORD='$(sq "${PASSWORD}")'
NODE_NAME='$(sq "${NODE_NAME}")'
EMAIL='$(sq "${EMAIL}")'
WEBROOT='$(sq "${WEBROOT}")'
EOF
  chmod 600 "$ENV_FILE"
}

load_env() {
  [ -s "$ENV_FILE" ] || error "未检测到安装信息（${ENV_FILE}），请先执行安装"
  # shellcheck disable=SC1090
  . "$ENV_FILE"
}

is_installed() {
  [ -s "$ENV_FILE" ] && [ -x "$BIN_FILE" ]
}

# ==================== 服务管理 ====================
write_service() {
  detect_init
  case "$INIT" in
    systemd)
      cat > "$SYSTEMD_FILE" <<EOF
[Unit]
Description=AnyTLS service (sing-box)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
Type=simple
NoNewPrivileges=yes
WorkingDirectory=${WORK_DIR}
ExecStart=${BIN_FILE} run -c ${CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload >/dev/null 2>&1
      systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
      ;;
    openrc)
      cat > "$OPENRC_FILE" <<EOF
#!/sbin/openrc-run

name="AnyTLS service (sing-box)"
description="AnyTLS service based on sing-box"
command="${BIN_FILE}"
command_args="run -c ${CONF_FILE}"
command_background="yes"
pidfile="/run/${SERVICE_NAME}.pid"
output_log="/var/log/${SERVICE_NAME}.log"
error_log="/var/log/${SERVICE_NAME}.log"

depend() {
    need net
    after firewall
}
EOF
      chmod +x "$OPENRC_FILE"
      rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
      ;;
    *)
      error "未检测到 systemd / openrc，本脚本暂不支持当前 init 系统"
      ;;
  esac
}

svc_start() {
  case "$INIT" in
    systemd) systemctl start "$SERVICE_NAME" >/dev/null 2>&1 ;;
    openrc)  rc-service "$SERVICE_NAME" start >/dev/null 2>&1 ;;
  esac
}

svc_stop() {
  case "$INIT" in
    systemd) systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 ;;
    openrc)  rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 ;;
  esac
}

svc_restart() {
  case "$INIT" in
    systemd) systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 ;;
    openrc)  rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 ;;
  esac
}

svc_active() {
  case "$INIT" in
    systemd) systemctl is-active --quiet "$SERVICE_NAME" ;;
    openrc)  rc-service "$SERVICE_NAME" status >/dev/null 2>&1 ;;
    *)       return 1 ;;
  esac
}

svc_log() {
  case "$INIT" in
    systemd) journalctl -u "$SERVICE_NAME" -n 60 --no-pager ;;
    openrc)  tail -n 60 "/var/log/${SERVICE_NAME}.log" 2>/dev/null ;;
  esac
}

# ==================== 校验 ====================
valid_domain() {
  printf '%s' "$1" | grep -Eq '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
}

valid_port() {
  # 拒绝前导零：JSON 数字不允许 08443 这种写法，否则 sing-box 解析配置直接失败
  printf '%s' "$1" | grep -Eq '^(0|[1-9][0-9]{0,4})$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_password() {
  # 只允许 URL 安全字符，避免分享链接被截断；同时排除会破坏 JSON / YAML 的字符
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._~-]{6,64}$'
}

gen_password() {
  # 纯十六进制：既符合 AnyTLS 密码要求，也可直接裸写进 JSON / YAML，无需加引号
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-32
  fi
}

# ==================== 节点信息输出 ====================
url_encode() {
  # 必须强制 C locale 按字节处理：Linux 上通常是 C.UTF-8，此时 ${#s} 是字符数、
  # ${s:i:1} 取的是整个多字节字符，printf '%02X' "'香" 只会得到末字节 0x99，
  # 中文节点名会被编码成 %9999 之类的垃圾
  local LC_ALL=C s="$1" out='' c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

build_links() {
  local tag enc_name clash_link uri server
  SERVER_IP=$(get_public_ip 2>/dev/null)

  # 脚本使用域名 + Let's Encrypt 证书，证书 SAN 只含域名。
  # 客户端必须用域名连接才能通过校验，因此链接里统一填域名。
  server="$DOMAIN"
  if [ -z "$SERVER_IP" ]; then
    ALT_HINT='未能获取公网 IP，请确认域名已解析到本机'
  else
    ALT_HINT="本机公网 IP：${SERVER_IP}（客户端请填域名 ${DOMAIN}；若域名未解析，可临时改用该 IP 并在客户端开启 skip-cert-verify）"
  fi

  enc_name=$(url_encode "${NODE_NAME}")

  # YAML 双引号字符串里 " 和 \ 必须转义，否则节点名带引号会让配置整体非法
  yaml_name=${NODE_NAME//\\/\\\\}
  yaml_name=${yaml_name//\"/\\\"}

  # 参数对齐 fscarmen/sing-box 的实现：anytls 专有字段 + 标准 tls 字段
  uri="anytls://${PASSWORD}@${server}:${PORT}?idle_session_check_interval=30s&idle_session_timeout=30s&min_idle_session=5&security=tls&sni=${DOMAIN}&fp=${DEFAULT_FP}#${enc_name}"

  # password 加引号：纯数字密码不加引号会被 YAML 解析成整数，mihomo 期望字符串
  clash_link="- name: \"${yaml_name}\"
  type: anytls
  server: ${server}
  port: ${PORT}
  password: \"${PASSWORD}\"
  client-fingerprint: ${DEFAULT_FP}
  sni: ${DOMAIN}
  udp: true
  idle-session-check-interval: 30
  idle-session-timeout: 30
  skip-cert-verify: false"

  LINKS=$(cat <<EOF
================================================================
 AnyTLS 节点信息
================================================================
 节点名称 : ${NODE_NAME}
 服务器   : ${server}
 端口     : ${PORT}
 密码     : ${PASSWORD}
 SNI      : ${DOMAIN}
 客户端指纹: ${DEFAULT_FP}
 备注     : ${ALT_HINT}
================================================================

【分享链接（sing-box / v2rayN / NekoBox 等）】
${uri}

【Clash / mihomo 配置】
${clash_link}

【订阅文件】${INFO_FILE}
================================================================
EOF
)
}

show_info() {
  load_env
  detect_init
  build_links
  printf '%s\n' "$LINKS"
  if [ "$1" = 'save' ]; then
    mkdir -p "$WORK_DIR"
    printf '%s\n' "$LINKS" > "$INFO_FILE"
    chmod 600 "$INFO_FILE"
    info "节点信息已保存到 ${INFO_FILE}"
  fi
}

# ==================== 安装 ====================
do_install() {
  need_root
  detect_os
  detect_arch
  detect_init

  if is_installed && [ "$FORCE_INSTALL" != '1' ]; then
    warn "检测到 AnyTLS 已安装。重新安装会覆盖配置。"
    confirm "确认重新安装？" || { info "已取消"; exit 0; }
  fi

  line
  info "系统：${OS_NAME:-未知}    架构：${ARCH}    服务管理：${INIT}"
  line

  check_deps

  # ---------- 交互补全缺失参数 ----------
  if [ -z "$DOMAIN" ]; then
    while [ -z "$DOMAIN" ]; do
      reading "请输入证书域名（必须已解析到本机）: " DOMAIN ''
      [ -z "$DOMAIN" ] && warn "域名不能为空"
    done
  fi
  valid_domain "$DOMAIN" || error "域名格式不正确：$DOMAIN"

  [ -z "$PORT" ] && reading "请输入监听端口: " PORT "$DEFAULT_PORT"
  valid_port "$PORT" || error "端口不合法：$PORT"

  [ -z "$PASSWORD" ] && PASSWORD=$(gen_password)
  valid_password "$PASSWORD" || error "密码只能包含字母数字和 ._~- ，长度 6-64"

  if [ -z "$NODE_NAME" ]; then
    NODE_NAME="AnyTLS-${DOMAIN}"
  fi

  if [ -z "$EMAIL" ]; then
    reading "请输入邮箱（acme.sh 注册用，可留空）: " EMAIL ''
  fi

  [ -z "$WEBROOT" ] && WEBROOT=''

  # ---------- DNS 检查 ----------
  SERVER_IP=$(get_public_ip 2>/dev/null)
  local resolved
  resolved=$(resolve_domain "$DOMAIN")
  if [ -z "$resolved" ]; then
    warn "域名 ${DOMAIN} 暂无解析记录，ACME 验证可能失败"
  elif [ -n "$SERVER_IP" ] && ! printf '%s\n' "$resolved" | tr ' ' '\n' | grep -qxF "$SERVER_IP"; then
    warn "域名 ${DOMAIN} 解析到：${resolved}，本机公网 IP：${SERVER_IP}"
    confirm "解析似乎不一致，仍要继续？" || { info "已取消"; exit 0; }
  fi

  # ---------- 端口检查 ----------
  if port_in_use "$PORT"; then
    warn "端口 ${PORT} 已被占用"
    confirm "仍要继续安装？" || { info "已取消"; exit 0; }
  fi

  # ---------- 证书 ----------
  issue_cert "$DOMAIN" "$WEBROOT"

  # ---------- 内核 ----------
  install_core "$CORE_VERSION"

  # ---------- 配置与服务 ----------
  write_config
  save_env
  write_service

  svc_start
  sleep 2
  if svc_active; then
    info "AnyTLS 服务已启动"
  else
    warn "服务未能正常启动，以下为最近的日志："
    svc_log
    exit 1
  fi

  show_info save
  info "安装完成。管理菜单：bash anytls.sh"
  info "卸载：bash anytls.sh uninstall"
}

# ==================== 各动作 ====================
do_uninstall() {
  need_root
  detect_init
  confirm "确认卸载 AnyTLS？将删除 ${WORK_DIR} 与服务" || { info "已取消"; exit 0; }

  svc_stop
  case "$INIT" in
    systemd)
      systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
      rm -f "$SYSTEMD_FILE"
      systemctl daemon-reload >/dev/null 2>&1
      ;;
    openrc)
      rc-update del "$SERVICE_NAME" default >/dev/null 2>&1
      rm -f "$OPENRC_FILE"
      ;;
  esac

  # 删除 acme.sh 中的证书与续期任务
  if [ -s "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    if [ -x "$ACME_BIN" ] && [ -n "$DOMAIN" ]; then
      "$ACME_BIN" --remove -d "$DOMAIN" --ecc >/dev/null 2>&1 || true
    fi
  fi

  rm -rf "$WORK_DIR"
  info "卸载完成"
}

do_restart() {
  need_root
  load_env
  detect_init
  svc_restart
  sleep 1
  if svc_active; then info "服务已重启"; else warn "服务启动失败，日志如下："; svc_log; fi
}

do_update() {
  need_root
  detect_os
  detect_arch
  detect_init
  load_env
  local old new
  old=$(core_version)
  info "当前内核版本：${old:-未知}"
  install_core
  new=$(core_version)
  info "新内核版本：${new:-未知}"
  svc_restart
  sleep 1
  if svc_active; then
    info "内核更新完成，服务运行中"
  else
    warn "服务启动失败："
    svc_log
  fi
}

do_renew() {
  need_root
  load_env
  detect_os
  detect_init
  FORCE_RENEW='1'
  issue_cert "$DOMAIN" "$WEBROOT"
  svc_restart
  sleep 1
  if svc_active; then
    info "证书已更新，服务已重启"
  else
    warn "服务启动失败："
    svc_log
  fi
}

do_change_port() {
  need_root
  load_env
  detect_init
  local new
  reading "请输入新端口: " new "$PORT"
  valid_port "$new" || error "端口不合法：$new"
  if [ "$new" = "$PORT" ]; then
    info "端口未变化"
    return 0
  fi
  if port_in_use "$new"; then
    warn "端口 $new 已被占用"
    confirm "仍要使用？" || return 0
  fi

  PORT="$new"
  write_config
  save_env
  svc_restart
  sleep 1
  if svc_active; then
    info "端口已修改为 ${PORT}"
    show_info save
  else
    warn "服务启动失败："
    svc_log
  fi
}

do_change_password() {
  need_root
  load_env
  detect_init
  local new
  reading "请输入新密码（留空自动生成）: " new ''
  if [ -z "$new" ]; then
    new=$(gen_password)
    info "已生成新密码：${new}"
  fi
  valid_password "$new" || error "密码只能包含字母数字和 ._~- ，长度 6-64"

  PASSWORD="$new"
  write_config
  save_env
  svc_restart
  sleep 1
  if svc_active; then
    info "密码已更新"
    show_info save
  else
    warn "服务启动失败："
    svc_log
  fi
}

do_status() {
  detect_init
  if is_installed; then
    local v
    v=$(core_version)
    load_env
    printf '安装状态: %s已安装%s\n' "$GREEN" "$PLAIN"
    printf '内核版本: %s\n' "${v:-未知}"
    printf '域名    : %s\n' "${DOMAIN}"
    printf '监听端口: %s\n' "${PORT}"
    printf '服务状态: %s\n' "$(svc_active && printf '%s运行中%s' "$GREEN" "$PLAIN" || printf '%s未运行%s' "$RED" "$PLAIN")"
  else
    printf '安装状态: %s未安装%s\n' "$YELLOW" "$PLAIN"
    return 1
  fi
}

menu() {
  need_root
  detect_init
  while :; do
    clear 2>/dev/null || true
    printf '%s\n' "${BLUE}================================================================${PLAIN}"
    info "  AnyTLS 管理菜单"
    printf '%s\n' "${BLUE}================================================================${PLAIN}"
    ( do_status ) 2>/dev/null || true
    printf '%s\n' "${BLUE}================================================================${PLAIN}"
    printf '  1. 查看节点信息 / 分享链接\n'
    printf '  2. 修改端口\n'
    printf '  3. 修改密码\n'
    printf '  4. 重新申请证书（ACME）\n'
    printf '  5. 更新 sing-box 内核\n'
    printf '  6. 重启服务\n'
    printf '  7. 查看日志\n'
    printf '  8. 卸载\n'
    printf '  0. 退出\n'
    printf '%s\n' "${BLUE}================================================================${PLAIN}"
    local choose
    reading "请选择: " choose ''
    case "$choose" in
      1) show_info save ;;
      2) do_change_port ;;
      3) do_change_password ;;
      4) do_renew ;;
      5) do_update ;;
      6) do_restart ;;
      7) svc_log ;;
      8) do_uninstall; exit 0 ;;
      0|'') exit 0 ;;
      *) warn "无效选项：$choose" ;;
    esac
    printf '\n'
    reading "按回车返回菜单..." _ignore ''
  done
}

usage() {
  cat <<'EOF'
AnyTLS 一键安装与管理脚本（sing-box 内核 + acme.sh 证书）

用法:
  bash anytls.sh [命令] [选项]

命令:
  install     安装 / 重装
  menu        管理菜单（默认：已安装进入菜单，未安装进入安装）
  info        输出节点信息与分享链接
  status      查看安装与运行状态
  restart     重启服务
  update      更新 sing-box 内核
  renew       重新申请证书
  uninstall   卸载
  help        显示本帮助

安装选项:
  --domain <域名>      证书域名（必填，需已解析到本机）
  --port <端口>        监听端口，默认 8443
  --password <密码>    AnyTLS 密码，默认随机生成（URL 安全字符）
  --name <节点名>      节点显示名称，默认 AnyTLS-<域名>
  --email <邮箱>       acme.sh 注册邮箱（可留空）
  --webroot <目录>     使用 webroot 方式验证（默认自动 standalone/alpn）
  --version <版本>     指定 sing-box 版本，如 1.12.0
  --force             已安装时强制重装

示例:
  bash anytls.sh install --domain tls.example.com --port 8443 --email me@example.com
  bash anytls.sh install --domain tls.example.com --webroot /var/www/html

远程一键安装:
  bash <(curl -Ls https://raw.githubusercontent.com/Howl-Star/anytls/main/anytls.sh)
EOF
}

# ==================== 参数解析 ====================
ACTION=''
DOMAIN=''; PORT=''; PASSWORD=''; NODE_NAME=''; EMAIL=''; WEBROOT=''; CORE_VERSION=''
FORCE_INSTALL='0'; FORCE_RENEW='0'; SERVER_IP=''

# 取选项值：缺值时报错，避免 `--domain` 结尾把下一个参数吞掉或变成死循环
need_value() {
  [ "$2" -ge 2 ] || error "选项 $1 缺少取值（bash $0 help 查看用法）"
  # 下一个参数若是另一个选项，说明本选项漏了取值（如 --domain --port 443）
  case "$3" in
    -*) error "选项 $1 缺少取值，其后直接跟了选项 $3（bash $0 help 查看用法）" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    install|menu|info|status|restart|update|renew|uninstall|help|-h|--help)
      ACTION="$1"
      shift
      ;;
    --domain)   need_value "$1" $# "$2"; DOMAIN="$2"; shift 2 ;;
    --port)     need_value "$1" $# "$2"; PORT="$2"; shift 2 ;;
    --password) need_value "$1" $# "$2"; PASSWORD="$2"; shift 2 ;;
    --name)     need_value "$1" $# "$2"; NODE_NAME="$2"; shift 2 ;;
    --email)    need_value "$1" $# "$2"; EMAIL="$2"; shift 2 ;;
    --webroot)  need_value "$1" $# "$2"; WEBROOT="$2"; shift 2 ;;
    --version)  need_value "$1" $# "$2"; CORE_VERSION="$2"; shift 2 ;;
    --force)    FORCE_INSTALL='1'; shift ;;
    *)
      warn "未知参数：$1"
      shift
      ;;
  esac
done

# 仅在直接执行时进入主流程：被 source（如测试、二次封装）时只加载函数定义，
# 避免末尾的 exit 把调用方 shell 一起退出
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "$ACTION" in
    install)   do_install ;;
    info)      show_info save ;;
    status)    do_status ;;
    restart)   do_restart ;;
    update)    do_update ;;
    renew)     do_renew ;;
    uninstall) do_uninstall ;;
    help|-h|--help) usage ;;
    menu)      menu ;;
    '')
      if is_installed; then
        menu
      else
        do_install
      fi
      ;;
    *) usage; exit 1 ;;
  esac
  exit 0
fi
