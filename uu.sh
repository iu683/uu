#!/bin/sh
set -eu

GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
RESET='\033[0m'

SNELL_DIR="/etc/snell"
SNELL_CONFIG="$SNELL_DIR/snell-server.conf"
SNELL_SERVICE="/etc/init.d/snell"
SNELL_USER="snell"
VERSION="v5.0.1"
LOG_FILE="/var/log/snell-manager.log"

info() { printf "${GREEN}[信息] %s${RESET}\n" "$1"; }
warn() { printf "${YELLOW}[警告] %s${RESET}\n" "$1"; }
err() { printf "${RED}[错误] %s${RESET}\n" "$1"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请用 root 运行此脚本"
    exit 1
  fi
}

require_alpine() {
  if [ ! -f /etc/alpine-release ]; then
    err "这是 Alpine 专用脚本，当前系统不是 Alpine"
    exit 1
  fi
}

install_deps() {
  info "安装依赖..."
  apk update
  apk add bash wget unzip iproute2 coreutils grep sed gawk
}

create_user_if_needed() {
  if ! id -u "$SNELL_USER" >/dev/null 2>&1; then
    addgroup -S "$SNELL_USER" >/dev/null 2>&1 || true
    adduser -S -D -H -s /sbin/nologin -G "$SNELL_USER" "$SNELL_USER"
  fi
}

get_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    i386|i686) echo "i386" ;;
    aarch64|arm64) echo "aarch64" ;;
    armv7l|armv7) echo "armv7l" ;;
    *) err "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

get_download_url() {
  arch="$(get_arch)"
  echo "https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-${arch}.zip"
}

random_key() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16
}

validate_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1025 ] && [ "$1" -le 65535 ]
}

port_in_use() {
  ss -tln 2>/dev/null | grep -q ":$1 "
}

get_public_ip() {
  for url in https://api.ipify.org https://ip.sb https://checkip.amazonaws.com; do
    ip="$(wget -qO- --timeout=5 "$url" 2>/dev/null || true)"
    if [ -n "$ip" ]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

get_system_dns() {
  grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd ',' -
}

write_config() {
  mkdir -p "$SNELL_DIR"

  printf '请输入端口 [1025-65535，留空随机]: '
  read -r input_port
  if [ -z "$input_port" ]; then
    port="$(shuf -i 1025-65535 -n 1)"
  else
    if ! validate_port "$input_port"; then
      err "端口无效"
      return 1
    fi
    port="$input_port"
  fi

  if port_in_use "$port"; then
    err "端口 $port 已被占用"
    return 1
  fi

  printf '请输入 PSK（留空随机生成）: '
  read -r key
  [ -n "$key" ] || key="$(random_key)"

  echo 'OBFS: 1) tls  2) http  3) off'
  printf '请选择 [默认 3]: '
  read -r obfs_choice
  case "$obfs_choice" in
    1) obfs='tls' ;;
    2) obfs='http' ;;
    *) obfs='off' ;;
  esac

  echo 'IPv6 解析: 1) 开启  2) 关闭'
  printf '请选择 [默认 2]: '
  read -r ipv6_choice
  case "${ipv6_choice:-2}" in
    1) ipv6='true'; listen="::0:$port" ;;
    *) ipv6='false'; listen="0.0.0.0:$port" ;;
  esac

  echo 'TCP Fast Open: 1) 开启  2) 关闭'
  printf '请选择 [默认 1]: '
  read -r tfo_choice
  case "${tfo_choice:-1}" in
    1) tfo='true' ;;
    *) tfo='false' ;;
  esac

  default_dns="$(get_system_dns)"
  [ -n "$default_dns" ] || default_dns='1.1.1.1,8.8.8.8'
  printf '请输入 DNS [默认 %s]: ' "$default_dns"
  read -r dns
  dns="${dns:-$default_dns}"

  cat > "$SNELL_CONFIG" <<EOF
[snell-server]
listen = $listen
psk = $key
obfs = $obfs
ipv6 = $ipv6
tfo = $tfo
dns = $dns
EOF

  ip="$(get_public_ip || true)"
  [ -n "$ip" ] || ip='YOUR_SERVER_IP'
  host="$(hostname -s 2>/dev/null || echo snell)"
  cat > "$SNELL_DIR/config.txt" <<EOF
$host = snell, $ip, $port, psk=$key, version=5, tfo=$tfo, reuse=true, ecn=true
EOF

  chown -R "$SNELL_USER":"$SNELL_USER" "$SNELL_DIR" 2>/dev/null || chown -R "$SNELL_USER" "$SNELL_DIR"

  info "配置已写入: $SNELL_CONFIG"
  echo "---------------------------------"
  cat "$SNELL_DIR/config.txt"
  echo "---------------------------------"
}

write_openrc_service() {
  cat > "$SNELL_SERVICE" <<EOF
#!/sbin/openrc-run
name="Snell Server"
description="Snell Server"
command="$SNELL_DIR/snell-server"
command_args="-c $SNELL_CONFIG"
command_user="$SNELL_USER"
pidfile="/run/snell.pid"
command_background="yes"
start_stop_daemon_args="--make-pidfile --pidfile /run/snell.pid"
output_log="/var/log/snell.log"
error_log="/var/log/snell.err"

depend() {
  need net
}
EOF
  chmod +x "$SNELL_SERVICE"
  rc-update add snell default >/dev/null 2>&1 || true
}

install_snell() {
  install_deps
  create_user_if_needed
  mkdir -p "$SNELL_DIR"
  cd "$SNELL_DIR"

  url="$(get_download_url)"
  info "下载: $url"
  wget -O snell.zip "$url"
  unzip -o snell.zip -d "$SNELL_DIR"
  rm -f snell.zip
  chmod +x "$SNELL_DIR/snell-server"

  write_config
  write_openrc_service

  rc-service snell restart >/dev/null 2>&1 || rc-service snell start
  info "Snell 已安装并启动"
}

update_snell() {
  [ -f "$SNELL_CONFIG" ] || { err "未找到现有配置，无法更新"; exit 1; }
  cd "$SNELL_DIR"
  rc-service snell stop >/dev/null 2>&1 || true

  url="$(get_download_url)"
  info "下载: $url"
  wget -O snell.zip "$url"
  unzip -o snell.zip -d "$SNELL_DIR"
  rm -f snell.zip
  chmod +x "$SNELL_DIR/snell-server"

  rc-service snell start
  info "Snell 已更新"
}

uninstall_snell() {
  warn "即将卸载 Snell"
  rc-service snell stop >/dev/null 2>&1 || true
  rc-update del snell default >/dev/null 2>&1 || true
  rm -f "$SNELL_SERVICE"
  rm -rf "$SNELL_DIR"
  info "Snell 已卸载"
}

show_config() {
  if [ ! -f "$SNELL_CONFIG" ]; then
    err "配置文件不存在"
    return 1
  fi
  echo '====== snell-server.conf ======'
  cat "$SNELL_CONFIG"
  echo '====== Surge 示例 ======'
  cat "$SNELL_DIR/config.txt" 2>/dev/null || true
}

show_menu() {
  clear
  echo '====== Snell Alpine 管理 ======'
  echo '1. 安装 Snell'
  echo '2. 更新 Snell'
  echo '3. 卸载 Snell'
  echo '4. 重新生成配置并重启'
  echo '5. 启动 Snell'
  echo '6. 停止 Snell'
  echo '7. 重启 Snell'
  echo '8. 查看配置'
  echo '9. 查看日志'
  echo '0. 退出'
}

pause() {
  printf '按回车继续...'
  read -r _
}

main() {
  require_root
  require_alpine

  while true; do
    show_menu
    printf '请输入选项: '
    read -r choice
    case "$choice" in
      1) install_snell; pause ;;
      2) update_snell; pause ;;
      3) uninstall_snell; pause ;;
      4) write_config && rc-service snell restart; pause ;;
      5) rc-service snell start; pause ;;
      6) rc-service snell stop; pause ;;
      7) rc-service snell restart; pause ;;
      8) show_config; pause ;;
      9) tail -n 100 /var/log/snell.log 2>/dev/null || echo '暂无 /var/log/snell.log'; pause ;;
      0) exit 0 ;;
      *) err '无效选项'; pause ;;
    esac
  done
}

main "$@"
