#!/usr/bin/env bash
set -eo pipefail

script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/anytls.sh
# shellcheck source=anytls.sh
source "$script"

sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT
umask 077
init_paths
WORK_DIR="$sandbox/work"
MENU_FILE="$sandbox/bin/menu"
ACME_HOME="$sandbox/acme"
SYSTEMD_FILE="$sandbox/anytls.service"
set_paths
mkdir -p "$WORK_DIR" "$ACME_HOME"
export MSYS=winsymlinks:nativestrict
if [[ $(uname -s) == MINGW* || $(uname -s) == MSYS* ]]; then
  # Coreutils emulates symlinks on Windows without Developer Mode.
  export MSYS=winsymlinks:lnk
fi

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_error() {
  if "$@"; then fail "expected failure: $*"; fi
}

# Legacy .env quoting stays compatible and is parsed literally.
DOMAIN=tls.example.com PORT=8443 PASSWORD=aabcdef EMAIL='' WEBROOT='/site path'
# Exercise literal shell syntax in the stored node name.
# shellcheck disable=SC2016
NODE_NAME='门店'"'"' $(printf danger) "example"'
save_env > "$ENV_FILE"
original_name=$NODE_NAME
NODE_NAME=''
load_env || fail 'legacy env format was rejected'
[[ "$NODE_NAME" == "$original_name" ]] || fail 'node name did not round trip'
[[ $(url_encode '门店') == '%E9%97%A8%E5%BA%97' ]] || fail 'UTF-8 URL encoding'
printf 'printf broken > %s\n' "$sandbox/unwanted" >> "$ENV_FILE"
expect_error load_env
[[ ! -e "$sandbox/unwanted" ]] || fail 'config was executed'

# Argument errors are detected before mutation, optional values never prompt.
expect_error bash "$script" install --domain --port 8443
expect_error bash "$script" updaet
expect_error bash "$script" status --force
NON_INTERACTIVE=1 PORT='' NODE_NAME='' WEBROOT='' CORE_VERSION=''
DOMAIN='TLS.example.com'
validate_install_params </dev/null
[[ "$PORT" == 8443 && "$DOMAIN" == tls.example.com && -z "$EMAIL" ]] || fail 'non-interactive defaults'

# Both a normal file and a one-shot process substitution produce a local manager.
SCRIPT_SOURCE="$script"
prepare_manager "$MANAGER_FILE"
cmp -- "$script" "$MANAGER_FILE"
bash <(cat "$script"; printf '\nprepare_manager %q\n' "$sandbox/from-stream.sh") help > /dev/null
bash "$sandbox/from-stream.sh" help | grep -F '打开管理菜单' >/dev/null
cp -- "$sandbox/from-stream.sh" "$sandbox/menu"
menu_error=$(bash "$sandbox/menu" --domain tls.example.com 2>&1) && fail 'menu accepted an install flag without a subcommand'
[[ "$menu_error" == *'menu 不支持 --domain'* ]] || fail "unexpected menu error: $menu_error"
mkdir -p "${MENU_FILE%/*}"
printf 'other\n' > "$MENU_FILE"
expect_error menu_available
expect_error install_menu
remove_menu
[[ $(cat "$MENU_FILE") == other ]] || fail 'foreign menu was overwritten'
rm -- "$MENU_FILE"
# Link creation and execution require native POSIX symlink semantics.
if [[ $(uname -s) == Linux* ]]; then
  ln -s -- "$sandbox/from-stream.sh" "$sandbox/menu-target"
  "$sandbox/menu-target" help | grep -F '打开管理菜单' >/dev/null
  install_menu
  owns_menu || fail 'menu did not point to the local manager'
  "$MENU_FILE" help | grep -F '打开管理菜单' >/dev/null
  remove_menu
  [[ ! -L "$MENU_FILE" ]] || fail 'owned link not removed'
fi

# Mock service manager. A failed restart must restore the old content and state.
SVC_EVENTS="$sandbox/service-events"
svc_active() { return 0; }
restart_rc=1
svc_restart() { printf 'restart\n' >> "$SVC_EVENTS"; return "$restart_rc"; }
svc_start() { printf 'start\n' >> "$SVC_EVENTS"; }
svc_stop() { printf 'stop\n' >> "$SVC_EVENTS"; }
svc_log() { :; }
service_ready() { return 0; }
printf 'old\n' > "$CONF_FILE"
ACME_DOMAIN_CONF="$ACME_HOME/tls.example.com.conf"
printf 'old hook\n' > "$ACME_DOMAIN_CONF"
acme() { printf 'DOMAIN_CONF=%s\n' "$ACME_DOMAIN_CONF"; }
DOMAIN=tls.example.com
run_update() (
  start_transaction "$CONF_FILE"
  backup_acme_conf
  printf 'new hook\n' > "$ACME_DOMAIN_CONF"
  printf 'new\n' > "$TX/config.json"
  publish_files "$CONF_FILE"
  apply_service
  TX_COMMITTED=1
)
expect_error run_update
[[ $(cat "$CONF_FILE") == old ]] || fail 'old config was not restored'
[[ $(cat "$ACME_DOMAIN_CONF") == 'old hook' ]] || fail 'old renewal hook was not restored'
[[ $(cat "$SVC_EVENTS") == $'restart\nstop\nstart' ]] || fail 'original service was not started again'
restart_rc=0
run_update
[[ $(cat "$CONF_FILE") == new ]] || fail 'successful restart was not committed'
[[ $(cat "$ACME_DOMAIN_CONF") == 'new hook' ]] || fail 'new renewal hook was not committed'

# The certificate check rejects a hostname mismatch before touching live files.
mkdir "$sandbox/inbox" "$sandbox/staging"
TX="$sandbox/staging"
MSYS2_ARG_CONV_EXCL='/CN=' openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj /CN=tls.example.com -keyout "$sandbox/inbox/private.key" -out "$sandbox/inbox/cert.pem"
DOMAIN=tls.example.com
collect_cert "$sandbox/inbox"
cmp "$TX/cert.pem" "$sandbox/inbox/cert.pem"
DOMAIN=wrong.example.com
# shellcheck disable=SC2016
expect_error bash -c 'source "$1"; TX="$2"; DOMAIN=wrong.example.com; collect_cert "$3"' _ "$script" "$TX" "$sandbox/inbox"

printf 'AnyTLS 回归测试通过\n'
