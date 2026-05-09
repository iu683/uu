#!/usr/bin/env bash
set -euo pipefail

APP_NAME="mtproto-proxy"
INSTALL_DIR="/opt/${APP_NAME}"
BIN_PATH="${INSTALL_DIR}/mtproto-proxy"
CONFIG_DIR="/etc/${APP_NAME}"
CONFIG_FILE="${CONFIG_DIR}/${APP_NAME}.conf"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
ENV_FILE="${CONFIG_DIR}/${APP_NAME}.env"
DEFAULT_PORT="8443"
DEFAULT_TLS_DOMAIN="www.cloudflare.com"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue() { printf '\033[36m%s\033[0m\n' "$*"; }

line() { printf '%*s\n' "${COLUMNS:-60}" '' | tr ' ' '-'; }
die() { red "[错误] $*"; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请用 root 运行此脚本"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
press_enter() { read -r -p "按回车继续..." _; }

OS_ID=""
OS_LIKE=""
PKG_MANAGER=""
ARCH_RAW="$(uname -m)"
ARCH=""

get_arch() {
  case "$ARCH_RAW" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv7) ARCH="armv7" ;;
    *) die "暂不支持的架构: $ARCH_RAW" ;;
  esac
}

detect_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
  else
    die "未识别的包管理器，请手动安装 curl wget openssl tar systemd"
  fi
}

install_deps() {
  blue "[1/6] 安装依赖..."
  case "$PKG_MANAGER" in
    apt)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget openssl ca-certificates tar systemd
      ;;
    dnf)
      dnf install -y curl wget openssl ca-certificates tar systemd
      ;;
    yum)
      yum install -y curl wget openssl ca-certificates tar systemd
      ;;
    apk)
      apk add --no-cache curl wget openssl ca-certificates tar
      ;;
    pacman)
      pacman -Sy --noconfirm curl wget openssl ca-certificates tar systemd
      ;;
    zypper)
      zypper --non-interactive install curl wget openssl ca-certificates tar systemd
      ;;
  esac
}

ensure_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemd，无法实现 systemctl 开机自启"
}

download_binary() {
  blue "[2/6] 下载 MTProto Proxy 二进制..."
  local url=""
  case "$ARCH" in
    amd64)
      url="https://github.com/TelegramMessenger/MTProxy/releases/latest/download/mtg-linux-amd64"
      ;;
    arm64)
      url="https://github.com/TelegramMessenger/MTProxy/releases/latest/download/mtg-linux-arm64"
      ;;
    armv7)
      url="https://github.com/TelegramMessenger/MTProxy/releases/latest/download/mtg-linux-armv7"
      ;;
  esac

  mkdir -p "$INSTALL_DIR"
  if ! curl -fL "$url" -o "$BIN_PATH"; then
    die "下载失败: $url"
  fi
  chmod +x "$BIN_PATH"
}

gen_secret() {
  openssl rand -hex 16
}

gen_tag() {
  openssl rand -hex 16
}

write_config() {
  local port="$1"
  local secret="$2"
  local tag="$3"
  local domain="$4"

  blue "[3/6] 写入配置..."
  mkdir -p "$CONFIG_DIR"
  cat > "$ENV_FILE" <<EOF
MP_PORT=${port}
MP_SECRET=${secret}
MP_TAG=${tag}
MP_TLS_DOMAIN=${domain}
EOF

  cat > "$CONFIG_FILE" <<EOF
# MTProto Proxy 配置
PORT=${port}
SECRET=${secret}
TAG=${tag}
TLS_DOMAIN=${domain}
# 客户端链接示例（需替换服务器 IP）:
# tg://proxy?server=YOUR_SERVER_IP&port=${port}&secret=dd${tag}${secret}
EOF
}

write_service() {
  blue "[4/6] 写入 systemd 服务..."
  cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=MTProto Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/mtproto-proxy/mtproto-proxy.env
ExecStart=/opt/mtproto-proxy/mtproto-proxy \
  --bind 0.0.0.0:${MP_PORT} \
  --secret ${MP_SECRET} \
  --domain ${MP_TLS_DOMAIN} \
  --dd-secret dd${MP_TAG}${MP_SECRET}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

public_ip() {
  curl -4fsSL https://api.ipify.org || curl -4fsSL https://ifconfig.me || true
}

start_service() {
  blue "[5/6] 启用并启动服务..."
  systemctl daemon-reload
  systemctl enable --now "$APP_NAME"
}

show_generated_info() {
  local ip="$1"
  local port secret tag domain
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  port="$MP_PORT"
  secret="$MP_SECRET"
  tag="$MP_TAG"
  domain="$MP_TLS_DOMAIN"

  green "[6/6] 安装完成"
  echo
  echo "服务名: $APP_NAME"
  echo "配置文件: $CONFIG_FILE"
  echo "环境文件: $ENV_FILE"
  echo "监听端口: $port"
  echo "伪装域名: $domain"
  echo "Secret: $secret"
  echo "Tag: $tag"
  if [[ -n "$ip" ]]; then
    echo "Telegram 链接: tg://proxy?server=${ip}&port=${port}&secret=dd${tag}${secret}"
  else
    yellow "未自动获取公网 IP，请手动替换下面链接中的 YOUR_SERVER_IP"
    echo "Telegram 链接: tg://proxy?server=YOUR_SERVER_IP&port=${port}&secret=dd${tag}${secret}"
  fi
  echo
  echo "常用命令:"
  echo "  systemctl status $APP_NAME"
  echo "  systemctl restart $APP_NAME"
  echo "  journalctl -u $APP_NAME -f"
}

install_proxy() {
  ensure_systemd
  detect_os
  get_arch
  install_deps

  local port secret tag domain
  read -r -p "请输入监听端口 [${DEFAULT_PORT}]: " port
  port="${port:-$DEFAULT_PORT}"
  [[ "$port" =~ ^[0-9]+$ ]] || die "端口必须是数字"
  (( port >= 1 && port <= 65535 )) || die "端口范围必须在 1-65535"

  read -r -p "请输入 TLS 伪装域名 [${DEFAULT_TLS_DOMAIN}]: " domain
  domain="${domain:-$DEFAULT_TLS_DOMAIN}"

  secret="$(gen_secret)"
  tag="$(gen_tag)"

  download_binary
  write_config "$port" "$secret" "$tag" "$domain"
  write_service
  start_service
  show_generated_info "$(public_ip)"
}

uninstall_proxy() {
  ensure_systemd
  blue "正在卸载 $APP_NAME ..."
  if systemctl list-unit-files | grep -q "^${APP_NAME}\.service"; then
    systemctl disable --now "$APP_NAME" || true
  fi
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload || true
  rm -rf "$INSTALL_DIR" "$CONFIG_DIR"
  green "卸载完成"
}

status_proxy() {
  ensure_systemd
  systemctl status "$APP_NAME" --no-pager || true
}

restart_proxy() {
  ensure_systemd
  systemctl restart "$APP_NAME"
  green "已重启 $APP_NAME"
}

show_config() {
  [[ -f "$CONFIG_FILE" ]] || die "未找到配置文件: $CONFIG_FILE"
  cat "$CONFIG_FILE"
}

show_link() {
  [[ -f "$ENV_FILE" ]] || die "未找到环境文件: $ENV_FILE"
  local ip
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  ip="$(public_ip)"
  if [[ -n "$ip" ]]; then
    echo "tg://proxy?server=${ip}&port=${MP_PORT}&secret=dd${MP_TAG}${MP_SECRET}"
  else
    echo "tg://proxy?server=YOUR_SERVER_IP&port=${MP_PORT}&secret=dd${MP_TAG}${MP_SECRET}"
  fi
}

change_port() {
  ensure_systemd
  [[ -f "$ENV_FILE" ]] || die "未安装或缺少环境文件: $ENV_FILE"
  local new_port
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  read -r -p "请输入新的监听端口 [当前: ${MP_PORT}]: " new_port
  new_port="${new_port:-$MP_PORT}"
  [[ "$new_port" =~ ^[0-9]+$ ]] || die "端口必须是数字"
  (( new_port >= 1 && new_port <= 65535 )) || die "端口范围必须在 1-65535"

  cat > "$ENV_FILE" <<EOF
MP_PORT=${new_port}
MP_SECRET=${MP_SECRET}
MP_TAG=${MP_TAG}
MP_TLS_DOMAIN=${MP_TLS_DOMAIN}
EOF

  cat > "$CONFIG_FILE" <<EOF
# MTProto Proxy 配置
PORT=${new_port}
SECRET=${MP_SECRET}
TAG=${MP_TAG}
TLS_DOMAIN=${MP_TLS_DOMAIN}
# 客户端链接示例（需替换服务器 IP）:
# tg://proxy?server=YOUR_SERVER_IP&port=${new_port}&secret=dd${MP_TAG}${MP_SECRET}
EOF

  systemctl restart "$APP_NAME"
  green "端口已修改为: ${new_port}"
  echo "新链接: $(show_link)"
}

menu() {
  while true; do
    clear || true
    line
    echo "      MTProto Proxy 管理脚本"
    line
    echo " 1) 安装 MTProto Proxy"
    echo " 2) 卸载 MTProto Proxy"
    echo " 3) 查看服务状态"
    echo " 4) 重启服务"
    echo " 5) 查看配置"
    echo " 6) 查看 Telegram 连接链接"
    echo " 7) 修改监听端口"
    echo " 0) 退出"
    line
    read -r -p "请选择 [0-7]: " choice
    echo
    case "$choice" in
      1) install_proxy; press_enter ;;
      2) uninstall_proxy; press_enter ;;
      3) status_proxy; press_enter ;;
      4) restart_proxy; press_enter ;;
      5) show_config; press_enter ;;
      6) show_link; press_enter ;;
      7) change_port; press_enter ;;
      0) exit 0 ;;
      *) yellow "无效选项"; press_enter ;;
    esac
  done
}

usage() {
  cat <<EOF
用法:
  $0                  打开交互菜单
  $0 menu             打开交互菜单
  $0 install          安装 MTProto Proxy
  $0 uninstall        卸载 MTProto Proxy
  $0 status           查看服务状态
  $0 restart          重启服务
  $0 config           查看当前配置
  $0 link             查看 Telegram 连接链接
  $0 change-port      修改监听端口
EOF
}

main() {
  need_root
  need_cmd uname
  need_cmd openssl
  case "${1:-menu}" in
    menu) menu ;;
    install) install_proxy ;;
    uninstall) uninstall_proxy ;;
    status) status_proxy ;;
    restart) restart_proxy ;;
    config) show_config ;;
    link) show_link ;;
    change-port) change_port ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
