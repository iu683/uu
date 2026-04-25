#!/bin/sh
set -eu

GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
RESET='\033[0m'

SNELL_DIR="/etc/snell"
SNELL_BIN="/usr/local/bin/snell-server-v5"
SNELL_CONF="$SNELL_DIR/snell-server.conf"
SNELL_INFO="$SNELL_DIR/client.conf"
SNELL_SERVICE="/etc/init.d/snell"
SNELL_USER="snell"
SNELL_GROUP="snell"
VERSION="${VERSION:-5.0.1}"

info() { printf "${GREEN}[信息] %s${RESET}\n" "$1"; }
warn() { printf "${YELLOW}[警告] %s${RESET}\n" "$1"; }
err() { printf "${RED}[错误] %s${RESET}\n" "$1" >&2; }

require_root() {
  [ "$(id -u)" -eq 0 ] || {
    err "请用 root 运行"
    exit 1
  }
}

require_alpine() {
  [ -f /etc/alpine-release ] || {
    err "这是 Alpine 专版脚本"
    exit 1
  }
}

install_deps() {
  info "安装依赖..."
  apk update
  apk add --no-cache bash wget curl unzip iproute2 coreutils grep sed gawk upx
}

ensure_user_group() {
  addgroup -S "$SNELL_GROUP" >/dev/null 2>&1 || true
  if ! id -u "$SNELL_USER" >/dev/null 2>&1; then
    adduser -S -D -H -s /sbin/nologin -G "$SNELL_GROUP" "$SNELL_USER"
  fi
}

get_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "aarch64" ;;
    armv7l|armv7) echo "armv7l" ;;
    *)
      err "不支持的架构: $(uname -m)"
      exit 1
      ;;
  esac
}

download_snell() {
  local arch url tmp
  arch="$(get_arch)"
  url="https://dl.nssurge.com/snell/snell-server-v${VERSION}-linux-${arch}.zip"
  tmp="$(mktemp -d)"

  info "下载: $url"
  if ! curl -sLo "$tmp/snell.zip" --connect-timeout 60 "$url"; then
    rm -rf "$tmp"
    err "下载失败"
    return 1
  fi

  unzip -oq "$tmp/snell.zip" -d "$tmp/"
  install -m 755 "$tmp/snell-server" "$SNELL_BIN"

  if command -v upx >/dev/null 2>&1; then
    upx -d "$SNELL_BIN" >/dev/null 2>&1 || true
  fi

  rm -rf "$tmp"
  info "Snell v${VERSION} 已安装到 $SNELL_BIN"
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
  local ip
  for url in https://api.ipify.org https://ip.sb https://checkip.amazonaws.com; do
    ip="$(curl -4s --max-time 5 "$url" 2>/dev/null || true)"
    [ -n "$ip" ] && { echo "$ip"; return; }
    ip="$(wget -4qO- --timeout=5 "$url" 2>/dev/null || true)"
    [ -n "$ip" ] && { echo "$ip"; return; }
  done
  echo "YOUR_SERVER_IP"
}

get_system_dns() {
  grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd ',' -
}

write_service() {
  cat > "$SNELL_SERVICE" <<EOF
#!/sbin/openrc-run
name="Snell Server v5"
description="Snell Server v5"
command="$SNELL_BIN"
command_args="-c $SNELL_CONF"
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

write_config() {
  mkdir -p "$SNELL_DIR"

  printf '请输入端口 [1025-65535，留空随机]: '
  read -r input_port
  if [ -z "$input_port" ]; then
    PORT="$(shuf -i 1025-65535 -n 1)"
  else
    validate_port "$input_port" || {
      err "端口无效"
      return 1
    }
    PORT="$input_port"
  fi

  if port_in_use "$PORT"; then
    err "端口 $PORT 已被占用"
    return 1
  fi

  printf '请输入 PSK（留空随机生成）: '
  read -r PSK
  [ -n "$PSK" ] || PSK="$(random_key)"

  echo 'OBFS: 1) off  2) http  3) tls'
  printf '请选择 [默认 1]: '
  read -r obfs_choice
  case "${obfs_choice:-1}" in
    2) OBFS='http' ;;
    3) OBFS='tls' ;;
    *) OBFS='off' ;;
  esac

  echo 'IPv6: 1) 关闭  2) 开启'
  printf '请选择 [默认 1]: '
  read -r ipv6_choice
  case "${ipv6_choice:-1}" in
    2)
      IPV6='true'
      LISTEN="::0:$PORT"
      ;;
    *)
      IPV6='false'
      LISTEN="0.0.0.0:$PORT"
      ;;
  esac

  echo 'TCP Fast Open: 1) 开启  2) 关闭'
  printf '请选择 [默认 1]: '
  read -r tfo_choice
  case "${tfo_choice:-1}" in
    2) TFO='false' ;;
    *) TFO='true' ;;
  esac

  DEFAULT_DNS="$(get_system_dns)"
  [ -n "$DEFAULT_DNS" ] || DEFAULT_DNS='1.1.1.1,8.8.8.8'
  printf '请输入 DNS [默认 %s]: ' "$DEFAULT_DNS"
  read -r DNS
  DNS="${DNS:-$DEFAULT_DNS}"

  cat > "$SNELL_CONF" <<EOF
[snell-server]
listen = $LISTEN
psk = $PSK
ipv6 = $IPV6
tfo = $TFO
obfs = $OBFS
dns = $DNS
EOF

  SERVER_IP="$(get_public_ip)"
  HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo snell)"
  cat > "$SNELL_INFO" <<EOF
$HOSTNAME_SHORT = snell, $SERVER_IP, $PORT, psk=$PSK, version=5, reuse=true, tfo=$TFO
EOF

  chown -R "$SNELL_USER:$SNELL_GROUP" "$SNELL_DIR" 2>/dev/null || chown -R "$SNELL_USER" "$SNELL_DIR"
  chmod 755 "$SNELL_DIR"
  chmod 600 "$SNELL_CONF"

  info "配置已写入: $SNELL_CONF"
  echo "---------------------------------"
  cat "$SNELL_INFO"
  echo "---------------------------------"
}

test_config() {
  info "检查配置是否可启动..."
  "$SNELL_BIN" -c "$SNELL_CONF" >/tmp/snell-test.log 2>&1 &
  TEST_PID=$!
  sleep 1
  if kill -0 "$TEST_PID" >/dev/null 2>&1; then
    kill "$TEST_PID" >/dev/null 2>&1 || true
    wait "$TEST_PID" 2>/dev/null || true
    rm -f /tmp/snell-test.log
    info "配置测试通过"
  else
    err "Snell 启动测试失败"
    cat /tmp/snell-test.log || true
    return 1
  fi
}

install_snell() {
  install_deps
  ensure_user_group
  download_snell
  write_config
  write_service
  test_config || return 1
  rc-service snell restart >/dev/null 2>&1 || rc-service snell start
  info "Snell 已安装并启动"
}

update_snell() {
  [ -f "$SNELL_CONF" ] || {
    err "未找到已有配置，无法更新"
    return 1
  }
  install_deps
  download_snell
  rc-service snell restart >/dev/null 2>&1 || rc-service snell start
  info "Snell 已更新"
}

modify_config() {
  [ -x "$SNELL_BIN" ] || {
    err "Snell 尚未安装"
    return 1
  }
  write_config
  test_config || return 1
  rc-service snell restart >/dev/null 2>&1 || rc-service snell start
  info "配置已更新并重启"
}

uninstall_snell() {
  warn "即将卸载 Snell"
  rc-service snell stop >/dev/null 2>&1 || true
  rc-update del snell default >/dev/null 2>&1 || true
  rm -f "$SNELL_SERVICE"
  rm -f "$SNELL_BIN"
  rm -rf "$SNELL_DIR"
  info "Snell 已卸载"
}

show_config() {
  if [ ! -f "$SNELL_CONF" ]; then
    err "配置文件不存在"
    return 1
  fi
  echo '====== snell-server.conf ======'
  cat "$SNELL_CONF"
  echo '====== 客户端示例 ======'
  cat "$SNELL_INFO" 2>/dev/null || true
}

show_logs() {
  if [ -f /var/log/snell.log ]; then
    tail -n 100 /var/log/snell.log
  else
    echo "暂无 /var/log/snell.log"
  fi
  if [ -f /var/log/snell.err ]; then
    echo
    echo "====== 错误日志 ======"
    tail -n 100 /var/log/snell.err
  fi
}

show_menu() {
  clear
  echo '====== Snell v5 Alpine 管理 ======'
  echo '1. 安装 Snell v5'
  echo '2. 更新 Snell'
  echo '3. 修改配置'
  echo '4. 启动 Snell'
  echo '5. 停止 Snell'
  echo '6. 重启 Snell'
  echo '7. 查看配置'
  echo '8. 查看日志'
  echo '9. 卸载 Snell'
  echo '0. 退出'
}

pause_wait() {
  printf '按回车返回菜单...'
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
      1) install_snell; pause_wait ;;
      2) update_snell; pause_wait ;;
      3) modify_config; pause_wait ;;
      4) rc-service snell start; pause_wait ;;
      5) rc-service snell stop; pause_wait ;;
      6) rc-service snell restart; pause_wait ;;
      7) show_config; pause_wait ;;
      8) show_logs; pause_wait ;;
      9) uninstall_snell; pause_wait ;;
      0) exit 0 ;;
      *) err '无效选项'; pause_wait ;;
    esac
  done
}

main "$@"
