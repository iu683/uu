#!/bin/bash

# =========================================================
# Shadowsocks-Rust 管理脚本 (Alpine Linux 专属解耦版)
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

get_public_ip() {
    curl -4fsSL --max-time 5 https://api.ipify.org || echo "YOUR_IP"
}

# ================== 功能函数：修改配置 ==================
modify_ss() {
    if [[ ! -f "$SS_CONFIG" ]]; then
        error "配置文件不存在，请先安装"
        return 1
    fi

    # 精准提取旧配置
    local old_port=$(grep -E '"server_port":' "$SS_CONFIG" | head -n 1 | grep -oE '[0-9]+')
    local old_pass=$(grep -E '"password":' "$SS_CONFIG" | head -n 1 | cut -d '"' -f4)
    
    echo -e "${YELLOW}--- 修改 Shadowsocks 配置 (回车保持默认) ---${RESET}"
    
    read -rp "$(echo -e ${GREEN}"设置新端口 [当前: $old_port]: "${RESET})" new_port
    new_port=${new_port:-$old_port}

    read -rp "$(echo -e ${GREEN}"设置新密码 [当前: $old_pass]: "${RESET})" new_pass
    new_pass=${new_pass:-$old_pass}

    # 写入配置
    cat > "$SS_CONFIG" <<EOF
{
    "server": "::",
    "server_port": $new_port,
    "password": "$new_pass",
    "method": "$METHOD",
    "fast_open": true,
    "mode": "tcp_and_udp",
    "timeout": 300,
    "no_delay": true,
    "ipv6_first": false,
    "nameserver": ["1.1.1.1", "8.8.8.8"]
}
EOF
    chown "${RUN_USER}:${RUN_GROUP}" "$SS_CONFIG"
    
    # 异步生成节点链接文件
    local ip=$(get_public_ip)
    [[ "$ip" =~ : ]] && ip="[$ip]"
    local encoded=$(echo -n "${METHOD}:${new_pass}" | base64 | tr -d '\n')
    echo "ss://${encoded}@${ip}:${new_port}#$(hostname)-SS2022" > "${SS_DIR}/ss.txt"

    rc-service ss-rust restart >/dev/null 2>&1 || true
    info "配置已更新！"
}

# ================== 功能函数：安装 ==================
install_ss() {
    info "正在安装系统依赖..."
    apk add curl wget tar xz openssl iproute2 coreutils >/dev/null 2>&1
    
    # 用户环境准备
    getent group "$RUN_GROUP" >/dev/null || addgroup -S "$RUN_GROUP"
    getent passwd "$RUN_USER" >/dev/null || adduser -S -D -H -G "$RUN_GROUP" -s /sbin/nologin "$RUN_USER"

    local ver=$(get_latest_version)
    local arch=$(detect_arch)
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${ver}/shadowsocks-v${ver}.${arch}.tar.xz"

    info "正在下载 Shadowsocks-Rust v$ver..."
    cd "$TMP_DIR"
    wget -q --show-progress -O ss.tar.xz "$url"
    tar -xf ss.tar.xz
    install -m 755 ssserver "$BINARY_PATH"
    
    # 建立目录与基础文件
    mkdir -p "$SS_DIR"
    echo "$ver" > "${SS_DIR}/version.txt"
    touch "$LOG_FILE"
    chown "${RUN_USER}:${RUN_GROUP}" "$LOG_FILE"

    # 生成初始随机配置 (仅安装，不修改)
    local init_port=$((RANDOM % 40000 + 20000))
    local init_pass=$(openssl rand -base64 32 | tr -d '\n')
    
    cat > "$SS_CONFIG" <<EOF
{
    "server": "::",
    "server_port": $init_port,
    "password": "$init_pass",
    "method": "$METHOD"
}
EOF
    chown -R "${RUN_USER}:${RUN_GROUP}" "$SS_DIR"

    # 写入 OpenRC 服务脚本
    cat > "$SS_INIT_SCRIPT" <<EOF
#!/sbin/openrc-run
name="ss-rust"
description="Shadowsocks-Rust Server"
command="${BINARY_PATH}"
command_args="-c ${SS_CONFIG}"
command_user="${RUN_USER}:${RUN_GROUP}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

depend() {
    need net
}
EOF
    chmod +x "$SS_INIT_SCRIPT"
    rc-update add ss-rust default
    
    rc-service ss-rust start
    info "安装完成并已启动服务！"
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
            info "卸载完成"; pause ;;
        4) modify_ss; pause ;;
        5) rc-service ss-rust start; pause ;;
        6) rc-service ss-rust stop; pause ;;
        7) rc-service ss-rust restart; pause ;;
        8) 
            info "正在实时查看日志 (Ctrl+C 退出)..."
            [[ -f "$LOG_FILE" ]] && tail -f "$LOG_FILE" || error "日志文件不存在"; pause ;;
        9) 
            if [[ -f "${SS_DIR}/ss.txt" ]]; then
                info "节点链接:\n${YELLOW}$(cat "${SS_DIR}/ss.txt")${RESET}"
            else
                error "配置链接尚未生成，请执行一次修改或重启。"
            fi
            pause ;;
        0) exit 0 ;;
        *) sleep 0.5 ;;
    esac
done
