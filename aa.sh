#!/usr/bin/env bash
set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_VERSION="0.2.0"
SINGBOX_VERSION="1.12.0"
WORKDIR="/opt/alpine-singbox-snellv5"
BIN_DIR="/usr/local/bin"
CONF_DIR="/etc/sing-box"
SINGBOX_BIN="$BIN_DIR/sing-box"
SINGBOX_CONF="$CONF_DIR/config.json"
SERVICE_DIR="/etc/init.d"
SINGBOX_SERVICE="$SERVICE_DIR/sing-box"
PROFILE_FILE="$WORKDIR/install.env"
SYSCTL_FILE="/etc/sysctl.d/99-singbox-snellv5.conf"

GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
BLUE='\033[34m'
BOLD='\033[1m'
RESET='\033[0m'

info(){ echo -e "${GREEN}[INFO]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
error(){ echo -e "${RED}[ERROR]${RESET} $*"; }
headline(){ echo -e "${BLUE}${BOLD}$*${RESET}"; }

require_root(){
  if [[ ${EUID} -ne 0 ]]; then
    error "请使用 root 运行此脚本"
    exit 1
  fi
}

pause(){
  read -r -p "按回车继续..."
}

trim(){
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

is_alpine(){
  [[ -f /etc/alpine-release ]]
}

need_cmd(){
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    error "缺少命令: $cmd"
    return 1
  }
}

install_deps(){
  require_root
  if ! is_alpine; then
    error "当前系统不是 Alpine，检测到: $(. /etc/os-release 2>/dev/null; echo ${PRETTY_NAME:-unknown})"
    return 1
  fi
  info "安装依赖中..."
  apk update
  apk add --no-cache bash curl wget tar openssl openrc iproute2 jq grep sed coreutils bind-tools
  mkdir -p "$WORKDIR" "$CONF_DIR"
  rc-update add local default >/dev/null 2>&1 || true
  info "依赖安装完成"
}

get_arch(){
  local machine
  machine=$(uname -m)
  case "$machine" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    *)
      error "不支持的架构: $machine"
      return 1
      ;;
  esac
}

random_port(){
  shuf -i 20000-60000 -n 1
}

random_token(){
  openssl rand -hex 8
}

prompt_default(){
  local prompt="$1"
  local default="$2"
  local input
  read -r -p "$prompt [$default]: " input
  input=$(trim "$input")
  if [[ -z "$input" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$input"
  fi
}

validate_port(){
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 )) || return 1
}

port_in_use(){
  local port="$1"
  ss -tuln | awk '{print $5}' | grep -Eq "(^|:)$port$"
}

validate_obfs(){
  local obfs="$1"
  [[ "$obfs" == "off" || "$obfs" == "http" || "$obfs" == "tls" ]]
}

validate_bool(){
  local value="$1"
  [[ "$value" == "true" || "$value" == "false" ]]
}

configure_profile(){
  require_root
  local listen_addr snell_port psk obfs_mode obfs_host log_level udp_enabled sniff_enabled inbound_tag dns_server

  listen_addr=$(prompt_default "请输入 sing-box 监听地址" "::")

  while true; do
    snell_port=$(prompt_default "请输入 Snell v5 监听端口" "$(random_port)")
    if ! validate_port "$snell_port"; then
      warn "端口格式不正确"
      continue
    fi
    if port_in_use "$snell_port"; then
      warn "端口 $snell_port 已被占用，请换一个"
      continue
    fi
    break
  done

  psk=$(prompt_default "请输入 Snell PSK" "$(random_token)")

  while true; do
    obfs_mode=$(prompt_default "请输入 obfs 模式(off/http/tls)" "off")
    validate_obfs "$obfs_mode" && break
    warn "obfs 仅支持 off / http / tls"
  done

  obfs_host=$(prompt_default "请输入 obfs host(仅 http/tls 有效)" "www.bing.com")
  log_level=$(prompt_default "请输入 sing-box 日志级别" "info")

  while true; do
    udp_enabled=$(prompt_default "是否开启 UDP(true/false)" "true")
    validate_bool "$udp_enabled" && break
    warn "请输入 true 或 false"
  done

  while true; do
    sniff_enabled=$(prompt_default "是否开启 sniff(true/false)" "false")
    validate_bool "$sniff_enabled" && break
    warn "请输入 true 或 false"
  done

  inbound_tag=$(prompt_default "请输入 inbound 标签" "snell-in")
  dns_server=$(prompt_default "请输入 sing-box DNS 服务器" "1.1.1.1")

  mkdir -p "$WORKDIR"
  cat > "$PROFILE_FILE" <<EOF
SINGBOX_VERSION="$SINGBOX_VERSION"
LISTEN_ADDR="$listen_addr"
SNELL_PORT="$snell_port"
SNELL_PSK="$psk"
SNELL_OBFS="$obfs_mode"
SNELL_OBFS_HOST="$obfs_host"
SB_LOG_LEVEL="$log_level"
SNELL_UDP="$udp_enabled"
SNELL_SNIFF="$sniff_enabled"
SNELL_TAG="$inbound_tag"
SB_DNS_SERVER="$dns_server"
EOF
  chmod 600 "$PROFILE_FILE"
  info "参数已保存到 $PROFILE_FILE"
}

load_profile(){
  if [[ ! -f "$PROFILE_FILE" ]]; then
    error "未找到配置参数文件: $PROFILE_FILE，请先执行 1) 安装/初始化"
    return 1
  fi
  # shellcheck disable=SC1090
  source "$PROFILE_FILE"
}

singbox_download_url(){
  local arch="$1"
  printf 'https://github.com/SagerNet/sing-box/releases/download/v%s/sing-box-%s-linux-%s.tar.gz' "$SINGBOX_VERSION" "$SINGBOX_VERSION" "$arch"
}

install_singbox_binary(){
  local arch url tmpdir extracted
  arch=$(get_arch)
  url=$(singbox_download_url "$arch")
  tmpdir=$(mktemp -d)
  info "下载 sing-box v$SINGBOX_VERSION"
  wget -O "$tmpdir/sing-box.tar.gz" "$url"
  tar -xzf "$tmpdir/sing-box.tar.gz" -C "$tmpdir"
  extracted=$(find "$tmpdir" -type f -name sing-box | head -n 1)
  [[ -n "$extracted" ]] || { error "未找到 sing-box 可执行文件"; return 1; }
  install -m 755 "$extracted" "$SINGBOX_BIN"
  rm -rf "$tmpdir"
  info "sing-box 已安装到 $SINGBOX_BIN"
}

write_singbox_config(){
  load_profile
  mkdir -p "$CONF_DIR"
  cat > "$SINGBOX_CONF" <<EOF
{
  "log": {
    "level": "${SB_LOG_LEVEL}",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "default-dns",
        "address": "${SB_DNS_SERVER}"
      }
    ]
  },
  "inbounds": [
    {
      "type": "snell",
      "tag": "${SNELL_TAG}",
      "listen": "${LISTEN_ADDR}",
      "listen_port": ${SNELL_PORT},
      "users": [
        {
          "name": "default",
          "password": "${SNELL_PSK}"
        }
      ],
      "version": 5,
      "udp": ${SNELL_UDP},
      "sniff": ${SNELL_SNIFF}$(if [[ "$SNELL_OBFS" != "off" ]]; then printf ',\n      "obfs": {\n        "enabled": true,\n        "type": "%s",\n        "host": "%s"\n      }' "$SNELL_OBFS" "$SNELL_OBFS_HOST"; fi)
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF
  chmod 600 "$SINGBOX_CONF"
  info "已写入 $SINGBOX_CONF"
}

write_openrc_service(){
  cat > "$SINGBOX_SERVICE" <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
depend() {
  need net
}
EOF
  chmod +x "$SINGBOX_SERVICE"
  rc-update add sing-box default >/dev/null 2>&1 || true
  info "OpenRC 服务脚本已写入: $SINGBOX_SERVICE"
}

enable_sysctl(){
  cat > "$SYSCTL_FILE" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.rmem_max=67108864
net.core.wmem_max=67108864
EOF
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
  info "已写入 $SYSCTL_FILE"
}

cleanup_legacy_snell(){
  rc-service snell-server stop >/dev/null 2>&1 || true
  rc-update del snell-server default >/dev/null 2>&1 || true
  rm -f /etc/init.d/snell-server /usr/local/bin/snell-server
  rm -rf /etc/snell
}

validate_singbox_config(){
  need_cmd "$SINGBOX_BIN"
  "$SINGBOX_BIN" check -c "$SINGBOX_CONF"
}

install_all(){
  install_deps
  configure_profile
  install_singbox_binary
  write_singbox_config
  write_openrc_service
  enable_sysctl
  cleanup_legacy_snell
  validate_singbox_config
  start_service
}

start_service(){
  need_cmd rc-service
  validate_singbox_config
  rc-service sing-box restart || rc-service sing-box start
  info "sing-box 启动命令已执行"
}

stop_service(){
  need_cmd rc-service
  rc-service sing-box stop || true
  info "sing-box 停止命令已执行"
}

restart_service(){
  stop_service
  start_service
}

status_service(){
  if rc-service sing-box status >/dev/null 2>&1; then
    echo -e "${GREEN}运行中${RESET}"
  else
    echo -e "${RED}未运行${RESET}"
  fi
}

show_status(){
  clear
  headline "Alpine + sing-box Snell v5 状态"
  echo "系统: $(cat /etc/alpine-release 2>/dev/null || echo unknown)"
  echo "sing-box: $(status_service)"
  echo "sing-box 版本: $($SINGBOX_BIN version 2>/dev/null | head -n1 || echo 未安装)"
  echo "监听端口: $(jq -r '.inbounds[0].listen_port // "未配置"' "$SINGBOX_CONF" 2>/dev/null || echo 未配置)"
  echo "协议版本: $(jq -r '.inbounds[0].version // "未配置"' "$SINGBOX_CONF" 2>/dev/null || echo 未配置)"
  echo "OBFS: $(if [[ -f "$SINGBOX_CONF" ]]; then jq -r 'if .inbounds[0].obfs then .inbounds[0].obfs.type else "off" end' "$SINGBOX_CONF"; else echo 未配置; fi)"
  echo "OpenRC 开机启动:"
  rc-update show default | grep 'sing-box' || true
}

show_config(){
  clear
  headline "sing-box 配置"
  if [[ -f "$SINGBOX_CONF" ]]; then
    sed -n '1,220p' "$SINGBOX_CONF"
  else
    echo "未找到 $SINGBOX_CONF"
  fi
}

reconfigure(){
  configure_profile
  write_singbox_config
  validate_singbox_config
  restart_service
}

show_client_hint(){
  load_profile
  clear
  headline "客户端参数"
  echo "协议: Snell v5"
  echo "地址: ${SNELL_OBFS_HOST}"
  echo "端口: ${SNELL_PORT}"
  echo "PSK: ${SNELL_PSK}"
  echo "UDP: ${SNELL_UDP}"
  echo "OBFS: ${SNELL_OBFS}"
  if [[ "$SNELL_OBFS" != "off" ]]; then
    echo "OBFS Host: ${SNELL_OBFS_HOST}"
  fi
  echo "DNS: ${SB_DNS_SERVER}"
  echo
  echo "说明: 当前为纯 sing-box 承载的 Snell v5 inbound，不再依赖独立 snell-server。"
}

uninstall_all(){
  stop_service || true
  rc-update del sing-box default >/dev/null 2>&1 || true
  rm -f "$SINGBOX_SERVICE" "$SINGBOX_BIN"
  rm -rf "$CONF_DIR" "$WORKDIR"
  rm -f "$SYSCTL_FILE"
  cleanup_legacy_snell
  info "已卸载纯 sing-box Snell v5 环境"
}

main_menu(){
  while true; do
    clear
    headline "Alpine 纯 sing-box Snell v5 菜单管理脚本 v${SCRIPT_VERSION}"
    echo "[1] 安装/初始化"
    echo "[2] 启动 sing-box"
    echo "[3] 停止 sing-box"
    echo "[4] 重启 sing-box"
    echo "[5] 查看状态"
    echo "[6] 查看配置"
    echo "[7] 修改配置并重载"
    echo "[8] 查看客户端参数"
    echo "[9] 卸载"
    echo "[0] 退出"
    echo
    read -r -p "请选择: " choice
    case "$choice" in
      1) install_all; pause ;;
      2) start_service; pause ;;
      3) stop_service; pause ;;
      4) restart_service; pause ;;
      5) show_status; pause ;;
      6) show_config; pause ;;
      7) reconfigure; pause ;;
      8) show_client_hint; pause ;;
      9) uninstall_all; pause ;;
      0) exit 0 ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

require_root
main_menu
