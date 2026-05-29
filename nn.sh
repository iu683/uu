#!/usr/bin/env bash
set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_VERSION="0.3.0"
SINGBOX_VERSION="1.12.0"
WORKDIR="/opt/alpine-singbox-tuicv5"
BIN_DIR="/usr/local/bin"
CONF_DIR="/etc/sing-box"
SINGBOX_BIN="$BIN_DIR/sing-box"
SINGBOX_CONF="$CONF_DIR/config.json"
SERVICE_DIR="/etc/init.d"
SINGBOX_SERVICE="$SERVICE_DIR/sing-box"
PROFILE_FILE="$WORKDIR/install.env"
CERT_DIR="$WORKDIR/certs"
CERT_FILE="$CERT_DIR/cert.pem"
KEY_FILE="$CERT_DIR/key.pem"
SYSCTL_FILE="/etc/sysctl.d/99-singbox-tuicv5.conf"

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
  apk add --no-cache bash curl wget tar openssl openrc iproute2 jq grep sed coreutils bind-tools python3
  mkdir -p "$WORKDIR" "$CONF_DIR" "$CERT_DIR"
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

random_uuid(){
  cat /proc/sys/kernel/random/uuid
}

random_password(){
  openssl rand -hex 16
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

validate_bool(){
  local value="$1"
  [[ "$value" == "true" || "$value" == "false" ]]
}

validate_cc(){
  local value="$1"
  [[ "$value" == "cubic" || "$value" == "new_reno" || "$value" == "bbr" ]]
}

validate_alpn(){
  local value="$1"
  [[ "$value" == "h3" || "$value" == "h3,hq-interop" || "$value" == "h3,hq-interop,hq-29" ]]
}

configure_profile(){
  require_root
  local listen_addr tuic_port uuid password congestion_control zero_rtt heartbeat auth_timeout domain sniff_enabled alpn_value tls_mode

  listen_addr=$(prompt_default "请输入 TUIC 监听地址" "::")

  while true; do
    tuic_port=$(prompt_default "请输入 TUIC v5 监听端口" "$(random_port)")
    if ! validate_port "$tuic_port"; then
      warn "端口格式不正确"
      continue
    fi
    if port_in_use "$tuic_port"; then
      warn "端口 $tuic_port 已被占用，请换一个"
      continue
    fi
    break
  done

  uuid=$(prompt_default "请输入 TUIC UUID" "$(random_uuid)")
  password=$(prompt_default "请输入 TUIC 密码" "$(random_password)")

  while true; do
    congestion_control=$(prompt_default "请输入拥塞控制(cubic/new_reno/bbr)" "bbr")
    validate_cc "$congestion_control" && break
    warn "仅支持 cubic / new_reno / bbr"
  done

  auth_timeout=$(prompt_default "请输入认证超时" "3s")
  heartbeat=$(prompt_default "请输入心跳间隔" "10s")
  domain=$(prompt_default "请输入 TLS 域名(证书 CN / SNI)" "bing.com")

  while true; do
    zero_rtt=$(prompt_default "是否启用 0-RTT(true/false，建议 false)" "false")
    validate_bool "$zero_rtt" && break
    warn "请输入 true 或 false"
  done

  while true; do
    sniff_enabled=$(prompt_default "是否开启 sniff(true/false)" "false")
    validate_bool "$sniff_enabled" && break
    warn "请输入 true 或 false"
  done

  while true; do
    alpn_value=$(prompt_default "请输入 ALPN(h3 / h3,hq-interop / h3,hq-interop,hq-29)" "h3")
    validate_alpn "$alpn_value" && break
    warn "ALPN 值不在预设范围内"
  done

  tls_mode=$(prompt_default "证书模式(self=自签 / custom=自定义)" "self")

  mkdir -p "$WORKDIR"
  cat > "$PROFILE_FILE" <<EOF
SINGBOX_VERSION="$SINGBOX_VERSION"
LISTEN_ADDR="$listen_addr"
TUIC_PORT="$tuic_port"
TUIC_UUID="$uuid"
TUIC_PASSWORD="$password"
TUIC_CC="$congestion_control"
TUIC_AUTH_TIMEOUT="$auth_timeout"
TUIC_HEARTBEAT="$heartbeat"
TUIC_DOMAIN="$domain"
TUIC_ZERO_RTT="$zero_rtt"
TUIC_SNIFF="$sniff_enabled"
TUIC_ALPN="$alpn_value"
TLS_MODE="$tls_mode"
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

generate_self_signed_cert(){
  load_profile
  mkdir -p "$CERT_DIR"
  info "生成自签 TLS 证书"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -days 3650 \
    -subj "/CN=${TUIC_DOMAIN}" >/dev/null 2>&1
  chmod 600 "$KEY_FILE" "$CERT_FILE"
}

prepare_certificate(){
  load_profile
  mkdir -p "$CERT_DIR"
  if [[ "$TLS_MODE" == "custom" ]]; then
    local custom_cert custom_key
    while true; do
      custom_cert=$(prompt_default "请输入现有证书路径" "$CERT_FILE")
      [[ -f "$custom_cert" ]] && break
      warn "证书文件不存在"
    done
    while true; do
      custom_key=$(prompt_default "请输入现有私钥路径" "$KEY_FILE")
      [[ -f "$custom_key" ]] && break
      warn "私钥文件不存在"
    done
    cp "$custom_cert" "$CERT_FILE"
    cp "$custom_key" "$KEY_FILE"
    chmod 600 "$CERT_FILE" "$KEY_FILE"
    info "已复制自定义证书到 $CERT_DIR"
  else
    generate_self_signed_cert
  fi
}

alpn_json(){
  load_profile
  python3 - <<PY
import json
print(json.dumps("${TUIC_ALPN}".split(','), ensure_ascii=False))
PY
}

write_singbox_config(){
  load_profile
  mkdir -p "$CONF_DIR"
  cat > "$SINGBOX_CONF" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "${LISTEN_ADDR}",
      "listen_port": ${TUIC_PORT},
      "users": [
        {
          "name": "default",
          "uuid": "${TUIC_UUID}",
          "password": "${TUIC_PASSWORD}"
        }
      ],
      "congestion_control": "${TUIC_CC}",
      "auth_timeout": "${TUIC_AUTH_TIMEOUT}",
      "zero_rtt_handshake": ${TUIC_ZERO_RTT},
      "heartbeat": "${TUIC_HEARTBEAT}",
      "sniff": ${TUIC_SNIFF},
      "tls": {
        "enabled": true,
        "server_name": "${TUIC_DOMAIN}",
        "alpn": $(alpn_json),
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      }
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

cleanup_legacy_services(){
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
  prepare_certificate
  write_singbox_config
  write_openrc_service
  enable_sysctl
  cleanup_legacy_services
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
  headline "Alpine + sing-box TUIC v5 状态"
  echo "系统: $(cat /etc/alpine-release 2>/dev/null || echo unknown)"
  echo "sing-box: $(status_service)"
  echo "sing-box 版本: $($SINGBOX_BIN version 2>/dev/null | head -n1 || echo 未安装)"
  echo "监听端口: $(jq -r '.inbounds[0].listen_port // "未配置"' "$SINGBOX_CONF" 2>/dev/null || echo 未配置)"
  echo "协议: $(jq -r '.inbounds[0].type // "未配置"' "$SINGBOX_CONF" 2>/dev/null || echo 未配置)"
  echo "拥塞控制: $(jq -r '.inbounds[0].congestion_control // "未配置"' "$SINGBOX_CONF" 2>/dev/null || echo 未配置)"
  echo "0-RTT: $(jq -r '.inbounds[0].zero_rtt_handshake // "未配置"' "$SINGBOX_CONF" 2>/dev/null || echo 未配置)"
  echo "证书: $(if [[ -f "$CERT_FILE" ]]; then echo 已生成; else echo 未生成; fi)"
  echo "OpenRC 开机启动:"
  rc-update show default | grep 'sing-box' || true
}

show_config(){
  clear
  headline "sing-box 配置"
  if [[ -f "$SINGBOX_CONF" ]]; then
    sed -n '1,240p' "$SINGBOX_CONF"
  else
    echo "未找到 $SINGBOX_CONF"
  fi
}

reconfigure(){
  configure_profile
  prepare_certificate
  write_singbox_config
  validate_singbox_config
  restart_service
}

show_client_hint(){
  load_profile
  clear
  headline "客户端参数"
  echo "协议: TUIC v5"
  echo "地址: ${TUIC_DOMAIN}"
  echo "端口: ${TUIC_PORT}"
  echo "UUID: ${TUIC_UUID}"
  echo "密码: ${TUIC_PASSWORD}"
  echo "拥塞控制: ${TUIC_CC}"
  echo "认证超时: ${TUIC_AUTH_TIMEOUT}"
  echo "心跳: ${TUIC_HEARTBEAT}"
  echo "0-RTT: ${TUIC_ZERO_RTT}"
  echo "ALPN: ${TUIC_ALPN}"
  echo "SNI: ${TUIC_DOMAIN}"
  echo "证书路径: ${CERT_FILE}"
  echo
  echo "说明: 当前为纯 sing-box 承载的 TUIC v5 inbound。客户端如校验证书，请导入对应证书或改用受信任证书。"
}

uninstall_all(){
  stop_service || true
  rc-update del sing-box default >/dev/null 2>&1 || true
  rm -f "$SINGBOX_SERVICE" "$SINGBOX_BIN"
  rm -rf "$CONF_DIR" "$WORKDIR"
  rm -f "$SYSCTL_FILE"
  cleanup_legacy_services
  info "已卸载纯 sing-box TUIC v5 环境"
}

main_menu(){
  while true; do
    clear
    headline "Alpine 纯 sing-box TUIC v5 菜单管理脚本 v${SCRIPT_VERSION}"
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
