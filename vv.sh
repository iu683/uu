#!/bin/sh
set -eu

SNELL_DIR="/etc/snell"
SNELL_BIN="$SNELL_DIR/snell-server"
SNELL_CONF="$SNELL_DIR/snell-server.conf"
SNELL_SURGE_CONF="$SNELL_DIR/config.txt"
SNELL_SERVICE="/etc/init.d/snell"
SNELL_USER="snell"
SNELL_GROUP="snell"
VERSION="v5.0.1"
OBFS="off"
IPV6="false"
TFO="true"

info() { printf '[信息] %s\n' "$1"; }
err() { printf '[错误] %s\n' "$1" >&2; }

require_root() {
  [ "$(id -u)" -eq 0 ] || { err "请用 root 运行"; exit 1; }
}

require_alpine() {
  [ -f /etc/alpine-release ] || { err "这是 Alpine 专用脚本"; exit 1; }
}

install_deps() {
  info "安装依赖..."
  apk update
  apk add wget unzip iproute2 coreutils
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
    *) err "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

download_snell() {
  arch="$(get_arch)"
  url="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-${arch}.zip"
  info "下载 Snell: $url"
  mkdir -p "$SNELL_DIR"
  cd "$SNELL_DIR"
  rm -f snell.zip
  wget -O snell.zip "$url"
  unzip -o snell.zip -d "$SNELL_DIR"
  rm -f snell.zip
  chmod 755 "$SNELL_BIN"
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

random_key() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16
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

ask_config() {
  while :; do
    printf '请输入端口 [1025-65535]: '
    read -r PORT
    if ! validate_port "$PORT"; then
      err "端口无效"
      continue
    fi
    if port_in_use "$PORT"; then
      err "端口已占用: $PORT"
      continue
    fi
    break
  done

  printf '请输入 DNS [默认 1.1.1.1,8.8.8.8]: '
  read -r DNS
  DNS="${DNS:-1.1.1.1,8.8.8.8}"

  PSK="$(random_key)"
  LISTEN="0.0.0.0:$PORT"
}

write_config() {
  cat > "$SNELL_CONF" <<EOF
[snell-server]
listen = $LISTEN
psk = $PSK
ipv6 = $IPV6
tfo = $TFO
obfs = $OBFS
dns = $DNS
EOF

  PUBLIC_IP="$(get_public_ip)"
  HOST_NAME="$(hostname -s 2>/dev/null || echo snell)"
  cat > "$SNELL_SURGE_CONF" <<EOF
$HOST_NAME = snell, $PUBLIC_IP, $PORT, psk=$PSK, version=5, reuse=true, tfo=$TFO
EOF

  chown -R "$SNELL_USER:$SNELL_GROUP" "$SNELL_DIR" 2>/dev/null || chown -R "$SNELL_USER" "$SNELL_DIR"
  chmod 755 "$SNELL_DIR"
  chmod 600 "$SNELL_CONF"
}

write_service() {
  cat > "$SNELL_SERVICE" <<'EOF'
#!/sbin/openrc-run
name="Snell Server"
description="Snell Server"
command="/etc/snell/snell-server"
command_args="-c /etc/snell/snell-server.conf"
command_user="snell"
pidfile="/run/snell.pid"
command_background="yes"
start_stop_daemon_args="--make-pidfile --pidfile /run/snell.pid"

depend() {
  need net
}
EOF
  chmod 755 "$SNELL_SERVICE"
  rc-update add snell default >/dev/null 2>&1 || true
}

test_binary() {
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

start_service() {
  info "启动服务..."
  rc-service snell restart >/tmp/snell-service.log 2>&1 || rc-service snell start >/tmp/snell-service.log 2>&1 || {
    err "服务启动失败"
    cat /tmp/snell-service.log || true
    exit 1
  }
}

show_result() {
  echo
  echo '====== 安装完成 ======'
  echo "端口: $PORT"
  echo "DNS: $DNS"
  echo "PSK: $PSK"
  echo '------ Surge 示例 ------'
  cat "$SNELL_SURGE_CONF"
  echo '------------------------'
}

main() {
  require_root
  require_alpine
  install_deps
  ensure_user_group
  download_snell
  ask_config
  write_config
  write_service
  test_binary
  start_service
  show_result
}

main "$@"
