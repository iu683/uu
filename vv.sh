#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
RESET='\033[0m'

SINGBOX_DIR='/etc/sing-box'
SINGBOX_CONFIG="$SINGBOX_DIR/config.json"
STATE_FILE='/etc/anyreality-singbox.env'
SERVICE_NAME='sing-box'

LOG_FILE='/var/log/anyreality-singbox.log'

info() { echo -e "${GREEN}[信息] $*${RESET}"; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}"; }
err() { echo -e "${RED}[错误] $*${RESET}" >&2; }

setup_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo
  echo "[$(date '+%F %T %Z')] anyreality-singbox script started"
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || { err '请用 root 运行'; exit 1; }
}

require_debian_ubuntu() {
  [[ -f /etc/os-release ]] || { err '无法识别系统，只支持 Debian/Ubuntu'; exit 1; }
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) [[ "${ID_LIKE:-}" == *debian* ]] || { err "只支持 Debian/Ubuntu，当前: ${PRETTY_NAME:-unknown}"; exit 1; } ;;
  esac
}

install_deps() {
  info '安装依赖...'
  apt-get update
  apt-get install -y curl wget unzip ca-certificates uuid-runtime
}

install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    info '检测到 sing-box，跳过安装。'
    return
  fi
  info '安装 sing-box...'
  bash <(curl -fsSL https://sing-box.app/install.sh)
}

get_public_ip() {
  local ip=''
  for url in https://api.ipify.org https://ip.sb https://checkip.amazonaws.com; do
    ip=$(curl -4s --max-time 5 "$url" 2>/dev/null || true)
    [[ -n "$ip" ]] && { echo "$ip"; return; }
    ip=$(wget -4qO- --timeout=5 "$url" 2>/dev/null || true)
    [[ -n "$ip" ]] && { echo "$ip"; return; }
  done
  hostname -I | awk '{print $1}'
}

ask_config() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi

  read -rp "请输入监听端口（留空随机生成，当前 ${PORT:-未设置}）: " INPUT_PORT
  if [[ -n "$INPUT_PORT" ]]; then
    PORT="$INPUT_PORT"
  elif [[ -z "${PORT:-}" ]]; then
    PORT=$(shuf -i 10000-65535 -n 1)
  fi

  read -rp "请输入用户名（留空随机生成，当前 ${USERNAME:-未设置}）: " INPUT_USERNAME
  if [[ -n "$INPUT_USERNAME" ]]; then
    USERNAME="$INPUT_USERNAME"
  elif [[ -z "${USERNAME:-}" ]]; then
    USERNAME=$(python3 - <<'PY'
import secrets, string
alphabet = string.ascii_lowercase + string.digits
print('user-' + ''.join(secrets.choice(alphabet) for _ in range(6)))
PY
)
  fi

  read -rp "请输入密码（留空随机生成，当前 ${PASSWORD:-未设置}）: " INPUT_PASSWORD
  if [[ -n "$INPUT_PASSWORD" ]]; then
    PASSWORD="$INPUT_PASSWORD"
  elif [[ -z "${PASSWORD:-}" ]]; then
    PASSWORD=$(python3 - <<'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(12)))
PY
)
  fi

  read -rp "请输入伪装域名/SNI（当前 ${SERVER_NAME:-www.amazon.com}）: " INPUT_SERVER_NAME
  SERVER_NAME=${INPUT_SERVER_NAME:-${SERVER_NAME:-www.amazon.com}}

  read -rp "请输入 short_id（留空随机生成，当前 ${SHORT_ID:-未设置}）: " INPUT_SHORT_ID
  if [[ -n "$INPUT_SHORT_ID" ]]; then
    SHORT_ID="$INPUT_SHORT_ID"
  elif [[ -z "${SHORT_ID:-}" ]]; then
    SHORT_ID=$(python3 - <<'PY'
import secrets
print(secrets.token_hex(8))
PY
)
  fi

  read -rp "请输入节点备注（当前 ${REMARK:-anytls-reality-tls}）: " INPUT_REMARK
  REMARK=${INPUT_REMARK:-${REMARK:-anytls-reality-tls}}
}

generate_or_use_key() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi

  if [[ -n "${PRIVATE_KEY:-}" && -n "${PUBLIC_KEY:-}" ]]; then
    info '沿用现有 Reality 私钥/公钥。'
    return
  fi

  KEY_OUT=$(sing-box generate reality-keypair)
  PRIVATE_KEY=$(awk '/PrivateKey/ {print $2}' <<< "$KEY_OUT")
  PUBLIC_KEY=$(awk '/PublicKey/ {print $2}' <<< "$KEY_OUT")
}

write_config() {
  mkdir -p "$SINGBOX_DIR"

  cat > "$SINGBOX_CONFIG" <<EOF
{
  "inbounds": [
    {
      "type": "anytls",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "${USERNAME}",
          "password": "${PASSWORD}"
        }
      ],
      "padding_scheme": [
        "stop=8",
        "0=30-30",
        "1=100-400",
        "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
        "3=9-9,500-1000",
        "4=500-1000",
        "5=500-1000",
        "6=500-1000",
        "7=500-1000"
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SERVER_NAME}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SERVER_NAME}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": "${SHORT_ID}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF
}

save_state() {
  SERVER_IP=$(get_public_ip)
  cat > "$STATE_FILE" <<EOF
PORT='${PORT}'
USERNAME='${USERNAME}'
PASSWORD='${PASSWORD}'
SERVER_NAME='${SERVER_NAME}'
SHORT_ID='${SHORT_ID}'
REMARK='${REMARK}'
PRIVATE_KEY='${PRIVATE_KEY}'
PUBLIC_KEY='${PUBLIC_KEY}'
SERVER_IP='${SERVER_IP}'
EOF
  chmod 600 "$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || { err '未找到已安装配置'; return 1; }
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
  fi
}

start_service() {
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"
  systemctl --no-pager --full status "$SERVICE_NAME" || true
}

show_subscription() {
  require_root
  load_state || return 1
  echo
  info '当前节点信息'
  echo "服务器 IP: ${SERVER_IP}"
  echo "端口: ${PORT}"
  echo "用户名: ${USERNAME}"
  echo "密码: ${PASSWORD}"
  echo "SNI: ${SERVER_NAME}"
  echo "Reality PublicKey: ${PUBLIC_KEY}"
  echo "Reality ShortID: ${SHORT_ID}"
  echo "备注: ${REMARK}"
  echo
  echo 'QX 配置：'
  echo "anytls=${SERVER_IP}:${PORT}, password=${PASSWORD}, over-tls=true, tls-host=${SERVER_NAME}, reality-base64-pubkey=${PUBLIC_KEY}, reality-hex-shortid=${SHORT_ID}, udp-relay=true, tag=${REMARK}"
  echo
  echo 'sing-box 客户端示例配置：'
  cat <<EOF
{
  "type": "anytls",
  "tag": "${REMARK}",
  "server": "${SERVER_IP}",
  "server_port": ${PORT},
  "password": "${PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${SERVER_NAME}",
    "reality": {
      "enabled": true,
      "public_key": "${PUBLIC_KEY}",
      "short_id": "${SHORT_ID}"
    }
  }
}
EOF
}

install_app() {
  require_root
  require_debian_ubuntu
  install_deps
  install_singbox
  ask_config
  generate_or_use_key
  write_config
  save_state
  open_firewall
  start_service
  show_subscription
}

uninstall_app() {
  require_root
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  apt-get remove -y sing-box >/dev/null 2>&1 || true
  apt-get purge -y sing-box >/dev/null 2>&1 || true
  rm -f "$SINGBOX_CONFIG" "$STATE_FILE"
  rm -rf "$SINGBOX_DIR"
  info '已卸载 sing-box、配置文件与状态文件。'
}

status_app() {
  systemctl --no-pager --full status "$SERVICE_NAME" || true
}

pause_return() {
  echo
  read -rp '按回车返回菜单...' _
}

show_menu() {
  echo
  echo '====== sing-box anytls+reality 管理 ======'
  echo '1. 安装'
  echo '2. 卸载'
  echo '3. 查看状态'
  echo '4. 查看节点信息'
  echo '5. 修改配置'
  echo '0. 退出'
  echo
}

menu_loop() {
  while true; do
    show_menu
    read -rp '请输入选项: ' choice
    case "$choice" in
      1) install_app; pause_return ;;
      2) uninstall_app; pause_return ;;
      3) status_app; pause_return ;;
      4) show_subscription; pause_return ;;
      5) install_app; pause_return ;;
      0) exit 0 ;;
      *) err '无效选项'; pause_return ;;
    esac
  done
}

setup_logging
menu_loop
