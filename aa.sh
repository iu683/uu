#!/bin/bash
set -e

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ================== 变量 ==================
SNELL_DIR="/etc/snell"
SNELL_CONFIG="$SNELL_DIR/snell-server.conf"
SNELL_SYSTEMD_SERVICE="/etc/systemd/system/snell.service"
SNELL_OPENRC_SERVICE="/etc/init.d/snell"
LOG_FILE="/var/log/snell_manager.log"
VERSION="v5.0.1"
SERVICE_TYPE=""

# ================== 基础函数 ==================
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo -e "${RED}请使用 root 权限运行此脚本！${RESET}"
        exit 1
    fi
}

detect_service_type() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        SERVICE_TYPE="systemd"
    elif [ -f /sbin/openrc-run ] || command -v rc-service >/dev/null 2>&1; then
        SERVICE_TYPE="openrc"
    else
        echo -e "${RED}未检测到受支持的服务管理器(systemd/OpenRC)${RESET}"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    elif [ -f /etc/redhat-release ]; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

install_dependencies() {
    echo -e "${GREEN}[信息] 检查并安装依赖...${RESET}"
    detect_os

    case "$OS" in
        alpine)
            apk update
            apk add bash wget curl unzip iproute2 coreutils grep sed gawk
            ;;
        debian)
            apt update
            apt install -y wget curl unzip iproute2 coreutils grep sed gawk
            ;;
        redhat)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y wget curl unzip iproute iproute-tc coreutils grep sed gawk
            else
                yum install -y wget curl unzip iproute coreutils grep sed gawk
            fi
            ;;
        *)
            echo -e "${YELLOW}[警告] 未识别系统，请手动确保已安装: wget curl unzip ss shuf awk grep sed${RESET}"
            ;;
    esac
}

create_user() {
    if ! id -u snell >/dev/null 2>&1; then
        local nologin_path="/usr/sbin/nologin"
        [ -x /sbin/nologin ] && nologin_path="/sbin/nologin"
        [ -x /bin/false ] && nologin_path="${nologin_path:-/bin/false}"

        if command -v useradd >/dev/null 2>&1; then
            useradd -r -s "$nologin_path" snell
        elif command -v adduser >/dev/null 2>&1; then
            adduser -S -D -H -s "$nologin_path" snell
        else
            echo -e "${RED}无法创建 snell 用户，请手动创建${RESET}"
            exit 1
        fi
    fi
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null || true)
            if [[ -n "$ip" ]]; then
                echo "$ip"
                return 0
            fi
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null || true)
            if [[ -n "$ip" ]]; then
                echo "$ip"
                return 0
            fi
        done
    done
    return 1
}

check_port() {
    if ss -tln 2>/dev/null | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1025 ] && [ "$1" -le 65535 ]
}

random_key() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

get_system_dns() {
    grep -E "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd "," -
}

pause() {
    read -n 1 -s -r -p "按任意键返回菜单..."
    echo
}

log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *)
            echo -e "${RED}不支持的系统架构: $(uname -m)${RESET}"
            exit 1
            ;;
    esac
}

service_enable() {
    if [[ "$SERVICE_TYPE" == "systemd" ]]; then
        systemctl daemon-reload
        systemctl enable snell
    else
        chmod +x "$SNELL_OPENRC_SERVICE"
        rc-update add snell default
    fi
}

service_start() {
    if [[ "$SERVICE_TYPE" == "systemd" ]]; then
        systemctl start snell
    else
        rc-service snell start
    fi
}

service_stop() {
    if [[ "$SERVICE_TYPE" == "systemd" ]]; then
        systemctl stop snell || true
    else
        rc-service snell stop || true
    fi
}

service_restart() {
    if [[ "$SERVICE_TYPE" == "systemd" ]]; then
        systemctl restart snell
    else
        rc-service snell restart
    fi
}

service_disable() {
    if [[ "$SERVICE_TYPE" == "systemd" ]]; then
        systemctl disable snell || true
        rm -f "$SNELL_SYSTEMD_SERVICE"
        systemctl daemon-reload
    else
        rc-update del snell default || true
        rm -f "$SNELL_OPENRC_SERVICE"
    fi
}

service_logs() {
    if [[ "$SERVICE_TYPE" == "systemd" ]]; then
        journalctl -u snell -e --no-pager
    else
        if [ -f "$LOG_FILE" ]; then
            tail -n 100 "$LOG_FILE"
        else
            echo -e "${YELLOW}暂无日志文件${RESET}"
        fi
    fi
}

# ================== 配置 Snell ==================
configure_snell() {
    echo -e "${GREEN}[信息] 开始配置 Snell...${RESET}"
    mkdir -p "$SNELL_DIR"

    read -p "请输入端口 [1025-65535, 默认随机]: " input_port
    if [[ -z "$input_port" ]]; then
        port=$(shuf -i 1025-65535 -n1)
    else
        if ! validate_port "$input_port"; then
            echo -e "${RED}端口无效，请输入 1025-65535 之间的数字${RESET}"
            return 1
        fi
        port="$input_port"
    fi
    check_port "$port" || return 1

    read -p "请输入Snell密钥 (默认:随机生成): " key
    key=${key:-$(random_key)}

    echo -e "${YELLOW}配置 OBFS：[注意] 无特殊作用不建议启用${RESET}"
    echo "1. TLS   2. HTTP   3. 关闭"
    read -p "(默认: 3): " obfs
    case $obfs in
        1) obfs="tls" ;;
        2) obfs="http" ;;
        *) obfs="off" ;;
    esac

    echo -e "${YELLOW}是否开启 IPv6 解析？${RESET}"
    echo "1. 开启   2. 关闭"
    read -p "(默认: 2): " ipv6
    ipv6=${ipv6:-2}
    ipv6=$([ "$ipv6" = "1" ] && echo true || echo false)

    echo -e "${YELLOW}是否开启 TCP Fast Open？${RESET}"
    echo "1. 开启   2. 关闭"
    read -p "(默认: 1): " tfo
    tfo=${tfo:-1}
    tfo=$([ "$tfo" = "1" ] && echo true || echo false)

    default_dns=$(get_system_dns)
    [[ -z "$default_dns" ]] && default_dns="1.1.1.1,8.8.8.8"
    read -p "请输入 DNS (默认: $default_dns): " dns
    dns=${dns:-$default_dns}

    if [[ "$ipv6" == "true" ]]; then
        LISTEN="::0:$port"
    else
        LISTEN="0.0.0.0:$port"
    fi

    cat > "$SNELL_CONFIG" <<EOF
[snell-server]
listen = $LISTEN
psk = $key
obfs = $obfs
ipv6 = $ipv6
tfo = $tfo
dns = $dns
EOF

    IP=$(get_public_ip || true)
    [[ -z "$IP" ]] && IP="YOUR_SERVER_IP"
    HOSTNAME=$(hostname -s 2>/dev/null || echo "snell")

    cat <<EOF > "$SNELL_DIR/config.txt"
$HOSTNAME = snell, $IP, $port, psk=$key, version=5, tfo=$tfo, reuse=true, ecn=true
EOF

    echo -e "${GREEN}[完成] 配置已写入 $SNELL_CONFIG${RESET}"
    echo -e "${GREEN}====== Snell Server 配置信息 ======${RESET}"
    echo -e "${YELLOW} IP 地址        : $IP${RESET}"
    echo -e "${YELLOW} 端口           : $port${RESET}"
    echo -e "${YELLOW} 密钥           : $key${RESET}"
    echo -e "${YELLOW} OBFS           : $obfs${RESET}"
    echo -e "${YELLOW} IPv6           : $ipv6${RESET}"
    echo -e "${YELLOW} TFO            : $tfo${RESET}"
    echo -e "${YELLOW} DNS            : $dns${RESET}"
    echo -e "${YELLOW} 版本           : ${VERSION}${RESET}"
    echo -e "${YELLOW}---------------------------------${RESET}"
    echo -e "${YELLOW}[信息] Surge 配置：${RESET}"
    cat "$SNELL_DIR/config.txt"
    echo -e "${YELLOW}---------------------------------\n${RESET}"
}

# ================== 创建服务 ==================
create_service() {
    if [[ "$SERVICE_TYPE" == "systemd" ]]; then
        cat > "$SNELL_SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Snell Server
After=network.target

[Service]
ExecStart=$SNELL_DIR/snell-server -c $SNELL_CONFIG
Restart=on-failure
User=snell
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    else
        cat > "$SNELL_OPENRC_SERVICE" <<EOF
#!/sbin/openrc-run
name="Snell Server"
description="Snell Server"
command="$SNELL_DIR/snell-server"
command_args="-c $SNELL_CONFIG"
command_user="snell"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background="yes"

depend() {
    need net
}
EOF
    fi
}

# ================== 安装 Snell ==================
install_snell() {
    echo -e "${GREEN}[信息] 开始安装 Snell...${RESET}"
    install_dependencies
    create_user
    mkdir -p "$SNELL_DIR"
    cd "$SNELL_DIR"

    ARCH=$(get_arch)
    SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-${ARCH}.zip"

    if ! wget -O snell.zip "$SNELL_URL"; then
        echo -e "${RED}下载 Snell 失败，请检查网络或下载地址${RESET}"
        return 1
    fi

    unzip -o snell.zip -d "$SNELL_DIR"
    rm -f snell.zip
    chmod +x "$SNELL_DIR/snell-server"

    configure_snell
    create_service
    service_enable
    service_start

    echo -e "${GREEN}[完成] Snell 已安装并启动${RESET}"
    log "Snell 已安装并启动"
}

# ================== 更新 Snell ==================
update_snell() {
    echo -e "${GREEN}[信息] 更新 Snell...${RESET}"

    if [ ! -f "$SNELL_CONFIG" ]; then
        echo -e "${RED}未找到配置文件，无法更新${RESET}"
        return 1
    fi

    service_stop
    cd "$SNELL_DIR"

    ARCH=$(get_arch)
    SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-${ARCH}.zip"

    if ! wget -O snell.zip "$SNELL_URL"; then
        echo -e "${RED}下载 Snell 失败，请检查网络或下载地址${RESET}"
        return 1
    fi

    unzip -o snell.zip -d "$SNELL_DIR"
    rm -f snell.zip
    chmod +x "$SNELL_DIR/snell-server"

    service_start
    echo -e "${GREEN}[完成] Snell 已更新${RESET}"
    log "Snell 已更新"
}

# ================== 卸载 Snell ==================
uninstall_snell() {
    echo -e "${RED}[警告] 卸载 Snell...${RESET}"
    service_stop
    service_disable
    rm -rf "$SNELL_DIR"
    echo -e "${GREEN}[完成] Snell 已卸载${RESET}"
    log "Snell 已卸载"
}

# ================== 菜单 ==================
show_menu() {
    clear
    echo -e "${GREEN}====== Snell 管理 ======${RESET}"
    echo -e "${GREEN}1. 安装 Snell${RESET}"
    echo -e "${GREEN}2. 更新 Snell${RESET}"
    echo -e "${GREEN}3. 卸载 Snell${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Snell${RESET}"
    echo -e "${GREEN}6. 停止 Snell${RESET}"
    echo -e "${GREEN}7. 重启 Snell${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看当前配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
}

# ================== 主程序 ==================
check_root
detect_service_type

while true; do
    show_menu
    read -r -p $'\033[32m请输入选项: \033[0m' choice
    case $choice in
        1) install_snell; pause ;;
        2) update_snell; pause ;;
        3) uninstall_snell; pause ;;
        4)
            configure_snell
            service_restart || true
            pause
            ;;
        5)
            service_start
            echo -e "${GREEN}[完成] Snell 已启动${RESET}"
            log "Snell 启动"
            pause
            ;;
        6)
            service_stop
            echo -e "${GREEN}[完成] Snell 已停止${RESET}"
            log "Snell 停止"
            pause
            ;;
        7)
            service_restart
            echo -e "${GREEN}[完成] Snell 已重启${RESET}"
            log "Snell 重启"
            pause
            ;;
        8)
            service_logs
            pause
            ;;
        9)
            if [ -f "$SNELL_CONFIG" ]; then
                echo -e "${GREEN}====== 当前 Snell 配置 ======${RESET}"
                cat "$SNELL_CONFIG"
                echo -e "${GREEN}====== Surge 配置示例 ======${RESET}"
                cat "$SNELL_DIR/config.txt" 2>/dev/null || true
            else
                echo -e "${RED}配置文件不存在${RESET}"
            fi
            pause
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${RESET}"; pause ;;
    esac
done
