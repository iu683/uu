#!/bin/bash

# =========================================================
# Shadowsocks-Rust 管理脚本 (Alpine Linux )
# =========================================================

set -euo pipefail

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ================== 基础变量 ==================
SS_DIR="/etc/ss-rust"
SS_CONFIG="${SS_DIR}/config.json"
SS_INIT_SCRIPT="/etc/init.d/ss-rust"
BINARY_PATH="/usr/local/bin/ssserver"
LOG_FILE="/var/log/ss-rust.log"
RUN_USER="ss-rust"
RUN_GROUP="ss-rust"
METHOD="2022-blake3-aes-256-gcm"
TMP_DIR=$(mktemp -d -t ss-rust.XXXXXX)

# ================== 工具函数 ==================
info() { echo -e "${GREEN}[信息] $*${RESET}"; }
error() { echo -e "${RED}[错误] $*${RESET}"; }
pause() { echo; echo -ne "${GREEN}按任意键返回菜单...${RESET}"; read -n 1 -s; echo; }

get_latest_version() {
    curl -fsSL "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | \
    grep '"tag_name":' | head -n 1 | sed -E 's/.*"v?([^"]+)".*/\1/'
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64-unknown-linux-musl" ;;
        aarch64) echo "aarch64-unknown-linux-musl" ;;
        *) error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

# 自动获取 VPS 本地的 DNS 地址
get_vps_dns() {
    local dns_list=$(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd "," -)
    echo "${dns_list:-"1.1.1.1,8.8.8.8"}"
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    error "无法获取公网 IP 地址。" && return 1
}

# ================== 核心：写入配置 ==================
write_config_and_link() {
    local port=$1
    local pass=$2
    local dns_str=$3
    
    # 将逗号分隔的字符串转为 JSON 数组格式
    local dns_json=$(echo "\"${dns_str//,/\",\"}\"")

    cat > "$SS_CONFIG" <<EOF
{
    "server": "::",
    "server_port": $port,
    "password": "$pass",
    "method": "$METHOD",
    "fast_open": true,
    "mode": "tcp_and_udp",
    "timeout": 300,
    "no_delay": true,
    "ipv6_first": false,
    "nameserver": [$dns_json]
}
EOF
    chown "${RUN_USER}:${RUN_GROUP}" "$SS_CONFIG"
    chmod 600 "$SS_CONFIG"

    # 生成链接
    local ip=$(get_public_ip)
    [[ "$ip" =~ : ]] && ip="[$ip]"
    local encoded=$(echo -n "${METHOD}:${pass}" | base64 | tr -d '\n')
    echo "ss://${encoded}@${ip}:${port}#$(hostname)-SS2022" > "${SS_DIR}/ss.txt"
}

show_node_info() {
    if [[ -f "${SS_DIR}/ss.txt" ]]; then
        echo -e "${BLUE}================================${RESET}"
        echo -e "${YELLOW}       Shadowsocks 节点信息      ${RESET}"
        echo -e "${BLUE}================================${RESET}"
        echo -e "${GREEN}SS 链接:${RESET}"
        echo -e "${YELLOW}$(cat "${SS_DIR}/ss.txt")${RESET}"
        echo -e "${BLUE}================================${RESET}"
    else
        error "链接文件不存在。"
    fi
}

# ================== 功能：安装 ==================
install_ss() {
    info "准备环境中..."
    apk add curl wget tar xz openssl iproute2 coreutils >/dev/null 2>&1
    
    getent group "$RUN_GROUP" >/dev/null || addgroup -S "$RUN_GROUP"
    getent passwd "$RUN_USER" >/dev/null || adduser -S -D -H -G "$RUN_GROUP" -s /sbin/nologin "$RUN_USER"

    local ver=$(get_latest_version)
    local arch=$(detect_arch)
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${ver}/shadowsocks-v${ver}.${arch}.tar.xz"

    info "正在下载 v$ver..."
    cd "$TMP_DIR"
    wget -q --show-progress -O ss.tar.xz "$url"
    tar -xf ss.tar.xz
    install -m 755 ssserver "$BINARY_PATH"
    
    mkdir -p "$SS_DIR"
    echo "$ver" > "${SS_DIR}/version.txt"
    touch "$LOG_FILE"
    chown "${RUN_USER}:${RUN_GROUP}" "$LOG_FILE"

    # 交互配置
    local def_port=$((RANDOM % 40000 + 20000))
    local def_pass=$(openssl rand -base64 32 | tr -d '\n')
    local def_dns=$(get_vps_dns)

    echo -e "${YELLOW}--- 自定义配置 (回车使用默认值) ---${RESET}"
    read -rp "$(echo -e ${GREEN}"设置端口 [默认 $def_port]: "${RESET})" user_port
    user_port=${user_port:-$def_port}

    read -rp "$(echo -e ${GREEN}"设置密码 [默认随机生成]: "${RESET})" user_pass
    user_pass=${user_pass:-$def_pass}

    read -rp "$(echo -e ${GREEN}"设置 DNS (多个用逗号隔开) [默认 VPS 本地]: "${RESET})" user_dns
    user_dns=${user_dns:-$def_dns}

    write_config_and_link "$user_port" "$user_pass" "$user_dns"

    # 服务脚本
    cat > "$SS_INIT_SCRIPT" <<EOF
#!/sbin/openrc-run
name="ss-rust"
command="${BINARY_PATH}"
command_args="-c ${SS_CONFIG}"
command_user="${RUN_USER}:${RUN_GROUP}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"
depend() { need net; }
EOF
    chmod +x "$SS_INIT_SCRIPT"
    rc-update add ss-rust default
    rc-service ss-rust start
    info "安装完成！"
    show_node_info
}

# ================== 功能：修改配置 ==================
modify_ss() {
    if [[ ! -f "$SS_CONFIG" ]]; then
        error "未发现配置，请先安装"
        return 1
    fi

    # 提取旧值
    local old_port=$(grep -E '"server_port":' "$SS_CONFIG" | head -n 1 | grep -oE '[0-9]+')
    local old_pass=$(grep -E '"password":' "$SS_CONFIG" | head -n 1 | cut -d '"' -f4)
    # 提取旧 DNS 并转回逗号分隔格式
    local old_dns=$(grep -A 1 '"nameserver":' "$SS_CONFIG" | tail -n 1 | tr -d ' "[]' | sed 's/,$//')
    [[ -z "$old_dns" ]] && old_dns=$(get_vps_dns)

    echo -e "${YELLOW}--- 修改配置 (回车保持当前值) ---${RESET}"
    read -rp "$(echo -e ${GREEN}"新端口 [当前 $old_port]: "${RESET})" new_port
    new_port=${new_port:-$old_port}

    read -rp "$(echo -e ${GREEN}"新密码 [当前 $old_pass]: "${RESET})" new_pass
    new_pass=${new_pass:-$old_pass}

    read -rp "$(echo -e ${GREEN}"新 DNS (多个用逗号隔开) [当前 $old_dns]: "${RESET})" new_dns
    new_dns=${new_dns:-$old_dns}

    write_config_and_link "$new_port" "$new_pass" "$new_dns"
    rc-service ss-rust restart >/dev/null 2>&1 || true
    info "修改成功！"
    show_node_info
}

# ================== 菜单系统 ==================
while true; do
    if rc-service ss-rust status 2>/dev/null | grep -q "started"; then
        STATUS="${GREEN}● 运行中${RESET}"
    else
        STATUS="${RED}● 未运行${RESET}"
    fi

    VERSION_SHOW=$( [ -f "${SS_DIR}/version.txt" ] && echo "v$(cat ${SS_DIR}/version.txt)" || echo "未安装")
    PORT_SHOW=$( [ -f "$SS_CONFIG" ] && grep '"server_port"' "$SS_CONFIG" | head -n 1 | grep -oE '[0-9]+' || echo "-")

    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   Shadowsocks-Rust 管理面板    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $STATUS"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${VERSION_SHOW}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${PORT_SHOW}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Shadowsocks-Rust${RESET}"
    echo -e "${GREEN}2. 更新 Shadowsocks-Rust${RESET}"
    echo -e "${GREEN}3. 卸载 Shadowsocks-Rust${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Shadowsocks-Rust${RESET}"
    echo -e "${GREEN}6. 停止 Shadowsocks-Rust${RESET}"
    echo -e "${GREEN}7. 重启 Shadowsocks-Rust${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"

    read -rp "$(echo -e ${GREEN}"请输入选项: "${RESET})" choice
    case $choice in
        1) install_ss; pause ;;
        2) 
            latest=$(get_latest_version)
            info "正在更新到 v$latest..."
            install_ss; pause ;;
        3) 
            rc-service ss-rust stop || true
            rc-update del ss-rust || true
            rm -f "$SS_INIT_SCRIPT" "$BINARY_PATH"
            rm -rf "$SS_DIR" "$LOG_FILE"
            info "已卸载"; pause ;;
        4) modify_ss; pause ;;
        5) rc-service ss-rust start; pause ;;
        6) rc-service ss-rust stop; pause ;;
        7) rc-service ss-rust restart; pause ;;
        8) 
            info "实时日志 (Ctrl+C 退出):"
            [[ -f "$LOG_FILE" ]] && tail -f "$LOG_FILE" || error "无日志文件"; pause ;;
        9) show_node_info; pause ;;
        0) exit 0 ;;
        *) sleep 0.5 ;;
    esac
done
