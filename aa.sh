#!/bin/bash

# =========================================================
# Xray VLESS-Reality 管理脚本
# =========================================================

set -euo pipefail

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
RESET="\033[0m"

# ================== 基础变量 ==================
SCRIPT_VERSION="6.0"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BINARY="/usr/local/bin/xray"

INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"

TMP_DIR=$(mktemp -d -t xray.XXXXXX)

# ================== cleanup ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

# ================== 日志 ==================
pause() {
    read -n 1 -s -r -p "按任意键返回菜单..."
    echo
}

# ================== 获取公网IP ==================
get_public_ip() {

    local ip

    for cmd in \
        "curl -4fsSL --max-time 5" \
        "wget -4qO- --timeout=5"; do

        for url in \
            "https://api.ipify.org" \
            "https://ip.sb" \
            "https://checkip.amazonaws.com"; do

            ip=$($cmd "$url" 2>/dev/null) && \
            [[ -n "$ip" ]] && \
            echo "$ip" && return
        done
    done

    for cmd in \
        "curl -6fsSL --max-time 5" \
        "wget -6qO- --timeout=5"; do

        for url in \
            "https://api64.ipify.org" \
            "https://ipv6.ip.sb"; do

            ip=$($cmd "$url" 2>/dev/null) && \
            [[ -n "$ip" ]] && \
            echo "$ip" && return
        done
    done

    echo "无法获取公网IP"
}

# ================== 检查端口 ==================
check_port() {

    if ss -tulnH "( sport = :$1 )" | grep -q .; then
        echo -e "${RED}端口 $1 已被占用${RESET}"
        return 1
    fi
}

# ================== 验证端口 ==================
is_valid_port() {

    [[ "$1" =~ ^[0-9]+$ ]] \
        && [[ "$1" -ge 1 ]] \
        && [[ "$1" -le 65535 ]]
}

# ================== UUID验证 ==================
is_valid_uuid() {

    [[ "$1" =~ ^[0-9a-fA-F-]{36}$ ]]
}

# ================== 域名验证 ==================
is_valid_domain() {

    [[ "$1" =~ ^[a-zA-Z0-9.-]+$ ]]
}

# ================== 获取Xray状态 ==================
get_xray_status() {

    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}● 运行中${RESET}"
    else
        echo -e "${RED}● 未运行${RESET}"
    fi
}

# ================== 获取版本 ==================
get_xray_version() {

    if [[ -f "$XRAY_BINARY" ]]; then
        $XRAY_BINARY version 2>/dev/null \
            | head -n 1 \
            | awk '{print $2}'
    else
        echo "未安装"
    fi
}

# ================== 写配置 ==================
write_config() {

    local port="$1"
    local uuid="$2"
    local domain="$3"
    local private_key="$4"
    local public_key="$5"
    local shortid="$6"

    mkdir -p /usr/local/etc/xray

    cat > "$XRAY_CONFIG" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "::",
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$uuid",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${domain}:443",
                    "xver": 0,
                    "serverNames": [
                        "$domain"
                    ],
                    "privateKey": "$private_key",
                    "publicKey": "$public_key",
                    "shortIds": [
                        "$shortid"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv4v6"
            }
        }
    ]
}
EOF
}

# ================== 生成订阅 ==================
generate_link() {

    local ip
    ip=$(get_public_ip)

    local uuid
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")

    local port
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")

    local domain
    domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")

    local public_key
    public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$XRAY_CONFIG")

    local shortid
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")

    local display_ip="$ip"

    [[ "$ip" =~ ":" ]] && display_ip="[$ip]"

    local hostname
    hostname=$(hostname -s | sed 's/ /_/g')

    cat > /root/xray_vless_reality.txt <<EOF
vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#${hostname}-Reality
EOF
}

# ================== 安装配置 ==================
configure_xray() {

    echo -e "${GREEN}[信息]开始配置 Xray Reality...${RESET}"

    # ===== 端口 =====
    while true; do

        read -p "请输入端口 (默认:443): " input_port

        port=${input_port:-443}

        if is_valid_port "$port"; then

            check_port "$port" || continue

            break

        else
            echo -e "${RED}端口无效${RESET}"
        fi
    done

    # ===== UUID =====
    while true; do

        read -p "请输入UUID (默认:自动生成): " input_uuid

        if [[ -z "$input_uuid" ]]; then

            uuid=$(cat /proc/sys/kernel/random/uuid)

            break

        elif is_valid_uuid "$input_uuid"; then

            uuid="$input_uuid"

            break

        else
            echo -e "${RED}UUID格式无效${RESET}"
        fi
    done

    # ===== 域名 =====
    while true; do

        read -p "请输入SNI域名 (默认:www.amazon.com): " input_domain

        domain=${input_domain:-www.amazon.com}

        if is_valid_domain "$domain"; then
            break
        else
            echo -e "${RED}域名格式无效${RESET}"
        fi
    done

    echo -e "${GREEN}[信息]生成 Reality 密钥...${RESET}"

    KEY_PAIR=$($XRAY_BINARY x25519)

    PRIVATE_KEY=$(echo "$KEY_PAIR" \
        | grep PrivateKey \
        | awk '{print $3}')

    PUBLIC_KEY=$(echo "$KEY_PAIR" \
        | grep PublicKey \
        | awk '{print $3}')

    SHORT_ID=$(openssl rand -hex 8)

    write_config \
        "$port" \
        "$uuid" \
        "$domain" \
        "$PRIVATE_KEY" \
        "$PUBLIC_KEY" \
        "$SHORT_ID"

    generate_link

    systemctl restart xray

    IP=$(get_public_ip)

    echo -e "${GREEN}[完成] 配置已保存${RESET}"

    echo -e "${GREEN}====== Xray Reality 配置 ======${RESET}"

    echo -e "${YELLOW} IP地址        : ${IP}${RESET}"

    echo -e "${YELLOW} 端口          : ${port}${RESET}"

    echo -e "${YELLOW} UUID          : ${uuid}${RESET}"

    echo -e "${YELLOW} SNI           : ${domain}${RESET}"

    echo -e "${YELLOW} PublicKey     : ${PUBLIC_KEY}${RESET}"

    echo -e "${YELLOW} ShortID       : ${SHORT_ID}${RESET}"

    echo -e "${YELLOW}---------------------------------${RESET}"

    echo -e "${YELLOW}📄 V6VPS 替换IP地址为V6 ★${RESET}"

    echo -e "${YELLOW}[信息] VLESS链接：${RESET}"

    cat /root/xray_vless_reality.txt

    echo -e "${YELLOW}---------------------------------${RESET}"
}

# ================== 安装 ==================
install_xray() {

    echo -e "${GREEN}[信息] 开始安装 Xray...${RESET}"

    bash <(curl -Ls "$INSTALL_SCRIPT_URL") install

    bash <(curl -Ls "$INSTALL_SCRIPT_URL") install-geodata

    configure_xray

    systemctl enable xray

    systemctl restart xray

    echo -e "${GREEN}[完成] Xray 已安装并启动${RESET}"
}

# ================== 更新 ==================
update_xray() {

    echo -e "${GREEN}[信息] 更新 Xray...${RESET}"

    bash <(curl -Ls "$INSTALL_SCRIPT_URL") install

    bash <(curl -Ls "$INSTALL_SCRIPT_URL") install-geodata

    systemctl restart xray

    echo -e "${GREEN}[完成] Xray 已更新${RESET}"
}

# ================== 修改配置 ==================
modify_config() {

    if [[ ! -f "$XRAY_CONFIG" ]]; then

        echo -e "${RED}配置文件不存在${RESET}"

        return
    fi

    old_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")

    old_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")

    old_domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")

    private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG")

    public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$XRAY_CONFIG")

    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")

    echo -e "${GREEN}[信息]开始修改配置...${RESET}"

    echo -e "${YELLOW}当前端口 : ${old_port}${RESET}"

    echo -e "${YELLOW}当前UUID : ${old_uuid}${RESET}"

    echo -e "${YELLOW}当前SNI  : ${old_domain}${RESET}"

    echo

    # ===== 端口 =====
    while true; do

        read -p "请输入新端口 [当前:${old_port}]: " input_port

        port=${input_port:-$old_port}

        if is_valid_port "$port"; then

            if [[ "$port" != "$old_port" ]]; then
                check_port "$port" || continue
            fi

            break

        else
            echo -e "${RED}端口无效${RESET}"
        fi
    done

    # ===== UUID =====
    while true; do

        read -p "请输入UUID [当前:${old_uuid}]: " input_uuid

        uuid=${input_uuid:-$old_uuid}

        if is_valid_uuid "$uuid"; then
            break
        else
            echo -e "${RED}UUID格式无效${RESET}"
        fi
    done

    # ===== 域名 =====
    while true; do

        read -p "请输入SNI域名 [当前:${old_domain}]: " input_domain

        domain=${input_domain:-$old_domain}

        if is_valid_domain "$domain"; then
            break
        else
            echo -e "${RED}域名格式无效${RESET}"
        fi
    done

    cp "$XRAY_CONFIG" \
        "${XRAY_CONFIG}.bak.$(date +%s)"

    write_config \
        "$port" \
        "$uuid" \
        "$domain" \
        "$private_key" \
        "$public_key" \
        "$shortid"

    generate_link

    systemctl restart xray

    echo -e "${GREEN}[完成] 配置修改成功${RESET}"
}

# ================== 卸载 ==================
uninstall_xray() {

    echo -e "${RED}[警告] 卸载 Xray...${RESET}"

    systemctl stop xray || true

    bash <(curl -Ls "$INSTALL_SCRIPT_URL") remove --purge

    rm -f /root/xray_vless_reality.txt

    echo -e "${GREEN}[完成] Xray 已卸载${RESET}"
}

# ================== 菜单 ==================
show_menu() {

    clear

    STATUS=$(get_xray_status)

    VERSION=$(get_xray_version)

    PORT_SHOW="-"

    if [[ -f "$XRAY_CONFIG" ]]; then
        PORT_SHOW=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
    fi

    echo -e "${GREEN}================================${RESET}"

    echo -e "${GREEN}      Xray Reality 管理面板      ${RESET}"

    echo -e "${GREEN}================================${RESET}"

    echo -e "状态   : $STATUS"

    echo -e "版本   : ${YELLOW}${VERSION}${RESET}"

    echo -e "端口   : ${YELLOW}${PORT_SHOW}${RESET}"

    echo -e "${GREEN}================================${RESET}"

    echo -e "${GREEN}1. 安装 Xray Reality${RESET}"

    echo -e "${GREEN}2. 更新 Xray${RESET}"

    echo -e "${GREEN}3. 卸载 Xray${RESET}"

    echo -e "${GREEN}4. 修改配置${RESET}"

    echo -e "${GREEN}5. 启动 Xray${RESET}"

    echo -e "${GREEN}6. 停止 Xray${RESET}"

    echo -e "${GREEN}7. 重启 Xray${RESET}"

    echo -e "${GREEN}8. 查看日志${RESET}"

    echo -e "${GREEN}9. 查看当前配置${RESET}"

    echo -e "${GREEN}0. 退出${RESET}"

    echo -e "${GREEN}================================${RESET}"
}

# ================== 依赖检查 ==================
pre_check() {

    if [[ $(id -u) -ne 0 ]]; then

        echo -e "${RED}请使用 root 用户运行${RESET}"

        exit 1
    fi

    if ! command -v jq &>/dev/null; then

        apt update

        apt install -y jq curl wget openssl
    fi
}

# ================== 主循环 ==================
main() {

    pre_check

    while true; do

        show_menu

        read -r -p $'\033[32m请输入选项: \033[0m' choice

        case $choice in

            1)
                install_xray
                pause
                ;;

            2)
                update_xray
                pause
                ;;

            3)
                uninstall_xray
                pause
                ;;

            4)
                modify_config
                pause
                ;;

            5)
                systemctl start xray
                echo -e "${GREEN}[完成] Xray 已启动${RESET}"
                pause
                ;;

            6)
                systemctl stop xray
                echo -e "${GREEN}[完成] Xray 已停止${RESET}"
                pause
                ;;

            7)
                systemctl restart xray
                echo -e "${GREEN}[完成] Xray 已重启${RESET}"
                pause
                ;;

            8)
                journalctl -u xray -e --no-pager
                pause
                ;;

            9)

                if [[ -f "$XRAY_CONFIG" ]]; then

                    echo -e "${GREEN}====== 当前配置 ======${RESET}"

                    cat "$XRAY_CONFIG"

                    echo

                    echo -e "${GREEN}====== VLESS链接 ======${RESET}"

                    cat /root/xray_vless_reality.txt

                else

                    echo -e "${RED}配置文件不存在${RESET}"

                fi

                pause
                ;;

            0)
                exit 0
                ;;

            *)
                echo -e "${RED}无效输入${RESET}"
                pause
                ;;
        esac
    done
}

main "$@"
