#!/usr/bin/env bash
set -euo pipefail

CFG="/etc/snell-v5"
BIN="/usr/local/bin/snell-server-v5"
SERVICE="snell-v5"
DEFAULT_VERSION="5.0.1"

red='\033[31m'
green='\033[32m'
yellow='\033[33m'
cyan='\033[36m'
reset='\033[0m'

info() { echo -e "${yellow}[!]${reset} $*"; }
ok() { echo -e "${green}[✔]${reset} $*"; }
err() { echo -e "${red}[✘]${reset} $*" >&2; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "请以 root 身份运行"
    exit 1
  fi
}

detect_distro() {
  if [[ -f /etc/alpine-release ]]; then
    DISTRO="alpine"
  elif [[ -f /etc/redhat-release ]]; then
    DISTRO="centos"
  elif [[ -f /etc/lsb-release ]] && grep -q "Ubuntu" /etc/lsb-release; then
    DISTRO="ubuntu"
  elif [[ -f /etc/os-release ]] && grep -q "Ubuntu" /etc/os-release; then
    DISTRO="ubuntu"
  else
    DISTRO="debian"
  fi
}

check_cmd() {
  command -v "$1" >/dev/null 2>&1
}

map_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "aarch64" ;;
    armv7l|armv7) echo "armv7l" ;;
    *) return 1 ;;
  esac
}

listen_addr() {
  if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
    echo "::"
  else
    echo "0.0.0.0"
  fi
}

fmt_hostport() {
  local host="$1" port="$2"
  if [[ "$host" == *:* ]]; then
    printf '[%s]:%s' "$host" "$port"
  else
    printf '%s:%s' "$host" "$port"
  fi
}

ensure_deps() {
  detect_distro
  case "$DISTRO" in
    alpine)
      apk add --no-cache curl unzip openssl >/dev/null
      if ! check_cmd upx; then apk add --no-cache upx >/dev/null || true; fi
      ;;
    debian|ubuntu)
      apt-get update -qq >/dev/null
      apt-get install -y -qq curl unzip openssl >/dev/null
      ;;
    centos)
      yum install -y -q curl unzip openssl >/dev/null
      ;;
  esac
}

get_latest_version() {
  local page
  page=$(curl -sL --connect-timeout 5 --max-time 10 "https://kb.nssurge.com/surge-knowledge-base/release-notes/snell.md" 2>/dev/null || true)
  echo "$page" | grep -oE '^##[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | sed -E 's/^##[[:space:]]+v?//' || true
}

install_snell_v5() {
  local version="${1:-}"
  local arch tmp url
  arch=$(map_arch) || { err "不支持的架构: $(uname -m)"; return 1; }

  if [[ -z "$version" ]]; then
    version=$(get_latest_version)
  fi
  [[ -z "$version" ]] && version="$DEFAULT_VERSION"

  tmp=$(mktemp -d)
  url="https://dl.nssurge.com/snell/snell-server-v${version}-linux-${arch}.zip"
  info "下载 Snell v5 v${version}..."
  curl -fsSL --connect-timeout 60 "$url" -o "$tmp/snell.zip"
  unzip -oq "$tmp/snell.zip" -d "$tmp/"
  install -m 755 "$tmp/snell-server" "$BIN"

  if [[ "${DISTRO:-}" == "alpine" ]] && check_cmd upx; then
    upx -d "$BIN" >/dev/null 2>&1 || true
  fi

  rm -rf "$tmp"
  ok "Snell v5 已安装到 $BIN"
}

gen_config() {
  local psk="$1" port="$2" version="${3:-5}"
  mkdir -p "$CFG"

  local host ipv6_enabled
  host=$(listen_addr)
  ipv6_enabled="false"
  [[ "$host" == "::" ]] && ipv6_enabled="true"

  cat > "$CFG/snell-v5.conf" <<EOF
[snell-server]
listen = $(fmt_hostport "$host" "$port")
psk = $psk
version = $version
ipv6 = $ipv6_enabled
obfs = off
EOF

  chmod 600 "$CFG/snell-v5.conf"
  ok "配置已生成: $CFG/snell-v5.conf"
}

create_service() {
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=Snell v5 Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
ExecStart=${BIN} -c ${CFG}/snell-v5.conf
Restart=on-failure
RestartSec=5s
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
  ok "systemd 服务已创建: ${SERVICE}"
}

restart_service() {
  systemctl restart "$SERVICE"
  systemctl --no-pager --full status "$SERVICE" | sed -n '1,20p'
}

show_info() {
  local ip
  ip=$(curl -4s --max-time 5 https://api.ipify.org 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -6s --max-time 5 https://api64.ipify.org 2>/dev/null || true)

  echo "----------------------------------------"
  echo "配置文件: $CFG/snell-v5.conf"
  echo "二进制:   $BIN"
  [[ -n "$ip" ]] && echo "服务器IP: $ip"
  echo "服务名:   $SERVICE"
  echo "----------------------------------------"
  [[ -f "$CFG/snell-v5.conf" ]] && cat "$CFG/snell-v5.conf"
  echo "----------------------------------------"
}

uninstall_all() {
  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE}.service"
  systemctl daemon-reload || true
  rm -f "$BIN"
  rm -rf "$CFG"
  ok "Snell v5 已卸载"
}

interactive_install() {
  local port psk version
  read -rp "请输入监听端口 [默认 443]: " port
  port=${port:-443}
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    err "端口无效"
    return 1
  fi

  read -rp "请输入 PSK（留空自动生成）: " psk
  [[ -z "$psk" ]] && psk=$(openssl rand -base64 32 | tr -d '\n')

  read -rp "请输入 Snell 协议版本 [默认 5]: " version
  version=${version:-5}

  ensure_deps
  install_snell_v5
  gen_config "$psk" "$port" "$version"
  create_service
  restart_service
  show_info
}

menu() {
  while true; do
    clear
    echo "Snell v5 "
    echo "----------------------------------------"
    echo "1) 安装 / 重装 Snell v5"
    echo "2) 查看配置"
    echo "3) 重启服务"
    echo "4) 卸载"
    echo "0) 退出"
    echo "----------------------------------------"
    read -rp "请输入选项 [0-4]: " choice
    case "$choice" in
      1) interactive_install ; read -n 1 -s -r -p "按任意键继续..." ;;
      2) show_info ; read -n 1 -s -r -p "按任意键继续..." ;;
      3) restart_service ; read -n 1 -s -r -p "按任意键继续..." ;;
      4) uninstall_all ; read -n 1 -s -r -p "按任意键继续..." ;;
      0) exit 0 ;;
      *) err "无效选项"; sleep 1 ;;
    esac
  done
}

main() {
  require_root
  menu
}

main "$@"
