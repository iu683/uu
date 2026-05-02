#!/usr/bin/env bash
set -euo pipefail

CFG="/etc/snell-v5"
BIN="/usr/local/bin/snell-server-v5"
SERVICE="snell-v5"
DEFAULT_VERSION="5.0.1"
SNELL_RELEASE_NOTES_URL="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell.md"
SNELL_RELEASE_NOTES_ZH_URL="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell.md"

R='\e[31m'; G='\e[32m'; Y='\e[33m'; C='\e[36m'; W='\e[97m'; NC='\e[0m'

_info() { echo -e "${Y}[!]${NC} $*"; }
_ok() { echo -e "${G}[✔]${NC} $*"; }
_err() { echo -e "${R}[✘]${NC} $*" >&2; }
_warn() { echo -e "${C}[~]${NC} $*"; }

require_root() {
  [[ $(id -u) -eq 0 ]] || { _err "请以 root 身份运行"; exit 1; }
}

require_alpine() {
  [[ -f /etc/alpine-release ]] || { _err "此脚本仅适用于 Alpine Linux"; exit 1; }
}

check_cmd() { command -v "$1" >/dev/null 2>&1; }

_map_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "aarch64" ;;
    armv7l|armv7) echo "armv7l" ;;
    *) return 1 ;;
  esac
}

_has_ipv6() {
  ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'
}

_can_dual_stack_listen() {
  [[ -r /proc/sys/net/ipv6/bindv6only ]] || return 1
  [[ "$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo 1)" == "0" ]]
}

_listen_addr() {
  if _has_ipv6 && _can_dual_stack_listen; then
    echo "::"
  else
    echo "0.0.0.0"
  fi
}

_fmt_hostport() {
  local host="$1" port="$2"
  if [[ "$host" == *:* ]]; then
    printf '[%s]:%s' "$host" "$port"
  else
    printf '%s:%s' "$host" "$port"
  fi
}

ensure_deps() {
  apk add --no-cache curl unzip openssl bash iproute2 >/dev/null
  if ! check_cmd upx; then
    apk add --no-cache upx >/dev/null || true
  fi
}

_get_snell_versions_from_kb() {
  local limit="${1:-10}" result
  result=$(curl -sL --connect-timeout 5 --max-time 10 "$SNELL_RELEASE_NOTES_URL" 2>/dev/null || true)
  echo "$result" | grep -oE '^##[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+' | sed -E 's/^##[[:space:]]+v?//' | head -n "$limit"
}

_get_snell_latest_version() {
  local version
  version=$(_get_snell_versions_from_kb 1 | head -n 1)
  [[ -z "$version" ]] && version="$DEFAULT_VERSION"
  echo "$version"
}

_get_snell_changelog_from_kb() {
  local version="$1" result
  result=$(curl -sL --connect-timeout 5 --max-time 10 "$SNELL_RELEASE_NOTES_ZH_URL" 2>/dev/null || true)
  awk -v ver="## ${version}" '
    $0 == ver {show=1; next}
    /^## / && show {exit}
    show {print}
  ' <<< "$result"
}

_get_snell_v5_version() {
  local output version
  if check_cmd snell-server-v5; then
    output=$(snell-server-v5 --version 2>&1 || true)
    version=$(echo "$output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    [[ -n "$version" ]] && { echo "$version"; return; }
  fi
  echo "未安装"
}

install_snell_v5() {
  local channel="${1:-stable}"
  local force="${2:-false}"
  local version_override="${3:-}"
  local exists=false action="安装" channel_label="稳定版"

  if check_cmd snell-server-v5; then
    exists=true
    [[ "$force" != "true" ]] && { _ok "Snell v5 已安装"; return 0; }
  fi
  [[ "$exists" == "true" ]] && action="更新"
  if [[ "$channel" == "prerelease" || "$channel" == "test" || "$channel" == "beta" ]]; then
    _warn "Snell v5 未提供预发布版本，使用稳定版"
    channel="stable"
  fi

  local sarch version tmp url
  sarch=$(_map_arch) || { _err "不支持的架构"; return 1; }

  if [[ -n "$version_override" ]]; then
    _info "$action Snell v5 (版本 v$version_override)..."
    version="$version_override"
  else
    _info "$action Snell v5 (获取最新${channel_label})..."
    version=$(_get_snell_latest_version)
  fi

  [[ -z "$version" ]] && version="$DEFAULT_VERSION"
  [[ "$version" =~ ^[0-9A-Za-z._-]+$ ]] || { _err "无效的版本号格式: $version"; return 1; }

  tmp=$(mktemp -d)
  url="https://dl.nssurge.com/snell/snell-server-v${version}-linux-${sarch}.zip"
  if curl -sLo "$tmp/snell.zip" --connect-timeout 60 "$url"; then
    unzip -oq "$tmp/snell.zip" -d "$tmp/" && install -m 755 "$tmp/snell-server" "$BIN"
    if check_cmd upx; then
      upx -d "$BIN" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp"
    _ok "Snell v$version 已安装"
    return 0
  fi
  rm -rf "$tmp"
  _err "下载失败"
  return 1
}

gen_snell_link() {
  local ip="$1" port="$2" psk="$3" version="${4:-5}" name="${5:-Snell-v${version}}"
  printf 'snell://%s@%s:%s?version=%s#%s\n' "$psk" "$ip" "$port" "$version" "$name"
}

gen_snell_v5_server_config() {
  local psk="$1" port="$2" version="${3:-5}"
  mkdir -p "$CFG"

  local listen_addr ipv6_enabled
  listen_addr=$(_listen_addr)
  ipv6_enabled="false"
  [[ "$listen_addr" == "::" ]] && ipv6_enabled="true"

  cat > "$CFG/snell-v5.conf" << EOF
[snell-server]
listen = $(_fmt_hostport "$listen_addr" "$port")
psk = $psk
version = $version
ipv6 = $ipv6_enabled
obfs = off
EOF

  chmod 600 "$CFG/snell-v5.conf"
  _ok "配置已生成: $CFG/snell-v5.conf"
}

create_openrc_service() {
  mkdir -p /etc/init.d
  cat >"/etc/init.d/${SERVICE}" <<EOF
#!/sbin/openrc-run
name="Proxy Server (snell-v5)"
command="${BIN}"
command_args="-c ${CFG}/snell-v5.conf"
command_background="yes"
pidfile="/run/${SERVICE}.pid"
depend() { need net; }
EOF
  chmod +x "/etc/init.d/${SERVICE}"
  rc-update add "$SERVICE" default >/dev/null 2>&1 || true
  _ok "OpenRC 服务已创建: /etc/init.d/${SERVICE}"
}

svc() {
  local action="$1" name="$2"
  case "$action" in
    start|restart) rc-service "$name" "$action" ;;
    stop) rc-service "$name" stop >/dev/null 2>&1 || true ;;
    enable) rc-update add "$name" default >/dev/null 2>&1 || true ;;
    disable) rc-update del "$name" default >/dev/null 2>&1 || true ;;
    reload) rc-service "$name" reload >/dev/null 2>&1 || rc-service "$name" restart >/dev/null 2>&1 ;;
    status) rc-service "$name" status >/dev/null 2>&1 ;;
  esac
}

restart_service() {
  svc restart "$SERVICE"
  rc-service "$SERVICE" status || true
}

show_info() {
  local ip port psk version
  ip=$(curl -4s --max-time 5 https://api.ipify.org 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -6s --max-time 5 https://api64.ipify.org 2>/dev/null || true)

  echo "----------------------------------------"
  echo "配置文件: $CFG/snell-v5.conf"
  echo "二进制:   $BIN"
  [[ -n "$ip" ]] && echo "服务器IP: $ip"
  echo "服务名:   $SERVICE (OpenRC)"
  echo "当前版本: $(_get_snell_v5_version)"
  echo "----------------------------------------"
  [[ -f "$CFG/snell-v5.conf" ]] && cat "$CFG/snell-v5.conf"
  echo "----------------------------------------"

  if [[ -f "$CFG/snell-v5.conf" && -n "$ip" ]]; then
    port=$(awk -F'= ' '/^listen = /{print $2}' "$CFG/snell-v5.conf" | sed -E 's/^.*:([0-9]+)$/\1/' | head -n1)
    psk=$(awk -F'= ' '/^psk = /{print $2}' "$CFG/snell-v5.conf" | head -n1)
    version=$(awk -F'= ' '/^version = /{print $2}' "$CFG/snell-v5.conf" | head -n1)
    [[ -n "$port" && -n "$psk" ]] && echo "节点链接: $(gen_snell_link "$ip" "$port" "$psk" "${version:-5}" "Snell-v${version:-5}")"
    echo "----------------------------------------"
  fi
}

show_versions() {
  local current latest
  current=$(_get_snell_v5_version)
  latest=$(_get_snell_latest_version)
  echo "----------------------------------------"
  echo -e "  ${W}Snell v5${NC}"
  echo -e "    当前版本: ${G}${current}${NC}"
  echo -e "    稳定版本: ${C}${latest}${NC}"
  echo "----------------------------------------"
}

show_changelog() {
  local version
  version=$(_get_snell_latest_version)
  echo "----------------------------------------"
  echo "Snell v5 最新版本: $version"
  echo "----------------------------------------"
  _get_snell_changelog_from_kb "$version" || true
  echo "----------------------------------------"
}

uninstall_all() {
  svc stop "$SERVICE"
  svc disable "$SERVICE"
  rm -f "/etc/init.d/${SERVICE}"
  rm -f "$BIN"
  rm -rf "$CFG"
  _ok "Snell v5 已卸载"
}

interactive_install() {
  local port psk version
  read -rp "请输入监听端口 [默认 443]: " port
  port=${port:-443}
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    _err "端口无效"
    return 1
  fi

  read -rp "请输入 PSK（留空自动生成）: " psk
  [[ -z "$psk" ]] && psk=$(openssl rand -base64 32 | tr -d '\n')

  read -rp "请输入 Snell 协议版本 [默认 5]: " version
  version=${version:-5}

  ensure_deps
  install_snell_v5 stable true
  gen_snell_v5_server_config "$psk" "$port" "$version"
  create_openrc_service
  svc enable "$SERVICE"
  restart_service
  show_info
}

pause_wait() {
  read -n 1 -s -r -p "按任意键继续..." || true
  echo
}

menu() {
  while true; do
    clear
    echo -e "${C}Snell v5 Alpine${NC}"
    echo "----------------------------------------"
    echo "1) 安装 / 重装 Snell v5"
    echo "2) 查看配置 / 节点信息"
    echo "3) 重启服务"
    echo "4) 卸载"
    echo "5) 查看版本信息"
    echo "6) 查看更新日志"
    echo "0) 退出"
    echo "----------------------------------------"
    read -rp "请输入选项 [0-6]: " choice
    case "$choice" in
      1) interactive_install; pause_wait ;;
      2) show_info; pause_wait ;;
      3) restart_service; pause_wait ;;
      4) uninstall_all; pause_wait ;;
      5) show_versions; pause_wait ;;
      6) show_changelog; pause_wait ;;
      0) exit 0 ;;
      *) _err "无效选项"; sleep 1 ;;
    esac
  done
}

main() {
  require_root
  require_alpine
  menu
}

main "$@"
