#!/bin/sh
# Alpine Linux Snell Server 管理脚本
set -e

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ================== 变量 ==================
SNELL_DIR="/etc/snell"
SNELL_CONFIG="$SNELL_DIR/snell-server.conf"
SNELL_INIT="/etc/init.d/snell"
LOG_FILE="/var/log/snell_manager.log"

# ================== 工具函数 ==================
# Alpine 环境依赖检查
check_deps() {
    echo -e "${GREEN}[信息] 检查并安装依赖...${RESET}"
    apk add --no-cache wget unzip curl gcompat libstdc++
}

create_user() {
    if ! id -u snell >/dev/null 2>&1; then
        adduser -S -D -H -s /sbin/nologin snell
    fi
}

get_public_ip() {
    local ip
    ip=$(curl -4s --max-time 5 https://api.ipify.org || curl -4s --max-time 5 https://ip.sb)
    if [ -z "$ip" ]; then
        ip=$(curl -6s --max-time 5 https://api64.ipify.org || echo "未知IP")
    fi
    echo "$ip"
}

check_port() {
    if netstat -tln | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

random_key() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

get_system_dns() {
    grep -E "^nameserver" /etc/resolv.conf | awk '{print $2}' | tr '\n' ',' | sed 's/,$//'
}

pause() {
    echo -e "${YELLOW}按回车键继续...${RESET}"
    read -r
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# ================== 配置 Snell ==================
configure_snell() {
    echo -e "${GREEN}[信息] 开始配置 Snell...${RESET}"
    mkdir -p $SNELL_DIR

    read -p "请输入端口 [默认随机]: " input_port
    port=${input_port:-$(shuf -i 1025-65535 -n1)}
    check_port "$port" || return

    read -p "请输入Snell密钥 (默认:随机生成): " key
    key=${key:-$(random_key)}

    echo -e "${YELLOW}配置 OBFS：1. TLS  2. HTTP  3. 关闭 (默认: 3)${RESET}"
    read -p "选择: " obfs_choice
    case $obfs_choice in
        1) obfs="tls" ;;
        2) obfs="http" ;;
        *) obfs="off" ;;
    esac

    echo -e "${YELLOW}是否开启 IPv6 解析？ 1. 开启  2. 关闭 (默认: 2)${RESET}"
    read -p "选择: " ipv6_choice
    ipv6=$([ "$ipv6_choice" = "1" ] && echo true || echo false)

    echo -e "${YELLOW}是否开启 TCP Fast Open？ 1. 开启  2. 关闭 (默认: 1)${RESET}"
    read -p "选择: " tfo_choice
    tfo=$([ "$tfo_choice" = "2" ] && echo false || echo true)

    default_dns=$(get_system_dns)
    [[ -z "$default_dns" ]] && default_dns="1.1.1.1,8.8.8.8"
    read -p "请输入 DNS (默认: $default_dns): " dns
    dns=${dns:-$default_dns}

    LISTEN=$([ "$ipv6" = "true" ] && echo "::0:$port" || echo "0.0.0.0:$port")

    cat > $SNELL_CONFIG <<EOF
[snell-server]
listen = $LISTEN
psk = $key
obfs = $obfs
ipv6 = $ipv6
tfo = $tfo
dns = $dns
EOF

    IP=$(get_public_ip)
    HOSTNAME=$(hostname)
    cat <<EOF > $SNELL_DIR/config.txt
$HOSTNAME = snell, $IP, $port, psk=$key, version=5, tfo=$tfo, reuse=true, ecn=true
EOF

    echo -e "${GREEN}[完成] 配置已写入 $SNELL_CONFIG${RESET}"
}

# ================== 安装 Snell ==================
install_snell() {
    check_deps
    create_user
    mkdir -p $SNELL_DIR
    cd $SNELL_DIR

    ARCH=$(uname -m)
    VERSION="v5.0.1"
    [ "$ARCH" = "x86_64" ] && ARCH="amd64"
    [ "$ARCH" = "aarch64" ] && ARCH="aarch64"

    SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-${ARCH}.zip"

    echo -e "${GREEN}[信息] 下载 Snell ${VERSION}...${RESET}"
    wget -O snell.zip "$SNELL_URL"
    unzip -o snell.zip -d $SNELL_DIR
    rm -f snell.zip
    chmod +x $SNELL_DIR/snell-server

    configure_snell

    # 创建 OpenRC 服务脚本
    cat > $SNELL_INIT <<EOF
#!/sbin/openrc-run

name="snell-server"
description="Snell Server Proxy"
command="$SNELL_DIR/snell-server"
command_args="-c $SNELL_CONFIG"
command_user="snell"
pidfile="/run/snell.pid"
command_background="yes"

depend() {
    need net
    after firewall
}
EOF
    chmod +x $SNELL_INIT
    rc-update add snell default
    rc-service snell start

    echo -e "${GREEN}[完成] Snell 已安装并启动 (OpenRC)${RESET}"
    log "Snell 已在 Alpine 上安装"
}

# ================== 卸载 Snell ==================
uninstall_snell() {
    echo -e "${RED}[警告] 卸载 Snell...${RESET}"
    rc-service snell stop || true
    rc-update del snell || true
    rm -f $SNELL_INIT
    rm -rf $SNELL_DIR
    echo -e "${GREEN}[完成] Snell 已卸载${RESET}"
}

# ================== 菜单 ==================
show_menu() {
    clear
    echo -e "${GREEN}====== Snell 管理 (Alpine OpenRC) ======${RESET}"
    echo "1. 安装/更新 Snell"
    echo "2. 卸载 Snell"
    echo "3. 修改配置"
    echo "4. 启动"
    echo "5. 停止"
    echo "6. 重启"
    echo "7. 查看日志"
    echo "8. 查看当前配置"
    echo "0. 退出"
}

while true; do
    show_menu
    read -r -p "请输入选项: " choice
    case $choice in
        1) install_snell; pause ;;
        2) uninstall_snell; pause ;;
        3) configure_snell; rc-service snell restart; pause ;;
        4) rc-service snell start; pause ;;
        5) rc-service snell stop; pause ;;
        6) rc-service snell restart; pause ;;
        7) tail -n 50 $LOG_FILE; [ -f /var/log/messages ] && grep snell /var/log/messages | tail -n 20; pause ;;
        8)
            [ -f "$SNELL_CONFIG" ] && cat "$SNELL_CONFIG"
            [ -f "$SNELL_DIR/config.txt" ] && echo -e "\n${YELLOW}Surge 配置:${RESET}" && cat "$SNELL_DIR/config.txt"
            pause ;;
        0) exit 0 ;;
        *) echo "无效输入"; sleep 1 ;;
    esac
done
