#!/bin/sh
set -eu

GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
RESET='\033[0m'

SNELL_DIR="/etc/snell"
SNELL_BIN="$SNELL_DIR/snell-server"
SNELL_CONF="$SNELL_DIR/snell-server.conf"
SNELL_INFO="$SNELL_DIR/client.conf"
SNELL_SERVICE="/etc/init.d/snell"
SNELL_USER="snell"
SNELL_GROUP="snell"
VERSION="v5.0.1"

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
  apk add bash wget unzip iproute2 coreutils grep sed gawk
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
    i386|i686) echo "i386" ;;
    aarch64|arm64) echo "aarch64" ;;
    armv7l|armv7) echo "armv7l" ;;
    *)
      err "不支持的架构: $(uname -m)"
      exit 1
      ;;
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
  echo "YOUR_SERVER_IP"
}

get_system_dns() {
  grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd ',' -
}

download_snell() {
  mkdir -p "$SNELL_DIR"
  cd "$SNELL_DIR"

  url="$(get_download_url)"
  info "下载: $url"
  wget -O snell.zip "$url"
  unzip -o snell.zip -d "$SNELL_DIR"
  rm -f snell.zip
  chmod +x "$SNELL_BIN"
}

write_openrc_service() {
  cat > "$SNELL_SERVICE" <<EOF
#!/sbin/openrc-run
name="Snell Server"
description="Snell Server"
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

  echo 'OBFS: 1) off  2) http  3) tls'
  printf '请选择 [默认 1]: '
  read -r obfs_choice
  case "${obfs_choice:-1}" in
    2) obfs='http' ;;
    3) obfs='tls' ;;
    *) obfs='off' ;;
  esac

  echo 'IPv6: 1) 关闭  2) 开启'
  printf '请选择 [默认 1]: '
  read -r ipv6_choice
  case "${ipv6_choice:-1}" in
    2)
      ipv6='true'
      listen="[::]:$port"
      ;;
    *)
      ipv6='false'
      listen="0.0.0.0:$port"
      ;;
  esac

  echo 'TCP Fast Open: 1) 开启  2) 关闭'
  printf '请选择 [默认 1]: '
  read -r tfo_choice
  case "${tfo_choice:-1}" in
    2) tfo='false' ;;
    *) tfo='true' ;;
  esac

  default_dns="$(get_system_dns)"
  [ -n "$default_dns" ] || default_dns='1.1.1.1,8.8.8.8'
  printf '请输入 DNS [默认 %s]: ' "$default_dns"
  read -r dns
  dns="${dns:-$default_dns}"

  cat > "$SNELL_CONF" <<EOF
[snell-server]
listen = $listen
psk = $key
ipv6 = $ipv6
tfo = $tfo
obfs = $obfs
dns = $dns
EOF

  server_ip="$(get_public_ip)"
  hostname_short="$(hostname -s 2>/dev/null || echo snell)"
  cat > "$SNELL_INFO" <<EOF
$hostname_short = snell, $server_ip, $port, psk=$key, version=5, reuse=true, tfo=$tfo
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
  test_pid=$!
  sleep 1
  if kill -0 "$test_pid" >/dev/null 2>&1; then
    kill "$test_pid" >/dev/null 2>&1 || true
    wait "$test_pid" 2>/dev/null || true
    rm -f /tmp/snell-test.log
    info "配置测试通过"
  else
    err "Snell 启动测试失败"
    cat /tmp/snell-test.log || true
    exit 1
  fi
}

install_snell() {
  install_deps
  ensure_user_group
  download_snell
  write_config
  write_openrc_service
  test_config
  rc-service snell restart >/dev/null 2>&1 || rc-service snell start
  info "Snell 已安装并启动"
}

update_snell() {
  [ -f "$SNELL_CONF" ] || {
    err "未找到已有配置，无法更新"
    exit 1
  }

  cd "$SNELL_DIR"
  rc-service snell stop >/dev/null 2>&1 || true
  url="$(get_download_url)"
  info "下载: $url"
  wget -O snell.zip "$url"
  unzip -o snell.zip -d "$SNELL_DIR"
  rm -f snell.zip
  chmod +x "$SNELL_BIN"
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
      3) write_config && test_config && rc-service snell restart; pause_wait ;;
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
