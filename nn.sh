#!/bin/bash

# =========================================================
# Shadowsocks-Rust 管理脚本 (Alpine Linux 完美修复版)
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

# ================== 独立配置修改函数 ==================
modify_ss() {
    if [[ ! -f "$SS_CONFIG" ]]; then
        error "未发现配置文件，请先安装。"
        return 1
    fi

    local old_port=$(grep '"server_port"' "$SS_CONFIG" | grep -oE '[0-9]+')
    local old_pass=$(grep '"password"' "$SS_CONFIG" | cut -d '"' -f4)
    
    echo -e "${YELLOW}--- 修改 Shadowsocks 配置 (回车保持当前默认值) ---${RESET}"
    
    read -rp "$(echo -e ${GREEN}"请输入服务端口 [当前: $old_port]: "${RESET})" new_port
    new_port=${new_port:-$old_port}

    read -rp "$(echo -e ${GREEN}"请输入连接密码 [当前: $old_pass]: "${RESET})" new_pass
    new_pass=${new_pass:-$old_pass}

    # 更新配置文件
    local tmp_conf=$(mktemp)
    cat > "$tmp_conf" <<EOF
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
    mv "$tmp_conf" "$SS_CONFIG"
    
    # 🛠 修复点：确保用户和组存在后再 chown
    chown "${RUN_USER}:${RUN_GROUP}" "$SS_CONFIG"
    chmod 600 "$SS_CONFIG"

    # 生成链接
    local ip=$(get_public_ip)
    local encoded=$(echo -n "${METHOD}:${new_pass}" | base64 | tr -d '\n')
    echo "ss://${encoded}@${ip}:${new_port}#$(hostname)-SS2022" > "${SS_DIR}/ss.txt"

    rc-service ss-rust restart
    info "配置修改成功，服务已重启！"
}

# ================== 安装逻辑 ==================
install_ss() {
    info "准备环境与依赖..."
    apk add curl wget tar xz openssl iproute2 coreutils >/dev/null 2>&1
    
    # 🛠 修复点：严谨的组和用户创建逻辑
    if ! getent group "$RUN_GROUP" >/dev/null; then
        addgroup -S "$RUN_GROUP"
    fi
    if ! getent passwd "$RUN_USER" >/dev/null; then
        adduser -S -D -H -G "$RUN_GROUP" -s /sbin/nologin "$RUN_USER"
    fi

    local ver=$(get_latest_version)
    local arch=$(detect_arch)
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${ver}/shadowsocks-v${ver}.${arch}.tar.xz"

    info "正在下载版本: v$ver"
    cd "$TMP_DIR"
    wget -q --show-progress -O ss.tar.xz "$url"
    
    tar -xf ss.tar.xz
    install -m 755 ssserver "$BINARY_PATH"
    
    mkdir -p "$SS_DIR"
    echo "$ver" > "${SS_DIR}/version.txt"

    # 初始日志文件处理
    touch "$LOG_FILE"
    chown "${RUN_USER}:${RUN_GROUP}" "$LOG_FILE"

    # 随机初始值
    local init_port=$((RANDOM % 40000 + 20000))
    local init_pass=$(openssl rand -base64 32 | tr -d '\n')
    
    # 写入初始配置用于 modify_ss 读取
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
command="${BINARY_PATH}"
command_args="-c ${SS_CONFIG}"
command_user="${RUN_USER}:${RUN_GROUP}"
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
    
    # 引导修改配置
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
    echo -e "5. 查看节点配置 (SS链接)"
    echo -e "0. 退出"
    echo -e "${BLUE}================================${RESET}"

    read -rp "请输入选项: " choice
    case $choice in
        1) install_ss; pause ;;
        2) 
            rc-service ss-rust stop || true
            rc-update del ss-rust || true
            rm -f "$SS_INIT_SCRIPT" "$BINARY_PATH"
            rm -rf "$SS_DIR" "$LOG_FILE"
            info "已彻底卸载。"; pause ;;
        3) modify_ss; pause ;;
        4) 
            echo -e "1. 启动  2. 停止  3. 重启"
            read -rp "请选择: " op
            [[ "$op" == "1" ]] && rc-service ss-rust start
            [[ "$op" == "2" ]] && rc-service ss-rust stop
            [[ "$op" == "3" ]] && rc-service ss-rust restart
            pause ;;
        5) 
            if [[ -f "${SS_DIR}/ss.txt" ]]; then
                info "节点链接:\n${YELLOW}$(cat "${SS_DIR}/ss.txt")${RESET}"
            else error "链接未生成。"; fi
            pause ;;
        0) exit 0 ;;
        *) sleep 0.5 ;;
    esac
done
