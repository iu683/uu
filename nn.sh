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
CYAN="\033[36m"
RESET="\033[0m"

# ================== 基础变量 ==================
readonly XRAY_CONFIG="/etc/xray/config.json"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly PUBLIC_KEY_FILE="/etc/xray/public.key"
readonly SERVICE_NAME="xray"

TMP_DIR=$(mktemp -d -t xray_alpine.XXXXXX)

# ================== 基础工具 ==================
cleanup() { [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

# 获取公网IP
get_public_ip() {
    local ip
    ip=$(curl -4fsSL --max-time 5 https://api.ipify.org || curl -4fsSL --max-time 5 https://ifconfig.me || echo "未知")
    echo "$ip"
}

# 检查端口占用
check_port() {
    local port="$1"
    netstat -tuln | grep -q ":${port} " && return 1 || return 0
}

# ================== 系统状态 ==================
get_xray_status() {
    if rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}● 运行中${RESET}"
    else
        echo -e "${RED}● 未运行${RESET}"
    fi
}

get_xray_version() {
    [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version | head -n 1 | awk '{print $2}' || echo "未安装"
}

# ================== 核心功能 ==================
write_config() {
    local port="$1" uuid="$2" domain="$3" pri_key="$4" sid="$5"
    local outbound_proto="${6:-freedom}"
    
    mkdir -p /etc/xray
    
    # 基础配置模板
    cat > "$XRAY_CONFIG" <<EOF
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
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
    }],
    "outbounds": [
        $( [[ "$outbound_proto" == "freedom" ]] && echo '{"protocol": "freedom", "tag": "direct"}' || echo "$outbound_proto" )
    ]
}
EOF
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
}

# ================== 功能函数 ==================
install_xray() {
    info "正在安装依赖 (Alpine 专用)..."
    apk update && apk add curl unzip openssl ca-certificates uuidgen jq gcompat libc6-compat > /dev/null 2>&1

    local arch=$(uname -m)
    case ${arch} in
        x86_64) local x_arch="64" ;;
        aarch64) local x_arch="arm64-v8a" ;;
        *) error "不支持的架构: $arch"; return 1 ;;
    esac

    local ver=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
    info "下载 Xray $ver ($arch)..."
    curl -L -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${x_arch}.zip"
    unzip -o /tmp/xray.zip -d /tmp/xray_tmp
    mv -f /tmp/xray_tmp/xray "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    rm -rf /tmp/xray*

    configure_xray
    setup_service
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
    
    local ip=$(get_public_ip)
    cat > /root/xray_vless_reality.txt <<EOF
vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${pub_key}&sid=${sid}#Alpine-Reality
EOF
}

show_current_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "配置不存在"; return; fi
    
    local port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
    local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
    local pub_key=$(cat "$PUBLIC_KEY_FILE" 2>/dev/null)
    
    echo -e "${GREEN}====== 当前配置 ======${RESET}"
    echo -e "${YELLOW}端口: $port${RESET}"
    echo -e "${YELLOW}UUID: $uuid${RESET}"
    echo -e "${YELLOW}公钥: $pub_key${RESET}"
    echo -e "${GREEN}链接: ${RESET}"
    cat /root/xray_vless_reality.txt 2>/dev/null || echo "链接文件丢失"
}

# ================== SNI 优选 (简化逻辑) ==================
select_best_sni() {
    info "正在测试常用域名延迟..."
    local domains=("www.amazon.com" "www.apple.com" "www.microsoft.com" "www.cloudflare.com")
    local best_domain=""
    local min_lat=9999
    
    for d in "${domains[@]}"; do
        local lat=$(curl -o /dev/null -s -w "%{time_total}\n" "https://$d")
        echo -e "[SNI] $d -> ${lat}s"
        if (( $(echo "$lat < $min_lat" | bc -l) )); then
            min_lat=$lat; best_domain=$d
        fi
    done
    info "建议使用最优 SNI: $best_domain"
}

# ================== 菜单 ==================
show_menu() {
    clear
    local status=$(get_xray_status)
    local version=$(get_xray_version)
    local port="-"
    [[ -f "$XRAY_CONFIG" ]] && port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "-")

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   Xray Vless+Reality 管理面板   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 Xray Vless+Reality${RESET}"
    echo -e "${GREEN} 2. 更新 Xray 内核${RESET}"
    echo -e "${GREEN} 3. 卸载 Xray${RESET}"
    echo -e "${GREEN} 4. 重置/修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 Xray${RESET}"
    echo -e "${GREEN} 6. 停止 Xray${RESET}"
    echo -e "${GREEN} 7. 重启 Xray${RESET}"
    echo -e "${GREEN} 8. 查看系统日志${RESET}"
    echo -e "${GREEN} 9. 查看节点配置${RESET}"
    echo -e "${GREEN}10. 配置 Socks5 出口${RESET}"
    echo -e "${GREEN}11. SNI 域名优选✨${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# ================== 主循环 ==================
main() {
    while true; do
        show_menu
        read -rp "$(echo -e "${GREEN}请输入选项: ${RESET}")" choice
        case "$choice" in
            1) install_xray; pause ;;
            2) install_xray; pause ;; # Alpine 重新运行安装即更新
            3) 
                rc-service xray stop 2>/dev/null
                rc-update del xray default 2>/dev/null
                rm -rf /etc/xray "$XRAY_BIN" /etc/init.d/xray /root/xray_vless_reality.txt
                info "卸载完成"; pause ;;
            4) configure_xray; rc-service xray restart; pause ;;
            5) rc-service xray start; pause ;;
            6) rc-service xray stop; pause ;;
            7) rc-service xray restart; pause ;;
            8) tail -n 50 /var/log/messages | grep xray; pause ;; # Alpine 日志路径
            9) show_current_config; pause ;;
            11) select_best_sni; pause ;;
            0) exit 0 ;;
            *) error "无效选项"; sleep 1 ;;
        esac
    done
}

main "$@"
