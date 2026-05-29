#!/bin/bash

# =========================================================
# Shadowsocks-Rust 管理脚本 (Alpine Linux 专用修复版)
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
METHOD="2022-blake3-aes-256-gcm"
KEY_BYTES=32
TMP_DIR=$(mktemp -d -t ss-rust.XXXXXX)

# ================== 工具函数 ==================
info() { echo -e "${GREEN}[信息] $*${RESET}"; }
error() { echo -e "${RED}[错误] $*${RESET}"; }
pause() { echo; echo -ne "${GREEN}按任意键返回菜单...${RESET}"; read -n 1 -s; echo; }

# 🛠 修复：更鲁棒的版本号抓取逻辑
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

get_public_ip() {
    curl -4fsSL --max-time 5 https://api.ipify.org || echo "YOUR_IP"
}

get_system_dns() {
    grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | head -n 2 | paste -sd "," -
}

random_port() {
    awk -v min=20000 -v max=60000 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'
}

# ================== 核心功能 ==================

# 🛠 独立配置修改函数：读取当前值，回车默认
modify_ss() {
    if [[ ! -f "$SS_CONFIG" ]]; then
        error "未发现配置文件，请先安装。"
        return 1
    fi

    # 读取旧值
    local old_port=$(grep '"server_port"' "$SS_CONFIG" | grep -oE '[0-9]+')
    local old_pass=$(grep '"password"' "$SS_CONFIG" | cut -d '"' -f4)
    
    info "--- 修改配置 (回车保持当前值) ---"
    
    read -rp "$(echo -e ${GREEN}"请输入端口 (当前: $old_port): "${RESET})" new_port
    new_port=${new_port:-$old_port}

    read -rp "$(echo -e ${GREEN}"请输入密码 (当前: $old_pass): "${RESET})" new_pass
    new_pass=${new_pass:-$old_pass}

    # 写入新配置
    local dns=$(get_system_dns)
    dns=${dns:-"1.1.1.1,8.8.8.8"}
    
    # 构造 JSON (简单替换)
    sed -i "s/\"server_port\": [0-9]*/\"server_port\": $new_port/" "$SS_CONFIG"
    sed -i "s/\"password\": \".*\"/\"password\": \"$new_pass\"/" "$SS_CONFIG"

    # 生成链接
    local ip=$(get_public_ip)
    local encoded=$(echo -n "${METHOD}:${new_pass}" | base64 | tr -d '\n')
    echo "ss://${encoded}@${ip}:${new_port}#$(hostname)-SS2022" > "${SS_DIR}/ss.txt"

    rc-service ss-rust restart
    info "修改成功并已重启服务！"
}

install_ss() {
    info "检查并安装依赖..."
    apk add curl wget tar xz openssl iproute2 coreutils >/dev/null 2>&1
    
    # 创建用户
    if ! id -u "$RUN_USER" &>/dev/null; then
        adduser -S -D -H -s /sbin/nologin "$RUN_USER"
    fi

    local ver=$(get_latest_version)
    local arch=$(detect_arch)
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${ver}/shadowsocks-v${ver}.${arch}.tar.xz"

    info "正在下载版本: v$ver..."
    cd "$TMP_DIR"
    if ! wget -O ss.tar.xz "$url"; then
        error "下载失败，请检查网络或 GitHub API 限制。"
        return 1
    fi
    
    tar -xf ss.tar.xz
    install -m 755 ssserver "$BINARY_PATH"
    mkdir -p "$SS_DIR"
    echo "$ver" > "${SS_DIR}/version.txt"

    # 初始配置
    local port=$(random_port)
    local pass=$(openssl rand -base64 32 | tr -d '\n')
    
    # 写入初始 config.json
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
    "nameserver": ["1.1.1.1", "8.8.8.8"]
}
EOF
    chown -R "$RUN_USER":"$RUN_USER" "$SS_DIR"

    # 写入 OpenRC
    cat > "$SS_INIT_SCRIPT" <<EOF
#!/sbin/openrc-run
name="ss-rust"
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
    
    # 引导用户进行第一次修改（如果需要）
    modify_ss
}

# ================== 菜单 ==================
while true; do
    clear
    status=$(rc-service ss-rust status 2>/dev/null | grep -q "started" && echo -e "${GREEN}● 运行中${RESET}" || echo -e "${RED}● 未运行${RESET}")
    version=$( [ -f "${SS_DIR}/version.txt" ] && echo "v$(cat ${SS_DIR}/version.txt)" || echo "未安装")
    port=$( [ -f "$SS_CONFIG" ] && grep '"server_port"' "$SS_CONFIG" | grep -oE '[0-9]+' || echo "-")

    echo -e "${BLUE}================================${RESET}"
    echo -e "${BLUE}   SS-Rust 管理面板 (Alpine)    ${RESET}"
    echo -e "${BLUE}================================${RESET}"
    echo -e "状态   : $status"
    echo -e "版本   : ${YELLOW}${version}${RESET}"
    echo -e "端口   : ${YELLOW}${port}${RESET}"
    echo -e "${BLUE}================================${RESET}"
    echo -e "1. 安装 Shadowsocks-Rust"
    echo -e "2. 卸载 Shadowsocks-Rust"
    echo -e "3. 修改配置 (端口/密码)"
    echo -e "4. 启动 / 停止 / 重启"
    echo -e "5. 查看节点链接"
    echo -e "0. 退出"
    echo -e "${BLUE}================================${RESET}"

    read -rp "请输入选项: " choice
    case $choice in
        1) install_ss; pause ;;
        2) 
            rc-service ss-rust stop || true
            rc-update del ss-rust || true
            rm -f "$SS_INIT_SCRIPT" "$BINARY_PATH"
            rm -rf "$SS_DIR"
            info "已卸载。"; pause ;;
        3) modify_ss; pause ;;
        4) 
            echo -e "1.启动 2.停止 3.重启"
            read -rp "选择操作: " op
            [[ "$op" == "1" ]] && rc-service ss-rust start
            [[ "$op" == "2" ]] && rc-service ss-rust stop
            [[ "$op" == "3" ]] && rc-service ss-rust restart
            pause ;;
        5) 
            if [[ -f "${SS_DIR}/ss.txt" ]]; then
                info "节点链接:\n${YELLOW}$(cat "${SS_DIR}/ss.txt")${RESET}"
            else error "链接文件不存在。"; fi
            pause ;;
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done
