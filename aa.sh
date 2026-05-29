#!/bin/bash

# =========================================================
# Xray VLESS-Reality 管理脚本 (Alpine Linux 优化版)
# =========================================================

set -Eeuo pipefail

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ================== 基础变量 ==================
readonly XRAY_CONFIG="/etc/xray/config.json"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly LOG_PATH="/var/log/xray.log"
readonly PUBLIC_KEY_FILE="/etc/xray/public.key"

TMP_DIR=$(mktemp -d -t xray_alpine.XXXXXX)

# ================== 依赖与环境 ==================
cleanup() { [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

info() { echo -e "${GREEN}[信息] $*${RESET}"; }
error() { echo -e "${RED}[错误] $*${RESET}"; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

# 获取架构
get_arch() {
    local arch=$(uname -m)
    case ${arch} in
        x86_64) echo "64" ;;
        aarch64) echo "arm64-v8a" ;;
        *) error "不支持的架构: $arch"; exit 1 ;;
    esac
}

# ================== 状态检测 ==================
get_xray_status() {
    if rc-service xray status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}● 运行中${RESET}"
    else
        echo -e "${RED}● 未运行${RESET}"
    fi
}

get_xray_version() {
    [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version | head -n 1 | awk '{print $2}' || echo "未安装"
}

# ================== 核心配置逻辑 ==================
write_config() {
    local port="$1" uuid="$2" domain="$3" pri_key="$4" sid="$5"
    mkdir -p /etc/xray

    cat > "$XRAY_CONFIG" <<EOF
{
    "log": { "access": "${LOG_PATH}", "loglevel": "warning" },
    "inbounds": [
        {
            "port": ${port},
            "protocol": "vless",
            "settings": {
                "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "${domain}:443",
                    "serverNames": ["${domain}"],
                    "privateKey": "${pri_key}",
                    "shortIds": ["${sid}"],
                    "fingerprint": "chrome"
                }
            },
            "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
        }
    ],
    "outbounds": [
        { "protocol": "freedom", "tag": "direct" }
    ]
}
EOF
}

# ================== 功能函数 ==================
install_xray() {
    info "正在安装依赖 (含 libc6-compat)..."
    apk update && apk add curl unzip openssl ca-certificates uuidgen jq gcompat libc6-compat > /dev/null 2>&1

    local x_arch=$(get_arch)
    local ver=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
    [[ -z "$ver" ]] && ver="v1.8.4"

    info "下载 Xray $ver ($x_arch)..."
    curl -L -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${x_arch}.zip"
    unzip -o /tmp/xray.zip -d /tmp/xray_tmp
    mv -f /tmp/xray_tmp/xray "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    rm -rf /tmp/xray*

    # 初始化配置交互
    configure_xray
    
    # 注册 OpenRC 服务
    setup_service
}

setup_service() {
    cat << 'EOF' > /etc/init.d/xray
#!/sbin/openrc-run
description="Xray Reality Service"
command="/usr/local/bin/xray"
command_args="run -c /etc/xray/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
depend() { need net; }
EOF
    chmod +x /etc/init.d/xray
    rc-update add xray default
    rc-service xray restart
}

configure_xray() {
    read -p "请输入端口 (默认随机): " port
    [[ -z "$port" ]] && port=$((RANDOM % 45535 + 10000))
    
    read -p "请输入伪装域名 (默认: www.amazon.com): " domain
    [[ -z "$domain" ]] && domain="www.amazon.com"
    
    uuid=$(uuidgen)
    keys=$($XRAY_BIN x25519)
    pri_key=$(echo "$keys" | grep "Private" | awk '{print $NF}')
    pub_key=$(echo "$keys" | grep "Public" | awk '{print $NF}')
    sid=$(openssl rand -hex 4)

    echo "$pub_key" > "$PUBLIC_KEY_FILE"
    write_config "$port" "$uuid" "$domain" "$pri_key" "$sid"
    info "配置已生成！"
}

# ================== 菜单 ==================
show_menu() {
    clear
    echo -e "${BLUE}================================${RESET}"
    echo -e "${BLUE}   Xray Reality (Alpine 版)     ${RESET}"
    echo -e "${BLUE}================================${RESET}"
    echo -e "状态: $(get_xray_status)"
    echo -e "版本: $(get_xray_version)"
    echo -e "--------------------------------"
    echo " 1. 安装 Xray"
    echo " 2. 重启服务"
    echo " 3. 停止服务"
    echo " 4. 查看当前配置/链接"
    echo " 5. 卸载 Xray"
    echo " 0. 退出"
    echo -e "${BLUE}================================${RESET}"
}

main() {
    while true; do
        show_menu
        read -p "请选择: " opt
        case $opt in
            1) install_xray; pause ;;
            2) rc-service xray restart; pause ;;
            3) rc-service xray stop; pause ;;
            4) 
                if [[ -f "$XRAY_CONFIG" ]]; then
                    cat "$XRAY_CONFIG"
                    echo -e "\n${GREEN}PublicKey: $(cat "$PUBLIC_KEY_FILE" 2>/dev/null)${RESET}"
                else
                    error "配置文件不存在"
                fi
                pause ;;
            5) 
                rc-service xray stop
                rc-update del xray default
                rm -rf /etc/xray "$XRAY_BIN" /etc/init.d/xray
                info "卸载完成"; pause ;;
            0) exit 0 ;;
            *) error "无效选项"; sleep 1 ;;
        esac
    done
}

main "$@"
