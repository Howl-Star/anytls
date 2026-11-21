#!/usr/bin/env bash
# AnyTLS 安装和管理工具。安装成功后运行 menu。

init_paths() {
  WORK_DIR='/etc/anytls'
  MENU_FILE='/usr/local/bin/menu'
  LOCK_FILE='/run/anytls.lock'
  SYSTEMD_FILE='/etc/systemd/system/anytls.service'
  OPENRC_FILE='/etc/init.d/anytls'
  ACME_HOME="${HOME}/.acme.sh"
  DEFAULT_PORT=8443
  DEFAULT_CORE_VERSION='1.14.4'
  GH_RELEASES='https://api.github.com/repos/SagerNet/sing-box/releases'
  ACME_REVISION='5567d7fe7298fd37aca53194885ba444c6678669' # 3.1.7
  set_paths
}

set_paths() {
  BIN_FILE="$WORK_DIR/sing-box"
  CONF_FILE="$WORK_DIR/config.json"
  ENV_FILE="$WORK_DIR/anytls.env"
  CERT_DIR="$WORK_DIR/cert"
  CERT_FILE="$CERT_DIR/cert.pem"
  KEY_FILE="$CERT_DIR/private.key"
  INFO_FILE="$WORK_DIR/anytls.txt"
  MANAGER_FILE="$WORK_DIR/manage.sh"
  ACME_BIN="$ACME_HOME/acme.sh"
}

info() { printf '%s\n' "$*"; }
warn() { printf 'AnyTLS: %s\n' "$*" >&2; }
error() { warn "$@"; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || error '请使用 root 运行，或执行 sudo menu'; }

reading() {
  local prompt="$1" target="$2" default="$3" input
  [ "$NON_INTERACTIVE" = 0 ] || error '此操作需要人工确认，请检查参数和当前系统状态'
  if [ -n "$default" ]; then prompt="$prompt [$default] "; fi
  if [ -t 0 ]; then
    IFS= read -r -p "$prompt" input || error '无法读取终端输入'
  else
    { IFS= read -r -p "$prompt" input < /dev/tty; } 2>/dev/null || IFS= read -r input || error '无法读取输入，请使用 --non-interactive'
  fi
  printf -v "$target" '%s' "${input:-$default}"
}

confirm() {
  local answer
  reading "$1 (y/N)" answer n
  [[ "$answer" == [Yy] ]]
}

valid_domain() {
  local LC_ALL=C
  [ "${#1}" -le 253 ] && [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

valid_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]; }
valid_password() { [[ "$1" =~ ^[A-Za-z0-9._~-]{6,64}$ ]]; }
valid_version() { [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?$ ]]; }

fetch() {
  curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 180 -o "${2:--}" "$1"
}

detect_os() {
  local ID='' ID_LIKE=''
  # shellcheck disable=SC1091
  if [ -r /etc/os-release ]; then . /etc/os-release; fi
  case " $ID $ID_LIKE " in
    *' alpine '*) PKG_FAMILY=apk ;;
    *' debian '*|*' ubuntu '*|*' kali '*|*' raspbian '*) PKG_FAMILY=deb ;;
    *' arch '*|*' manjaro '*) PKG_FAMILY=pacman ;;
    *' suse '*|*' opensuse '*|*' opensuse-leap '*|*' opensuse-tumbleweed '*|*' sles '*) PKG_FAMILY=zypper ;;
    *' rhel '*|*' centos '*|*' fedora '*|*' rocky '*|*' almalinux '*|*' ol '*) PKG_FAMILY=rpm ;;
    *) PKG_FAMILY=unknown ;;
  esac
}

detect_init() {
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null; then
    INIT=systemd
    UNIT_FILE="$SYSTEMD_FILE"
  elif command -v rc-service >/dev/null && command -v rc-update >/dev/null; then
    INIT=openrc
    UNIT_FILE="$OPENRC_FILE"
  else
    INIT=unknown
    UNIT_FILE=''
    return 1
  fi
}

detect_arch() {
  local machine musl=''
  machine=$(uname -m)
  if [ "$PKG_FAMILY" = apk ] || ldd --version 2>&1 | grep -i musl >/dev/null; then musl='-musl'; fi
  case "$machine" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l|armv7) ARCH=armv7 ;;
    armv6l) ARCH=armv6 ;;
    i386|i686) ARCH=386 ;;
    s390x) ARCH=s390x ;;
    *) error "不支持的 CPU 架构 $machine" ;;
  esac
  ARCH+="$musl"
}

install_packages() {
  case "$PKG_FAMILY" in
    deb) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    rpm) if command -v dnf >/dev/null; then dnf install -y "$@"; else yum install -y "$@"; fi ;;
    apk) apk add --no-cache "$@" ;;
    pacman) pacman -S --needed --noconfirm "$@" ;;
    zypper) zypper --non-interactive install "$@" ;;
    *) return 1 ;;
  esac
}

check_deps() {
  local cmd package
  local -a missing=() required=(curl tar openssl socat jq sha256sum flock ss)
  for cmd in "${required[@]}"; do
    if command -v "$cmd" >/dev/null; then continue; fi
    package="$cmd"
    case "$PKG_FAMILY:$cmd" in
      apk:flock) package=flock ;;
      *:flock) package=util-linux ;;
      *:sha256sum) package=coreutils ;;
      rpm:ss) package=iproute ;;
      *:ss) package=iproute2 ;;
    esac
    missing+=("$package")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    install_packages "${missing[@]}" ca-certificates || error "安装依赖失败，请手动安装 ${missing[*]}"
  fi
  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null || error "缺少命令 $cmd"
  done
}

ensure_cron() {
  if ! command -v crontab >/dev/null; then
    case "$PKG_FAMILY" in
      deb|zypper) install_packages cron || return 1 ;;
      apk) install_packages dcron || return 1 ;;
      rpm|pacman) install_packages cronie || return 1 ;;
      *) return 1 ;;
    esac
  fi
  if [ "$INIT" = systemd ]; then
    systemctl enable --now cron 2>/dev/null || systemctl enable --now crond
  else
    rc-update add crond default && { rc-service crond status >/dev/null 2>&1 || rc-service crond start; }
  fi
}

port_in_use() {
  ss -H -ltn "sport = :$1" | awk 'NF { found=1 } END { exit !found }'
}

# 保存格式兼容旧版，但读取时把每一行当成数据，避免以 root 执行配置文件。
save_env() {
  local key escaped
  for key in DOMAIN PORT PASSWORD NODE_NAME EMAIL WEBROOT; do
    escaped=${!key}
    escaped=${escaped//\'/\'\\\'\'}
    printf "%s='%s'\n" "$key" "$escaped" || return 1
  done
}

load_env() {
  local entry key value quote="'" escaped="'\\''"
  [ -s "$ENV_FILE" ] || return 1
  DOMAIN='' PORT='' PASSWORD='' NODE_NAME='' EMAIL='' WEBROOT=''
  while IFS= read -r entry || [ -n "$entry" ]; do
    key=${entry%%=*}
    value=${entry#*=}
    case "$key" in DOMAIN|PORT|PASSWORD|NODE_NAME|EMAIL|WEBROOT) ;; *) return 1 ;; esac
    [[ "$value" == "$quote"*"$quote" && ${#value} -ge 2 ]] || return 1
    value=${value:1:${#value}-2}
    value=${value//"$escaped"/"$quote"}
    printf -v "$key" '%s' "$value"
  done < "$ENV_FILE"
  valid_domain "$DOMAIN" && valid_port "$PORT" && valid_password "$PASSWORD"
}

is_installed() { [ -s "$ENV_FILE" ] && [ -x "$BIN_FILE" ]; }
require_install() { load_env || error '未安装 AnyTLS，或安装配置无法读取'; }

lock_work() {
  command -v flock >/dev/null || error '需要 flock，请安装 util-linux 或运行新版安装脚本补齐依赖'
  exec 9>"$LOCK_FILE" || error "无法打开锁文件 $LOCK_FILE"
  flock -n 9 || error '有另一个 AnyTLS 操作正在运行，请稍后再试'
}

# 每次写入在同一文件系统上准备候选文件，旧内容保留至服务检查通过。
start_transaction() {
  local target
  mkdir -p "$WORK_DIR" || error "无法创建 $WORK_DIR"
  [ ! -L "$WORK_DIR" ] || error "无法保护 $WORK_DIR"
  chmod 700 "$WORK_DIR" || error "无法保护 $WORK_DIR"
  TX=$(mktemp -d "$WORK_DIR/.txn.XXXXXXXX") || error '无法创建事务目录'
  TX_TARGETS=("$@")
  TX_CHANGED=0 TX_COMMITTED=0 TX_WAS_ACTIVE=0 TX_SERVICE_CREATED=0 TX_MENU_CREATED=0 TX_RESTART=0
  TX_ACME_CONF=''
  trap finish_transaction EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkdir "$TX/old" || error '无法创建备份目录'
  if svc_active; then TX_WAS_ACTIVE=1; fi
  for target in "${TX_TARGETS[@]}"; do
    if [ -e "$target" ] || [ -L "$target" ]; then
      [ -f "$target" ] && [ ! -L "$target" ] || error "不能替换非普通文件 $target"
      cp -p -- "$target" "$TX/old/${target##*/}" || error "备份失败 $target"
    fi
  done
}

publish_files() {
  local target
  TX_CHANGED=1
  for target in "$@"; do
    mv -f -- "$TX/${target##*/}" "$target" || error "无法替换 $target"
  done
}

finish_transaction() {
  local rc=$? target failed=0
  trap - EXIT
  trap '' INT TERM
  if [ "$TX_COMMITTED" = 0 ]; then
    if [ "$TX_RESTART" = 1 ]; then svc_stop || true; fi
    if [ "$TX_CHANGED" = 1 ]; then
      for target in "${TX_TARGETS[@]}"; do
        if [ -e "$TX/old/${target##*/}" ]; then
          cp -p -- "$TX/old/${target##*/}" "$TX/restore" && mv -f -- "$TX/restore" "$target" || failed=1
        else
          rm -f -- "$target" || failed=1
        fi
      done
    fi
    if [ -n "$TX_ACME_CONF" ]; then
      if [ -f "$TX/old/acme-domain.conf" ]; then
        restore_acme_conf || failed=1
      else
        rm -f -- "$TX_ACME_CONF" || failed=1
      fi
    fi
    if [ "$TX_MENU_CREATED" = 1 ]; then remove_menu || failed=1; fi
    if [ "$TX_SERVICE_CREATED" = 1 ]; then remove_service || failed=1; fi
    if [ "$TX_RESTART" = 1 ] && [ "$TX_WAS_ACTIVE" = 1 ]; then
      svc_start && service_ready || failed=1
    fi
    if [ "$failed" = 1 ]; then
      warn "自动回滚未完成，备份保存在 $TX/old"
      exit 1
    fi
    if [ "$TX_CHANGED" = 1 ]; then warn '已恢复原有文件和服务运行状态'; fi
  fi
  rm -rf -- "$TX"
  exit "$rc"
}

prepare_core() {
  local requested="${1#v}" release name digest url
  if [ -n "$requested" ]; then
    valid_version "$requested" || error "无效的内核版本 $requested"
    release="$GH_RELEASES/tags/v$requested"
  else
    release="$GH_RELEASES/latest"
  fi
  fetch "$release" "$TX/release.json" || error '无法读取 sing-box 发布信息'
  CORE_TAG=$(jq -er '.tag_name | select(type == "string")' "$TX/release.json") || error '发布信息缺少版本号'
  valid_version "$CORE_TAG" || error '上游版本号格式不正确'
  if [ -n "$requested" ] && [ "${CORE_TAG#v}" != "$requested" ]; then error '上游返回版本与请求不一致'; fi
  name="sing-box-${CORE_TAG#v}-linux-$ARCH.tar.gz"
  digest=$(jq -er --arg name "$name" '.assets[] | select(.name == $name) | .digest | select(type == "string")' "$TX/release.json") || error "上游没有提供带校验值的资产 $name"
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || error "资产校验值无效 $name"
  url="https://github.com/SagerNet/sing-box/releases/download/$CORE_TAG/$name"
  info "下载 sing-box $CORE_TAG ($ARCH)"
  fetch "$url" "$TX/core.tar.gz" || error '内核下载失败'
  (cd "$TX" && printf '%s  core.tar.gz\n' "${digest#sha256:}" | sha256sum -c -) || error '内核 SHA-256 校验失败'
  tar -xOzf "$TX/core.tar.gz" "${name%.tar.gz}/sing-box" > "$TX/sing-box" || error '无法提取 sing-box'
  chmod 755 "$TX/sing-box" || error '无法设置候选内核权限'
  "$TX/sing-box" version >/dev/null || error '候选内核无法运行'
  printf '%s\n' "${CORE_TAG#v}" > "$TX/version" || error '无法保存版本号'
}

core_version() { "$BIN_FILE" version 2>/dev/null | sed -n '1s/^sing-box version \([^ ]*\).*/\1/p'; }

write_config() {
  local cert="$1" key="$2" listen='::'
  if [ ! -f /proc/net/if_inet6 ]; then listen='0.0.0.0'; fi
  jq -n --arg listen "$listen" --argjson port "$PORT" --arg password "$PASSWORD" \
    --arg domain "$DOMAIN" --arg cert "$cert" --arg key "$key" '
    {log:{level:"info",timestamp:true},inbounds:[{type:"anytls",tag:"anytls-in",listen:$listen,
     listen_port:$port,users:[{password:$password}],padding_scheme:[],
     tls:{enabled:true,server_name:$domain,certificate_path:$cert,key_path:$key}}],
     outbounds:[{type:"direct",tag:"direct"}]}'
}

svc() {
  case "$INIT" in
    systemd) systemctl "$1" anytls 9>&- ;;
    openrc) rc-service anytls "$1" 9>&- ;;
    *) return 1 ;;
  esac
}

svc_active() {
  case "$INIT" in
    systemd) systemctl is-active --quiet anytls ;;
    openrc) rc-service anytls status >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

svc_start() { svc start; }
svc_stop() { svc stop; }
svc_restart() { svc restart; }

svc_log() {
  case "$INIT" in
    systemd) journalctl -u anytls -n 40 --no-pager ;;
    openrc) tail -n 40 /var/log/anytls.log ;;
  esac
}

service_ready() {
  sleep 2
  svc_active
}

apply_service() {
  TX_RESTART=1
  if { if [ "$TX_WAS_ACTIVE" = 1 ]; then svc_restart; else svc_start; fi; } && service_ready; then return 0; fi
  svc_log >&2 || true
  error '服务启动检查失败'
}

write_service() {
  case "$INIT" in
    systemd)
      cat <<EOF
[Unit]
Description=AnyTLS service (sing-box)
After=network.target nss-lookup.target

[Service]
Type=exec
User=root
NoNewPrivileges=yes
WorkingDirectory=$WORK_DIR
ExecStart=$BIN_FILE run -c $CONF_FILE
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
      ;;
    openrc)
      cat <<EOF
#!/sbin/openrc-run
name="AnyTLS service (sing-box)"
command="$BIN_FILE"
command_args="run -c $CONF_FILE"
command_background="yes"
pidfile="/run/anytls.pid"
output_log="/var/log/anytls.log"
error_log="/var/log/anytls.log"
depend() { need net; after firewall; }
EOF
      ;;
  esac
}

create_service() {
  [ ! -e "$UNIT_FILE" ] && [ ! -L "$UNIT_FILE" ] || return 0
  TX_SERVICE_CREATED=1
  local tmp mode=644
  if [ "$INIT" = openrc ]; then mode=755; fi
  tmp=$(mktemp "${UNIT_FILE}.XXXXXXXX") || return 1
  if ! write_service > "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f "$tmp" "$UNIT_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [ "$INIT" = systemd ]; then
    systemctl daemon-reload && systemctl enable anytls
  else
    rc-update add anytls default
  fi
}

remove_service() {
  [ -e "$UNIT_FILE" ] || return 0
  if [ "$INIT" = systemd ]; then
    systemctl disable anytls || return 1
    rm -f -- "$UNIT_FILE" && systemctl daemon-reload
  else
    rc-update del anytls default && rm -f -- "$UNIT_FILE"
  fi
}

owns_menu() { [ -L "$MENU_FILE" ] && [ "$(readlink "$MENU_FILE")" = "$MANAGER_FILE" ]; }
menu_available() { owns_menu || { [ ! -e "$MENU_FILE" ] && [ ! -L "$MENU_FILE" ]; }; }

# 普通文件直接复制。进程替换和管道不可重读，其本地副本由当前已加载函数组成。
prepare_manager() {
  local dest="$1"
  if [ -f "$SCRIPT_SOURCE" ] && [[ "$SCRIPT_SOURCE" != /dev/fd/* && "$SCRIPT_SOURCE" != /proc/*/fd/* ]]; then
    install -m 755 -- "$SCRIPT_SOURCE" "$dest" || return 1
  else
    {
      printf '#!/usr/bin/env bash\n'
      declare -f
      # The generated launcher expands these variables at runtime.
    # shellcheck disable=SC2016
    printf '\nif [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi\n'
    } > "$dest" && chmod 755 "$dest" || return 1
  fi
  bash -n "$dest"
}

install_menu() {
  if owns_menu; then return 0; fi
  mkdir -p "${MENU_FILE%/*}" && ln -sT -- "$MANAGER_FILE" "$MENU_FILE" || return 1
  TX_MENU_CREATED=1
}

remove_menu() {
  if owns_menu; then rm -- "$MENU_FILE"; fi
}

install_acme() {
  local -a args=(--install --home "$ACME_HOME" --noprofile)
  if [ -x "$ACME_BIN" ]; then return 0; fi
  mkdir -p "$ACME_HOME" || error '无法创建 acme.sh 安装目录'
  if [ -n "$EMAIL" ]; then args+=(--accountemail "$EMAIL"); fi
  if ! command -v crontab >/dev/null; then args+=(--force); fi
  fetch "https://raw.githubusercontent.com/acmesh-official/acme.sh/$ACME_REVISION/acme.sh" "$TX/acme.sh" || error '下载 acme.sh 失败'
  (cd "$TX" && sh ./acme.sh "${args[@]}") && [ -x "$ACME_BIN" ] || error 'acme.sh 安装失败'
}

acme() { "$ACME_BIN" --home "$ACME_HOME" "$@"; }

backup_acme_conf() {
  local conf
  conf=$(acme --info -d "$DOMAIN" --ecc 2>/dev/null | sed -n 's/^DOMAIN_CONF=//p')
  [[ "$conf" == /*/"$DOMAIN.conf" && "$conf" != *$'\n'* ]] || error 'acme.sh 未返回可用的域名配置路径'
  if [ -e "$conf" ]; then
    [ -f "$conf" ] && [ ! -L "$conf" ] || error '无法备份此 acme.sh 域名配置'
    cp -p -- "$conf" "$TX/old/acme-domain.conf" || error '备份 acme.sh 域名配置失败'
  fi
  TX_ACME_CONF="$conf"
}

restore_acme_conf() {
  local restore
  restore=$(mktemp "${TX_ACME_CONF}.restore.XXXXXXXX") || return 1
  if cp -p -- "$TX/old/acme-domain.conf" "$restore" && mv -f -- "$restore" "$TX_ACME_CONF"; then return 0; fi
  rm -f -- "$restore"
  return 1
}

try_issue() {
  local rc=0
  acme --issue --server letsencrypt -d "$DOMAIN" --keylength ec-256 "${ISSUE_ARGS[@]}" "$@" || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 2 ]
}

issue_cert() {
  local old_port="$1"
  local -a ISSUE_ARGS=()
  if [ -n "$EMAIL" ]; then ISSUE_ARGS+=(--accountemail "$EMAIL"); fi
  if [ "$ACTION" = renew ] || [ "${FORCE_ISSUE:-0}" = 1 ]; then ISSUE_ARGS+=(--force); fi
  if [ -n "$WEBROOT" ]; then
    try_issue -w "$WEBROOT" || error 'webroot 验证失败，请检查站点路径和 80/TCP'
    return 0
  fi
  if ! port_in_use 80 && try_issue --standalone --httpport 80; then return 0; fi
  if port_in_use 443; then
    if [ "$old_port" != 443 ] || [ "$TX_WAS_ACTIVE" != 1 ]; then
      error '443/TCP 已被占用，请使用 --webroot 或释放验证端口'
    fi
    TX_RESTART=1
    svc_stop || error '临时停止 AnyTLS 失败'
    if port_in_use 443; then error '443/TCP 仍被占用，请使用 --webroot'; fi
  fi
  try_issue --alpn --tlsport 443 || error 'ACME 签发失败，请检查域名解析、80/443 和防火墙'
}

incoming_path() { printf '%s/incoming/%s' "$CERT_DIR" "$1"; }

collect_cert() {
  local inbox="$1" cert_pub key_pub
  [ -s "$inbox/cert.pem" ] && [ -s "$inbox/private.key" ] || error 'ACME 未交付证书或私钥'
  openssl x509 -in "$inbox/cert.pem" -noout -checkend 0 >/dev/null || error '证书无效或已过期'
  LC_ALL=C openssl x509 -in "$inbox/cert.pem" -noout -checkhost "$DOMAIN" > "$TX/x509-check" || error '证书与安装域名不匹配'
  grep -Fq ' does match certificate' "$TX/x509-check" || error '证书与安装域名不匹配'
  cert_pub=$(openssl x509 -in "$inbox/cert.pem" -noout -pubkey) || error '无法读取证书公钥'
  key_pub=$(openssl pkey -in "$inbox/private.key" -pubout) || error '无法读取私钥'
  [ "$cert_pub" = "$key_pub" ] || error '证书与私钥不匹配'
  install -m 600 -- "$inbox/private.key" "$TX/private.key" || error '无法准备私钥文件'
  install -m 644 -- "$inbox/cert.pem" "$TX/cert.pem" || error '无法准备证书文件'
}

configure_cert() {
  local inbox
  inbox=$(incoming_path "$DOMAIN")
  mkdir -p "$inbox" || error '无法创建证书写入目录'
  rm -f -- "$inbox/cert.pem" "$inbox/private.key" || error '无法清理旧候选证书'
  # --install-cert 会当场运行 hook。本次由持锁调用者部署，cron 下次续期由同一入口部署。
  ANYTLS_DEFER_DEPLOY=1 acme --install-cert -d "$DOMAIN" --ecc \
    --key-file "$inbox/private.key" --fullchain-file "$inbox/cert.pem" \
    --reloadcmd "if [ \"\${ANYTLS_DEFER_DEPLOY:-0}\" != 1 ]; then \"$MANAGER_FILE\" deploy-cert $DOMAIN; fi" || error 'acme.sh 部署证书失败'
  collect_cert "$inbox"
}

url_encode() {
  local LC_ALL=C value="$1" i byte
  for ((i=0; i<${#value}; i++)); do
    byte=${value:i:1}
    case "$byte" in [a-zA-Z0-9.~_-]) printf '%s' "$byte" ;; *) printf '%%%02X' "'$byte" ;; esac
  done
}

build_links() {
  local tag name
  tag=$(url_encode "$NODE_NAME")
  name=${NODE_NAME//\\/\\\\}
  name=${name//\"/\\\"}
  cat <<EOF
AnyTLS 节点信息（含密码，请妥善保存）

anytls://$PASSWORD@$DOMAIN:$PORT?idle_session_check_interval=30s&idle_session_timeout=30s&min_idle_session=5&security=tls&sni=$DOMAIN&fp=chrome#$tag

Clash / mihomo
- name: "$name"
  type: anytls
  server: $DOMAIN
  port: $PORT
  password: "$PASSWORD"
  client-fingerprint: chrome
  sni: $DOMAIN
  udp: true
  idle-session-check-interval: 30
  idle-session-timeout: 30
  skip-cert-verify: false
EOF
}

validate_install_params() {
  if [ "$NON_INTERACTIVE" = 1 ]; then
    PORT=${PORT:-$DEFAULT_PORT}
  else
    if [ -z "$DOMAIN" ]; then reading '请输入证书域名: ' DOMAIN ''; fi
    if [ -z "$PORT" ]; then reading '请输入监听端口: ' PORT "$DEFAULT_PORT"; fi
    if [ -z "$EMAIL" ]; then reading '请输入邮箱（可留空）: ' EMAIL ''; fi
  fi
  valid_domain "$DOMAIN" || error '请通过 --domain 提供有效域名'
  DOMAIN=${DOMAIN,,}
  valid_port "$PORT" || error "无效监听端口 $PORT"
  if [ -n "$PASSWORD" ]; then valid_password "$PASSWORD" || error '密码应为 6 至 64 位 URL 安全字符'; fi
  if [ -n "$CORE_VERSION" ]; then valid_version "$CORE_VERSION" || error "无效的内核版本 $CORE_VERSION"; fi
  if [ -n "$WEBROOT" ]; then [[ "$WEBROOT" == /* && -d "$WEBROOT" ]] || error 'webroot 必须是存在的绝对路径'; fi
  NODE_NAME=${NODE_NAME:-AnyTLS-$DOMAIN}
  local LC_ALL=C
  if [[ "$NODE_NAME$EMAIL$WEBROOT" =~ [[:cntrl:]] ]]; then error '节点名、邮箱和 webroot 不能包含控制字符'; fi
}

do_install() (
  need_root
  detect_os
  detect_init || error '需要 systemd 或 OpenRC'
  menu_available || error "$MENU_FILE 已被其他程序使用，请先处理同名文件"
  validate_install_params
  local reinstall_confirmed=0
  if is_installed && [ "$FORCE_INSTALL" = 0 ]; then
    if [ "$NON_INTERACTIVE" = 1 ]; then error '已安装，非交互重装需要 --force'; fi
    confirm '覆盖现有配置？' || exit 0
    reinstall_confirmed=1
  fi
  check_deps
  lock_work
  menu_available || error "$MENU_FILE 已被其他程序使用"
  local old_port='' old_domain='' old_webroot='' running=0 FORCE_ISSUE=0
  if is_installed; then
    [ "$FORCE_INSTALL" = 1 ] || [ "$reinstall_confirmed" = 1 ] || error '检测到另一项操作已完成安装，请重新执行安装命令'
    local saved
    saved=$(load_env && printf '%s %s\n%s' "$PORT" "${DOMAIN,,}" "$WEBROOT") || error '无法读取现有安装配置'
    {
      read -r old_port old_domain
      IFS= read -r old_webroot
    } <<< "$saved"
    if [ "$old_domain" = "$DOMAIN" ] && [ "$old_webroot" != "$WEBROOT" ]; then FORCE_ISSUE=1; fi
    if svc_active; then running=1; fi
  elif [ -e "$UNIT_FILE" ] || [ -L "$UNIT_FILE" ]; then
    error "已存在服务文件 $UNIT_FILE，请先确认旧安装状态"
  fi
  if port_in_use "$PORT" && { [ "$running" != 1 ] || [ "$PORT" != "$old_port" ]; }; then
    error "端口 $PORT 已被占用"
  fi
  if [ -z "$PASSWORD" ]; then PASSWORD=$(openssl rand -hex 16) || error '生成密码失败'; fi
  start_transaction "$BIN_FILE" "$CONF_FILE" "$ENV_FILE" "$KEY_FILE" "$CERT_FILE" "$INFO_FILE" "$MANAGER_FILE" "$WORK_DIR/version"
  ensure_cron || warn '未确认 cron 正常运行，请检查定时任务服务，或用 menu renew 手动续期'
  detect_arch
  prepare_core "${CORE_VERSION:-$DEFAULT_CORE_VERSION}"
  prepare_manager "$TX/manage.sh" || error '无法准备本地管理脚本'
  [ ! -L "$CERT_DIR" ] || error '证书目录不能是符号链接'
  install_acme
  backup_acme_conf
  issue_cert "$old_port"
  configure_cert
  write_config "$TX/cert.pem" "$TX/private.key" > "$TX/check.json" || error '无法生成候选配置'
  "$TX/sing-box" check -c "$TX/check.json" || error '候选配置校验失败'
  write_config "$CERT_FILE" "$KEY_FILE" > "$TX/config.json" || error '无法生成服务配置'
  save_env > "$TX/anytls.env" || error '无法保存安装参数'
  build_links > "$TX/anytls.txt" || error '无法写入安装配置'
  publish_files "$BIN_FILE" "$CONF_FILE" "$ENV_FILE" "$KEY_FILE" "$CERT_FILE" "$INFO_FILE" "$MANAGER_FILE" "$WORK_DIR/version"
  create_service || error '无法注册 AnyTLS 服务'
  apply_service
  install_menu || error '无法安装 menu 命令'
  TX_COMMITTED=1
  if [ -n "$old_domain" ] && [ "$old_domain" != "$DOMAIN" ]; then
    acme --remove -d "$old_domain" --ecc || warn "旧域名 $old_domain 的续期记录需要手动清理"
  fi
  info '安装完成，输入 menu 打开管理菜单'
  if [ "$NON_INTERACTIVE" = 0 ]; then cat "$INFO_FILE"; else info '连接凭据已保存，可用 menu info 查看'; fi
)

do_update() (
  need_root
  require_install
  detect_os
  detect_init || error '需要 systemd 或 OpenRC'
  check_deps
  lock_work
  require_install
  start_transaction "$BIN_FILE" "$WORK_DIR/version"
  detect_arch
  prepare_core "$CORE_VERSION"
  "$TX/sing-box" check -c "$CONF_FILE" || error '候选内核不兼容当前配置'
  publish_files "$BIN_FILE" "$WORK_DIR/version"
  apply_service
  TX_COMMITTED=1
  info "内核已更新至 $CORE_TAG"
)

deploy_cert() (
  local requested="$1"
  need_root
  detect_init || error '需要 systemd 或 OpenRC'
  lock_work
  require_install
  [ "$DOMAIN" = "$requested" ] || error '续期证书与当前 AnyTLS 域名不一致'
  start_transaction "$KEY_FILE" "$CERT_FILE"
  collect_cert "$(incoming_path "$DOMAIN")"
  publish_files "$KEY_FILE" "$CERT_FILE"
  "$BIN_FILE" check -c "$CONF_FILE" || error '续期证书配置校验失败'
  # 保留操作员主动停止的状态。运行中的服务必须通过启动检查。
  if [ "$TX_WAS_ACTIVE" = 1 ]; then apply_service; fi
  TX_COMMITTED=1
  info '续期证书已部署'
)

do_renew() (
  need_root
  detect_init || error '需要 systemd 或 OpenRC'
  lock_work
  require_install
  [ -x "$MANAGER_FILE" ] || error '请先用新版脚本重装以安装本地管理入口'
  start_transaction "$CERT_FILE" "$KEY_FILE"
  backup_acme_conf
  issue_cert "$PORT"
  configure_cert
  publish_files "$CERT_FILE" "$KEY_FILE"
  "$BIN_FILE" check -c "$CONF_FILE" || error '续期证书配置校验失败'
  if [ "$TX_WAS_ACTIVE" = 1 ]; then apply_service; fi
  TX_COMMITTED=1
  info '证书已更新'
)

change_config() (
  local kind="$1" new
  need_root
  detect_init || error '需要 systemd 或 OpenRC'
  lock_work
  require_install
  if [ "$kind" = port ]; then
    reading '新端口: ' new "$PORT"
    valid_port "$new" || error '端口不合法'
    if [ "$PORT" = "$new" ]; then info '端口未变化'; exit 0; fi
    if port_in_use "$new"; then error "端口 $new 已被占用"; fi
    local PORT="$new"
  else
    reading '新密码（留空自动生成）: ' new ''
    if [ -z "$new" ]; then new=$(openssl rand -hex 16) || error '生成密码失败'; fi
    valid_password "$new" || error '密码应为 6 至 64 位 URL 安全字符'
    PASSWORD="$new"
  fi
  start_transaction "$CONF_FILE" "$ENV_FILE" "$INFO_FILE"
  write_config "$CERT_FILE" "$KEY_FILE" > "$TX/config.json" || error '无法生成服务配置'
  save_env > "$TX/anytls.env" || error '无法保存安装参数'
  build_links > "$TX/anytls.txt" || error '无法保存候选配置'
  "$BIN_FILE" check -c "$TX/config.json" || error '候选配置校验失败'
  publish_files "$CONF_FILE" "$ENV_FILE" "$INFO_FILE"
  apply_service
  TX_COMMITTED=1
  cat "$INFO_FILE"
)

do_restart() (
  need_root
  detect_init || error '需要 systemd 或 OpenRC'
  lock_work
  require_install
  if ! svc_restart || ! service_ready; then svc_log >&2 || true; error '重启失败'; fi
  info '服务已重启'
)

do_uninstall() (
  need_root
  detect_init || error '需要 systemd 或 OpenRC'
  lock_work
  if [ "$FORCE_INSTALL" = 0 ]; then confirm '确认卸载 AnyTLS 并删除其本地配置？' || exit 2; fi
  if [ -f "$UNIT_FILE" ]; then
    is_installed || error '无法确认该服务属于当前安装，请检查本地配置'
    svc_stop || error '停止 AnyTLS 失败'
    remove_service || error '删除 AnyTLS 服务注册失败'
  fi
  if [ -x "$ACME_BIN" ] && load_env; then
    acme --remove -d "$DOMAIN" --ecc || warn "请手动清理域名 $DOMAIN 的续期记录"
  fi
  remove_menu || error '无法移除 menu 入口'
  rm -rf -- "$WORK_DIR" || error '无法删除所有 AnyTLS 文件'
  info '已卸载 AnyTLS'
)

do_status() {
  local state=未运行
  require_install
  if detect_init && svc_active; then state=运行中; fi
  printf '域名: %s\n端口: %s\n内核: %s\n服务: %s\n' "$DOMAIN" "$PORT" "$(core_version)" "$state"
  [ "$state" = 运行中 ]
}

do_info() { need_root; require_install; build_links; }

do_menu() {
  need_root
  require_install
  local choice
  while :; do
    info '========== AnyTLS 管理菜单 =========='
    (do_status) || true
    printf '%s\n' '1. 节点信息' '2. 修改端口' '3. 修改密码' '4. 重签证书' \
      '5. 更新内核' '6. 重启服务' '7. 查看日志' '8. 卸载' '0. 退出'
    reading '请选择: ' choice ''
    case "$choice" in
      1) (do_info) ;;
      2) change_config port ;;
      3) change_config password ;;
      4) (ACTION=renew; do_renew) ;;
      5) do_update ;;
      6) do_restart ;;
      7) (detect_init && svc_log) ;;
      8) if do_uninstall; then return 0; fi ;;
      0|'') return 0 ;;
      *) warn '无效选项' ;;
    esac
    reading '按回车返回菜单: ' choice ''
  done
}

usage() {
  cat <<'EOF'
AnyTLS 安装和管理

  bash anytls.sh [命令] [选项]
  menu [命令] [选项]

命令
  install  安装或重装
  menu     打开管理菜单
  info     查看节点凭据和分享链接
  status   查询服务状态
  restart  重启服务
  update   更新 sing-box，可用 --version 指定版本
  renew    手动重签证书
  uninstall 卸载，--force 跳过确认

安装选项
  --domain <域名>      证书域名
  --port <端口>        默认 8443
  --password <密码>    默认随机生成
  --name <节点名>      默认 AnyTLS-<域名>
  --email <邮箱>       可选的 ACME 邮箱
  --webroot <目录>     已有站点的 webroot
  --version <版本>     覆盖安装脚本固定的默认内核版本
  --force             确认重装
  --non-interactive   使用默认值并禁止读取输入
EOF
}

parse_args() {
  case "${1:-}" in
    install|menu|info|status|restart|update|renew|uninstall|help|-h|--help|deploy-cert)
      ACTION="$1"; shift ;;
  esac
  if [ "$ACTION" = deploy-cert ]; then
    [[ "$#" = 1 ]] || error '缺少有效的续期域名'
    valid_domain "$1" || error '缺少有效的续期域名'
    DEPLOY_DOMAIN="$1"
    return 0
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force)
        [[ "$ACTION" == install || "$ACTION" == uninstall || -z "$ACTION" ]] || error "$ACTION 不支持 $1"
        FORCE_INSTALL=1; shift ;;
      --non-interactive)
        [[ "$ACTION" == install || "$ACTION" == uninstall || -z "$ACTION" ]] || error "$ACTION 不支持 $1"
        NON_INTERACTIVE=1; shift ;;
      --domain|--port|--password|--name|--email|--webroot|--version)
        if [[ -n "$ACTION" && "$ACTION" != install && ! ( "$ACTION" = update && "$1" = --version ) ]]; then
          error "$ACTION 不支持 $1"
        fi
        [[ "$#" -ge 2 && "$2" != --* ]] || error "$1 缺少取值"
        case "$1" in
          --domain) DOMAIN="$2" ;;
          --port) PORT="$2" ;;
          --password) PASSWORD="$2" ;;
          --name) NODE_NAME="$2" ;;
          --email) EMAIL="$2" ;;
          --webroot) WEBROOT="$2" ;;
          --version) CORE_VERSION="$2" ;;
        esac
        INSTALL_OPTIONS=1
        shift 2 ;;
      *) error "未知参数 $1，请查看 help" ;;
    esac
  done
}

main() {
  set -o pipefail
  umask 077
  init_paths
  SCRIPT_SOURCE=${BASH_SOURCE[0]}
  ACTION='' DOMAIN='' PORT='' PASSWORD='' NODE_NAME='' EMAIL='' WEBROOT='' CORE_VERSION=''
  FORCE_INSTALL=0 NON_INTERACTIVE=0 INSTALL_OPTIONS=0 DEPLOY_DOMAIN=''
  if [ "${0##*/}" = menu ]; then
    case "${1:-}" in ''|--force|--non-interactive|--domain|--port|--password|--name|--email|--webroot|--version) ACTION=menu ;; esac
  fi
  parse_args "$@"
  if [ -z "$ACTION" ]; then
    if [ "${0##*/}" = menu ]; then ACTION=menu
    elif [ "$INSTALL_OPTIONS" = 1 ] || [ "$FORCE_INSTALL" = 1 ] || [ "$NON_INTERACTIVE" = 1 ] || ! is_installed; then ACTION=install
    else ACTION=menu; fi
  fi
  case "$ACTION" in
    install) do_install ;;
    menu) do_menu ;;
    info) do_info ;;
    status) do_status ;;
    restart) do_restart ;;
    update) do_update ;;
    renew) do_renew ;;
    uninstall) do_uninstall ;;
    deploy-cert) deploy_cert "$DEPLOY_DOMAIN" ;;
    help|-h|--help) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then main "$@"; fi
