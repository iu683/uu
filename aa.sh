#!/usr/bin/env bash
set -Eeuo pipefail

REPO="Diniboy1123/usque"
BIN_NAME="usque"
INSTALL_DIR="/usr/local/bin"
BIN_PATH="$INSTALL_DIR/$BIN_NAME"
CONFIG_DIR="/etc/usque"
CONFIG_PATH="$CONFIG_DIR/config.json"
SERVICE_NAME="usque"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
STATE_FILE="/etc/usque/runtime.env"
DEFAULT_MODE="socks"
DEFAULT_BIND="127.0.0.1"
DEFAULT_PORT="1080"
AUTO_REGISTER_NAME=""
AUTO_REGISTER_LOCALE="en_US"
AUTO_REGISTER_MODEL="PC"
AUTO_REGISTER_JWT=""

# ---- 颜色定义 ----
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m' 
NC='\033[0m'

log() {
  printf '%s\n' "$*"
}

info() {
  printf "[${GREEN}*${NC}] %s\n" "$*"
}

warn() {
  printf "[${YELLOW}!${NC}] %s\n" "$*" >&2
}

die() {
  printf "[${RED}x${NC}] %s\n" "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1"
}

run_as_root() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "需要 root 权限执行: $*"
  fi
}

detect_os() {
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$os" in
    linux) echo "linux" ;;
    darwin) echo "darwin" ;;
    *) die "暂不支持的系统: $os" ;;
  esac
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    armv6l|armv6) echo "armv6" ;;
    armv5tel|armv5|arm) echo "armv5" ;;
    mips) echo "mips" ;;
    mips64) echo "mips64" ;;
    mips64el|mips64le) echo "mips64le" ;;
    mipsel|mipsle) echo "mipsle" ;;
    *) die "暂不支持的架构: $arch" ;;
  esac
}

pick_service_manager() {
  if command -v systemctl >/dev/null 2>&1; then
    echo "systemd"
  else
    echo "none"
  fi
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    run_as_root apt-get update
    run_as_root apt-get install -y curl unzip ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    run_as_root dnf install -y curl unzip ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    run_as_root yum install -y curl unzip ca-certificates
  elif command -v apk >/dev/null 2>&1; then
    run_as_root apk add --no-cache curl unzip ca-certificates
  elif command -v pacman >/dev/null 2>&1; then
    run_as_root pacman -Sy --noconfirm curl unzip ca-certificates
  elif command -v zypper >/dev/null 2>&1; then
    run_as_root zypper --non-interactive install curl unzip ca-certificates
  else
    die "无法自动安装依赖，请手动安装: curl unzip ca-certificates"
  fi
}

fetch_latest_release() {
  local api tag
  api="https://api.github.com/repos/$REPO/releases/latest"
  tag="$(curl -fsSL "$api" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
  [ -n "$tag" ] || die "获取最新版本失败"
  echo "$tag"
}

build_asset_name() {
  local version os arch
  version="$1"
  os="$2"
  arch="$3"
  version="${version#v}"
  echo "usque_${version}_${os}_${arch}.zip"
}

write_runtime_env() {
  local mode bind port tmp
  mode="$1"
  bind="$2"
  port="$3"
  run_as_root mkdir -p "$CONFIG_DIR"
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
USQUE_MODE="$mode"
USQUE_BIND="$bind"
USQUE_PORT="$port"
EOF
  run_as_root install -m 0644 "$tmp" "$STATE_FILE"
  rm -f "$tmp"
}

load_runtime_env() {
  local mode bind port
  mode="$DEFAULT_MODE"
  bind="$DEFAULT_BIND"
  port="$DEFAULT_PORT"
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    mode="${USQUE_MODE:-$mode}"
    bind="${USQUE_BIND:-$bind}"
    port="${USQUE_PORT:-$port}"
  fi
  printf '%s|%s|%s\n' "$mode" "$bind" "$port"
}

require_valid_port() {
  local port
  port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "端口必须是数字"
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "端口必须在 1-65535 之间"
}

port_in_use() {
  local port
  port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lnt | awk '{print $4}' | grep -Eq "[:.]${port}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
  else
    return 1
  fi
}

download_and_install_binary() {
  local version os arch asset url tmpdir checksum_file actual expected
  version="$1"
  os="$2"
  arch="$3"
  asset="$(build_asset_name "$version" "$os" "$arch")"
  url="https://github.com/$REPO/releases/download/$version/$asset"
  tmpdir="$(mktemp -d)"

  info "下载 $asset"
  curl -fL "$url" -o "$tmpdir/$asset" || {
    rm -rf "$tmpdir"
    die "下载失败: $url"
  }

  checksum_file="$tmpdir/checksums.txt"
  if curl -fsSL "https://github.com/$REPO/releases/download/$version/checksums.txt" -o "$checksum_file"; then
    expected="$(grep "  $asset$" "$checksum_file" | awk '{print $1}')"
    if [ -n "$expected" ] && command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$tmpdir/$asset" | awk '{print $1}')"
      [ "$actual" = "$expected" ] || {
        rm -rf "$tmpdir"
        die "校验失败: $asset"
      }
      info "SHA256 校验通过"
    else
      warn "跳过 SHA256 校验（未找到匹配校验值或 sha256sum）"
    fi
  else
    warn "未获取到 checksums.txt，跳过校验"
  fi

  unzip -qo "$tmpdir/$asset" -d "$tmpdir/unpack"
  [ -f "$tmpdir/unpack/$BIN_NAME" ] || {
    rm -rf "$tmpdir"
    die "压缩包中未找到 $BIN_NAME"
  }
  chmod +x "$tmpdir/unpack/$BIN_NAME"
  run_as_root mkdir -p "$INSTALL_DIR"
  run_as_root install -m 0755 "$tmpdir/unpack/$BIN_NAME" "$BIN_PATH"
  rm -rf "$tmpdir"
  info "已更新到 $BIN_PATH"
}

create_systemd_service() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
[Unit]
Description=usque Cloudflare WARP MASQUE service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-$STATE_FILE
ExecStart=/bin/sh -c 'exec "$BIN_PATH" -c "$CONFIG_PATH" "\${USQUE_MODE:-socks}" --bind "\${USQUE_BIND:-127.0.0.1}" --port "\${USQUE_PORT:-1080}"'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  run_as_root install -m 0644 "$tmp" "$SERVICE_FILE"
  rm -f "$tmp"
  run_as_root systemctl daemon-reload
  run_as_root systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

ensure_systemd_service() {
  [ "$(pick_service_manager)" = "systemd" ] || return 0
  create_systemd_service
}

get_installed_version() {
  if [ ! -x "$BIN_PATH" ]; then
    echo "-"
    return
  fi
  "$BIN_PATH" version 2>/dev/null | head -n1 | awk -F': ' '{print $2}'
}

config_exists() {
  [ -s "$CONFIG_PATH" ]
}

auto_register() {
  [ -x "$BIN_PATH" ] || die "usque 未安装，请先安装"

  if config_exists; then
    info "检测到已存在配置，跳过自动注册"
    return 0
  fi

  run_as_root mkdir -p "$CONFIG_DIR"

  local args
  args="-c $CONFIG_PATH register -a"

  if [ -n "$AUTO_REGISTER_NAME" ]; then
    args="$args -n '$AUTO_REGISTER_NAME'"
  fi
  if [ -n "$AUTO_REGISTER_LOCALE" ]; then
    args="$args -l '$AUTO_REGISTER_LOCALE'"
  fi
  if [ -n "$AUTO_REGISTER_MODEL" ]; then
    args="$args -m '$AUTO_REGISTER_MODEL'"
  fi
  if [ -n "$AUTO_REGISTER_JWT" ]; then
    args="$args --jwt '$AUTO_REGISTER_JWT'"
  fi

  info "开始自动注册..."
  run_as_root /bin/sh -c "exec '$BIN_PATH' $args"

  config_exists || die "自动注册失败，未生成配置文件"
  info "自动注册完成: $CONFIG_PATH"
}

prompt_install_options() {
  local current_runtime current_mode current_bind current_port input
  current_runtime="$(load_runtime_env)"
  current_mode="${current_runtime%%|*}"
  current_bind="$(printf '%s' "$current_runtime" | cut -d'|' -f2)"
  current_port="$(printf '%s' "$current_runtime" | cut -d'|' -f3)"

  printf '模式 [socks/http-proxy] (默认 %s): ' "$current_mode"
  read -r input
  if [ -n "$input" ]; then
    case "$input" in
      socks|http-proxy) current_mode="$input" ;;
      *) die "模式只支持 socks 或 http-proxy" ;;
    esac
  fi

  printf '监听地址 (默认 %s): ' "$current_bind"
  read -r input
  if [ -n "$input" ]; then
    current_bind="$input"
  fi

  printf '端口 (默认 %s): ' "$current_port"
  read -r input
  if [ -n "$input" ]; then
    require_valid_port "$input"
    current_port="$input"
  fi

  printf '设备名（可留空）: '
  read -r input
  AUTO_REGISTER_NAME="$input"

  printf 'ZeroTrust JWT（可留空）: '
  read -r input
  AUTO_REGISTER_JWT="$input"

  if port_in_use "$current_port"; then
    warn "检测到端口 $current_port 可能已被占用，启动前请确认"
  fi

  write_runtime_env "$current_mode" "$current_bind" "$current_port"
}

install_register_start() {
  prompt_install_options
  update_usque

  if [ "$(pick_service_manager)" = "systemd" ] && [ -f "$SERVICE_FILE" ]; then
    start_service
    info "安装完成"
  else
    warn "当前系统未使用 systemd，已完成部署和注册，请手动启动"
  fi
}

show_status() {
  local runtime mode bind port installed svc status_line version
  runtime="$(load_runtime_env)"
  mode="${runtime%%|*}"
  bind="$(printf '%s' "$runtime" | cut -d'|' -f2)"
  port="$(printf '%s' "$runtime" | cut -d'|' -f3)"
  
  installed="未安装"
  version="-"
  if [ -x "$BIN_PATH" ]; then
    installed="已安装"
    version="$(get_installed_version)"
    version="${version:--}"
  fi
  
  svc="$(pick_service_manager)"
  status_line="未运行"
  if [ "$svc" = "systemd" ] && [ -f "$SERVICE_FILE" ]; then
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      status_line="运行中"
    fi
  else
    status_line="未安装"
  fi

  echo -e "${GREEN}================================${RESET}"
  echo -e "${GREEN}         usque 管理面板          ${RESET}"
  echo -e "${GREEN}================================${RESET}"
  echo -e "${GREEN}状态   :${RESET} ${YELLOW}$status_line${RESET}"
  echo -e "${GREEN}模式   :${RESET} ${YELLOW}$mode${RESET}"
  echo -e "${GREEN}端口   :${RESET} ${YELLOW}${bind}:${port}${RESET}"
  echo -e "${GREEN}================================${RESET}"
  echo -e "${GREEN} 1. 安装 usque${RESET}"
  echo -e "${GREEN} 2. 更新 usque${RESET}"
  echo -e "${GREEN} 3. 卸载 usque${RESET}"
  echo -e "${GREEN} 4. 更换端口${RESET}"
  echo -e "${GREEN} 5. 启动 usque${RESET}"
  echo -e "${GREEN} 6. 停止 usque${RESET}"
  echo -e "${GREEN} 7. 重启 usque${RESET}"
  echo -e "${GREEN} 8. 查看服务日志${RESET}"
  echo -e "${GREEN} 0. 退出${RESET}"
  echo -e "${GREEN}================================${RESET}"
}

update_usque() {
  local os arch version runtime mode bind port
  need_cmd uname
  need_cmd curl
  need_cmd python3
  if ! command -v unzip >/dev/null 2>&1; then
    info "检测到未安装 unzip，尝试自动安装依赖"
    install_packages
  fi
  need_cmd unzip

  os="$(detect_os)"
  arch="$(detect_arch)"
  version="$(fetch_latest_release)"
  info "系统: $os"
  info "架构: $arch"
  info "最新版本: $version"

  download_and_install_binary "$version" "$os" "$arch"
  run_as_root mkdir -p "$CONFIG_DIR"

  runtime="$(load_runtime_env)"
  mode="${runtime%%|*}"
  bind="$(printf '%s' "$runtime" | cut -d'|' -f2)"
  port="$(printf '%s' "$runtime" | cut -d'|' -f3)"
  write_runtime_env "$mode" "$bind" "$port"

  if [ "$os" = "linux" ] && [ "$(pick_service_manager)" = "systemd" ]; then
    ensure_systemd_service
    info "已创建 systemd 服务"
  else
    warn "当前系统未创建 systemd 服务"
  fi

  "$BIN_PATH" version || true
  auto_register
  log
  log "安装完成"
  log "手动启动: $BIN_PATH -c $CONFIG_PATH $mode --bind $bind --port $port"
}

uninstall_usque() {
  if [ "$(pick_service_manager)" = "systemd" ] && [ -f "$SERVICE_FILE" ]; then
    run_as_root systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    run_as_root systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    run_as_root rm -f "$SERVICE_FILE"
    run_as_root systemctl daemon-reload
  fi

  run_as_root rm -f "$BIN_PATH"
  run_as_root rm -f "$STATE_FILE"
  if [ -d "$CONFIG_DIR" ]; then
    run_as_root rm -rf "$CONFIG_DIR"
  fi
  log "卸载完成"
}

change_port() {
  local runtime mode bind old_port new_port
  runtime="$(load_runtime_env)"
  mode="${runtime%%|*}"
  bind="$(printf '%s' "$runtime" | cut -d'|' -f2)"
  old_port="$(printf '%s' "$runtime" | cut -d'|' -f3)"

  printf '当前端口 %s，输入新端口: ' "$old_port"
  read -r new_port
  require_valid_port "$new_port"

  if [ "$new_port" != "$old_port" ] && port_in_use "$new_port"; then
    die "端口 $new_port 已被占用"
  fi

  write_runtime_env "$mode" "$bind" "$new_port"
  info "端口已更新为 $new_port"

  if [ "$(pick_service_manager)" = "systemd" ] && [ -f "$SERVICE_FILE" ]; then
    run_as_root systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
    info "已尝试重启服务"
  fi
}

start_service() {
  [ "$(pick_service_manager)" = "systemd" ] || die "当前系统不支持 systemd 服务管理"
  [ -f "$SERVICE_FILE" ] || die "服务文件不存在，请先安装"
  run_as_root systemctl start "$SERVICE_NAME"
  info "服务已启动"
}

stop_service() {
  [ "$(pick_service_manager)" = "systemd" ] || die "当前系统不支持 systemd 服务管理"
  [ -f "$SERVICE_FILE" ] || die "服务文件不存在"
  run_as_root systemctl stop "$SERVICE_NAME"
  info "服务已停止"
}

restart_service() {
  [ "$(pick_service_manager)" = "systemd" ] || die "当前系统不支持 systemd 服务管理"
  [ -f "$SERVICE_FILE" ] || die "服务文件不存在"
  run_as_root systemctl restart "$SERVICE_NAME"
  info "服务已重启"
}

service_status() {
  [ "$(pick_service_manager)" = "systemd" ] || die "当前系统不支持 systemd 服务管理"
  [ -f "$SERVICE_FILE" ] || die "服务文件不存在"
  run_as_root systemctl status "$SERVICE_NAME" --no-pager
}

pause() {
  printf "\n${GREEN}按回车继续...${RESET}"
  read -r _
}

menu_loop() {
  local choice
  while true; do
    clear || true
    show_status
    
    printf "${GREEN}请选择 [${YELLOW}0-11${GREEN}]: ${RESET}"
    read -r choice
    case "$choice" in
      1) install_register_start ;;
      2) update_usque ;;
      3) uninstall_usque ;;
      4) change_port ;;
      5) start_service ;;
      6) stop_service ;;
      7) restart_service ;;
      8) service_status ;;
      0) exit 0 ;;
      *) warn "无效选项" ;;
    esac
    pause
  done
}

menu_loop "$@"
