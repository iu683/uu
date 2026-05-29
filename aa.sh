#!/bin/bash

# =========================================================
# Shadowsocks-Rust 管理脚本 (Alpine Linux 专用)
# 加密方式: 2022-blake3-aes-256-gcm
# =========================================================

set -euo pipefail

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ================== 基础变量 ==================
SCRIPT_VERSION="5.0-Alpine"
SS_DIR="/etc/ss-rust"
SS_CONFIG="${SS_DIR}/config.json"
SS_INIT_SCRIPT="/etc/init.d/ss-rust"
BINARY_PATH="/usr/local/bin/ssserver"
LOG_FILE="/var/log/ss-rust.log"
RUN_USER="ss-rust"
METHOD="2022-blake3-aes-256-gcm"
KEY_BYTES=32
TMP_DIR=$(mktemp -d -t ss-rust.XXXXXX)

# ================== cleanup ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# ================== 日志与交互 ==================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

pause() {
    read -n 1 -s -r -p "按任意键返回菜单..."
    echo
}

# ================== 环境准备 ==================
create_user() {
    if ! id -u "$RUN_USER" &>/dev/null; then
        adduser -S -D -H -s /sbin/nologin "$RUN_USER"
    fi
}

get_public_ip() {
    local ip
    ip=$(curl -4fsSL --max-time 5 https://api.ipify.org || curl -4fsSL --max-time 5 https://ifconfig.me || echo "YOUR_IP")
    echo "$ip"
}

check_deps() {
    echo -e "${GREEN}[信息] 检查系统依赖...${RESET}"
    apk update
    # Alpine 基础依赖
    apk add curl wget tar xz openssl iproute2 coreutils
    echo -e "${GREEN}[完成] 依赖检查完成${RESET}"
}

check_port() {
    if ss -tulnH "( sport = :$1 )" | grep -q .; then
        echo -e "${RED}端口 $1 已被占用${RESET}"
        return 1
    fi
}

random_key() {
    openssl rand -base64 "$KEY_BYTES" | tr -d '\n'
}

random_port() {
    # Alpine 默认没有 shuf，使用 awk 模拟
    awk -v min=2000 -v max=65000 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'
}

get_system_dns() {
    grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd "," -
}

validate_password() {
    local password="$1"
    if ! echo "$password" | base64 -d >/dev/null 2>&1; then
        echo -e "${RED}密码不是合法 Base64${RESET}"
        return 1
    fi
    local decoded_len=$(echo "$password" | base64 -d 2>/dev/null | wc -c)
    if [[ "$decoded_len" -ne "$KEY_BYTES" ]]; then
        echo -e "${RED}密码必须为 ${KEY_BYTES} 字节${RESET}"
        return 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64-unknown-linux-musl" ;;
        aarch64) echo "aarch64-unknown-linux-musl" ;;
        *) echo -e "${RED}不支持架构: $(uname -m)${RESET}"; exit 1 ;;
    esac
}

get_latest_version() {
    curl -fsSL "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | grep tag_name | cut -d '"' -f4 | sed 's/v//'
}

# ================== 配置写入 ==================
write_config() {
    local port="$1"
    local password="$2"
    local dns="$3"

    mkdir -p "$SS_DIR"
    DNS_JSON=$(echo "$dns" | awk -F',' '{
        for(i=1;i<=NF;i++){
            gsub(/^[ \t]+|[ \t]+$/, "", $i)
            printf "%s\"%s\"", (i>1?",":""), $i
        }
    }')

    cat > "$SS_CONFIG" <<EOF
{
    "server": "::",
    "server_port": $port,
    "password": "$password",
    "method": "$METHOD",
    "fast_open": true,
    "mode": "tcp_and_udp",
    "timeout": 300,
    "no_delay": true,
    "ipv6_first": false,
    "nameserver": [ $DNS_JSON ]
}
EOF
    chmod 600 "$SS_CONFIG"
    chown -R "$RUN_USER":"$RUN_USER" "$SS_DIR"
}

generate_links() {
    local port="$1"
    local password="$2"
    local ip=$(get_public_ip)
    local hostname=$(hostname)
    local encoded=$(echo -n "${METHOD}:${password}" | base64 | tr -d '\n')
    
    echo "ss://${encoded}@${ip}:${port}#${hostname}-SS2022" > "${SS_DIR}/ss.txt"
}

# ================== 核心功能 ==================
configure_ss() {
    echo -e "${GREEN}[信息] 开始配置 Shadowsocks-Rust...${RESET}"
    while true; do
        read -p "请输入端口 (默认:随机): " input_port
        port=${input_port:-$(random_port)}
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            check_port "$port" || continue
            break
        else echo -e "${RED}端口无效${RESET}"; fi
    done

    read -p "请输入密码 (默认:随机): " input_password
    password=${input_password:-$(random_key)}
    if [[ -n "$input_password" ]]; then validate_password "$password" || return; fi

    default_dns=$(get_system_dns)
    default_dns=${default_dns:-"1.1.1.1,8.8.8.8"}
    read -p "请输入 DNS (默认:$default_dns): " dns
    dns=${dns:-$default_dns}

    write_config "$port" "$password" "$dns"
    generate_links "$port" "$password"
    echo -e "${GREEN}[完成] 配置已保存${RESET}"
}

install_ss() {
    check_deps
    create_user
    mkdir -p "$SS_DIR"
    cd "$TMP_DIR"
    
    VERSION=$(get_latest_version)
    ARCH=$(detect_arch)
    URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${VERSION}/shadowsocks-v${VERSION}.${ARCH}.tar.xz"

    echo -e "${GREEN}正在下载版本 v$VERSION...${RESET}"
    wget -O ss.tar.xz "$URL"
    tar -xf ss.tar.xz
    install -m 755 ssserver "$BINARY_PATH"
    echo "$VERSION" > "${SS_DIR}/version.txt"

    configure_ss

    # ===== OpenRC Init Script =====
    cat > "$SS_INIT_SCRIPT" <<EOF
#!/sbin/openrc-run

name="ss-rust"
description="Shadowsocks-Rust Server"
command="${BINARY_PATH}"
command_args="-c ${SS_CONFIG}"
command_user="${RUN_USER}:${RUN_USER}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

depend() {
    need net
    after firewall
}
EOF
    chmod +x "$SS_INIT_SCRIPT"
    rc-update add ss-rust default
    rc-service ss-rust start
    
    echo -e "${GREEN}[完成] 安装成功并已启动${RESET}"
}

uninstall_ss() {
    echo -e "${RED}[警告] 正在卸载...${RESET}"
    rc-service ss-rust stop || true
    rc-update del ss-rust || true
    rm -f "$SS_INIT_SCRIPT" "$BINARY_PATH"
    rm -rf "$SS_DIR"
    echo -e "${GREEN}[完成] 卸载成功${RESET}"
}

# ================== 菜单 ==================
show_menu() {
    clear
    STATUS=$(rc-service ss-rust status 2>/dev/null | grep -q "started" && echo -e "${GREEN}● 运行中${RESET}" || echo -e "${RED}● 未运行${RESET}")
    VERSION_SHOW=$( [ -f "${SS_DIR}/version.txt" ] && echo "v$(cat ${SS_DIR}/version.txt)" || echo "未安装")
    PORT_SHOW=$( [ -f "$SS_CONFIG" ] && grep server_port "$SS_CONFIG" | grep -o '[0-9]\+' || echo "-")

    echo -e "${BLUE}================================${RESET}"
    echo -e "${BLUE}   SS-Rust 管理面板 (Alpine)    ${RESET}"
    echo -e "${BLUE}================================${RESET}"
    echo -e "状态   : $STATUS"
    echo -e "版本   : ${YELLOW}${VERSION_SHOW}${RESET}"
    echo -e "端口   : ${YELLOW}${PORT_SHOW}${RESET}"
    echo -e "${BLUE}================================${RESET}"
    echo -e "1. 安装 Shadowsocks-Rust"
    echo -e "2. 卸载 Shadowsocks-Rust"
    echo -e "3. 修改配置"
    echo -e "4. 启动 / 停止 / 重启"
    echo -e "5. 查看节点配置"
    echo -e "0. 退出"
    echo -e "${BLUE}================================${RESET}"
}

while true; do
    show_menu
    read -r -p "请输入选项: " choice
    case $choice in
        1) install_ss; pause ;;
        2) uninstall_ss; pause ;;
        3) [ -f "$SS_CONFIG" ] && configure_ss && rc-service ss-rust restart || echo "未安装"; pause ;;
        4) 
            echo "1.启动 2.停止 3.重启"
            read -p "选择: " op
            case $op in
                1) rc-service ss-rust start ;;
                2) rc-service ss-rust stop ;;
                3) rc-service ss-rust restart ;;
            esac
            pause ;;
        5) [ -f "${SS_DIR}/ss.txt" ] && cat "${SS_DIR}/ss.txt" || echo "无配置"; pause ;;
        0) exit 0 ;;
        *) echo "无效输入"; sleep 1 ;;
    esac
done
