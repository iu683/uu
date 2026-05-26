#!/bin/bash

# ==============================================================================
# Xray VLESS-Reality 一键安装管理脚本
# Final Optimized Edition
# ==============================================================================

set -Eeuo pipefail

# ================== 全局常量 ==================

readonly SCRIPT_VERSION="Final-3.0"

readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_BINARY="/usr/local/bin/xray"

readonly XRAY_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"

# ================== 颜色 ==================

readonly RED='\033[31m'
readonly GREEN='\033[32m'
readonly YELLOW='\033[33m'
readonly BLUE='\033[34m'
readonly CYAN='\033[36m'
readonly RESET='\033[0m'

# ================== 全局变量 ==================

IS_QUIET=false

# ================== 日志 ==================

info() {

    [[ "$IS_QUIET" == true ]] && return

    echo -e "${GREEN}[信息] $*${RESET}"
}

warn() {

    echo -e "${YELLOW}[警告] $*${RESET}" >&2
}

error() {

    echo -e "${RED}[错误] $*${RESET}" >&2
}

success() {

    [[ "$IS_QUIET" == true ]] && return

    echo -e "${CYAN}[成功] $*${RESET}"
}

pause() {

    echo

    read -n 1 -s -r -p "按任意键返回菜单..."

    echo
}

# ================== Spinner ==================

spinner() {

    local pid="$1"

    local spin='-\|/'

    local i=0

    while kill -0 "$pid" 2>/dev/null; do

        i=$(( (i+1) %4 ))

        printf "\r${CYAN}[%c] 请稍候...${RESET}" "${spin:$i:1}"

        sleep 0.1
    done

    printf "\r                    \r"
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

            ip=$($cmd "$url" 2>/dev/null || true)

            if [[ -n "${ip:-}" ]]; then

                echo "$ip"

                return 0
            fi
        done
    done

    for cmd in \
        "curl -6fsSL --max-time 5" \
        "wget -6qO- --timeout=5"; do

        for url in \
            "https://api64.ipify.org" \
            "https://ipv6.ip.sb"; do

            ip=$($cmd "$url" 2>/dev/null || true)

            if [[ -n "${ip:-}" ]]; then

                echo "$ip"

                return 0
            fi
        done
    done

    return 1
}

# ================== 检查端口占用 ==================

is_port_in_use() {

    local port="$1"

    if command -v ss >/dev/null 2>&1; then

        ss -tuln | awk '{print $5}' | grep -qE "[:.]${port}$"

        return
    fi

    if command -v netstat >/dev/null 2>&1; then

        netstat -tuln | awk '{print $4}' | grep -qE "[:.]${port}$"

        return
    fi

    return 1
}

# ================== 验证端口 ==================

is_valid_port() {

    [[ "$1" =~ ^[0-9]+$ ]] \
        && [[ "$1" -ge 1 ]] \
        && [[ "$1" -le 65535 ]]
}

# ================== UUID验证 ==================

is_valid_uuid() {

    local uuid="$1"

    [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# ================== 域名验证 ==================

is_valid_domain() {

    local domain="$1"

    [[ "$domain" =~ ^([a-zA-Z0-9](-?[a-zA-Z0-9])*\.)+[A-Za-z]{2,}$ ]]
}

# ================== 获取监听地址 ==================

get_listen_ip() {

    if sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null \
        | grep -q '= 1'; then

        echo "0.0.0.0"

    else

        echo "::"
    fi
}

# ================== 安装依赖 ==================

install_dependencies() {

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y \
        curl \
        wget \
        jq \
        openssl \
        ca-certificates \
        iproute2 \
        gawk \
        coreutils
}

# ================== 预检查 ==================

pre_check() {

    if [[ $(id -u) -ne 0 ]]; then

        error "请使用 root 用户运行"

        exit 1
    fi

    local deps=(
        curl
        wget
        jq
        openssl
        timeout
    )

    local missing=0

    for cmd in "${deps[@]}"; do

        if ! command -v "$cmd" >/dev/null 2>&1; then

            missing=1

            break
        fi
    done

    if [[ "$missing" -eq 1 ]]; then

        info "安装依赖中..."

        install_dependencies
    fi
}

# ================== 执行官方安装脚本 ==================

execute_official_script() {

    local args="$1"

    bash <(curl -fsSL "$XRAY_INSTALL_SCRIPT_URL") $args \
        >/dev/null 2>&1 &

    local pid=$!

    spinner "$pid"

    wait "$pid"
}

# ================== 获取Xray状态 ==================

get_xray_status() {

    if systemctl is-active --quiet xray; then

        echo -e "${GREEN}运行中${RESET}"

    else

        echo -e "${RED}未运行${RESET}"
    fi
}

# ================== 获取版本 ==================

get_xray_version() {

    if [[ -x "$XRAY_BINARY" ]]; then

        "$XRAY_BINARY" version 2>/dev/null \
            | head -n 1 \
            | awk '{print $2}'

    else

        echo "未安装"
    fi
}

# ================== 测试配置 ==================

test_config() {

    if "$XRAY_BINARY" run -test -config "$XRAY_CONFIG"; then

        return 0
    fi

    error "配置测试失败"

    return 1
}

# ================== 重启服务 ==================

restart_xray() {

    info "重启 Xray 服务..."

    systemctl restart xray

    sleep 1

    if systemctl is-active --quiet xray; then

        success "Xray 启动成功"

        return 0
    fi

    error "Xray 启动失败"

    journalctl -u xray -n 20 --no-pager

    return 1
}

# ================== Reality 密钥 ==================

generate_reality_keys() {

    info "生成 Reality 密钥..."

    local key_pair

    key_pair=$("$XRAY_BINARY" x25519 2>/dev/null)

    local private_key

    private_key=$(echo "$key_pair" \
        | grep -i "Private" \
        | awk -F ': ' '{print $2}')

    local public_key

    public_key=$(echo "$key_pair" \
        | grep -i "Public" \
        | awk -F ': ' '{print $2}')

    if [[ -z "${private_key:-}" ]]; then

        error "PrivateKey 生成失败"

        return 1
    fi

    if [[ -z "${public_key:-}" ]]; then

        error "PublicKey 生成失败"

        return 1
    fi

    echo "${private_key}|${public_key}"
}

# ================== 写配置 ==================

write_config() {

    local port="$1"
    local uuid="$2"
    local domain="$3"
    local private_key="$4"
    local public_key="$5"
    local shortid="$6"

    local listen_ip

    listen_ip=$(get_listen_ip)

    mkdir -p /usr/local/etc/xray

    cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "${listen_ip}",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",

        "sockopt": {
          "tcpFastOpen": true,
          "tcpNoDelay": true
        },

        "realitySettings": {
          "show": false,
          "dest": "${domain}:443",
          "xver": 0,

          "serverNames": [
            "${domain}"
          ],

          "privateKey": "${private_key}",
          "publicKey": "${public_key}",

          "shortIds": [
            "${shortid}"
          ],

          "spiderX": "/"
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

generate_subscription() {

    local ip

    if ! ip=$(get_public_ip); then

        error "获取公网IP失败"

        return 1
    fi

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
    hostname=$(hostname -s | tr ' ' '_')

    local link

    link="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}&spx=%2F#${hostname}-Reality"

    echo "$link" > /root/xray_vless_reality.txt

    echo

    echo -e "${GREEN}==============================${RESET}"

    echo -e "${CYAN}VLESS Reality 节点信息${RESET}"

    echo -e "${GREEN}==============================${RESET}"

    echo -e "IP地址     : ${YELLOW}${ip}${RESET}"

    echo -e "端口       : ${YELLOW}${port}${RESET}"

    echo -e "UUID       : ${YELLOW}${uuid}${RESET}"

    echo -e "SNI        : ${YELLOW}${domain}${RESET}"

    echo -e "PublicKey  : ${YELLOW}${public_key}${RESET}"

    echo -e "ShortID    : ${YELLOW}${shortid}${RESET}"

    echo

    echo -e "${CYAN}${link}${RESET}"

    echo

    success "订阅已保存到 /root/xray_vless_reality.txt"
}

# ================== 安装Xray ==================

install_xray() {

    info "开始安装 Xray..."

    if ! execute_official_script "install"; then

        error "Xray 安装失败"

        return 1
    fi

    timeout 300 bash <(curl -fsSL "$XRAY_INSTALL_SCRIPT_URL") install-geodata \
        >/dev/null 2>&1 || true

    configure_xray
}

# ================== 更新Xray ==================

update_xray() {

    info "更新 Xray..."

    execute_official_script "install"

    timeout 300 bash <(curl -fsSL "$XRAY_INSTALL_SCRIPT_URL") install-geodata \
        >/dev/null 2>&1 || true

    restart_xray
}

# ================== 配置Xray ==================

configure_xray() {

    local port
    local uuid
    local domain

    while true; do

        read -rp "请输入端口 (默认:443): " input_port

        port=${input_port:-443}

        if ! is_valid_port "$port"; then

            error "端口无效"

            continue
        fi

        if is_port_in_use "$port"; then

            error "端口已被占用"

            continue
        fi

        break
    done

    while true; do

        read -rp "请输入UUID (默认自动生成): " input_uuid

        if [[ -z "${input_uuid:-}" ]]; then

            uuid=$(cat /proc/sys/kernel/random/uuid)

            break

        fi

        if is_valid_uuid "$input_uuid"; then

            uuid="$input_uuid"

            break
        fi

        error "UUID 格式错误"
    done

    while true; do

        read -rp "请输入SNI域名 (默认:www.amazon.com): " input_domain

        domain=${input_domain:-www.amazon.com}

        if is_valid_domain "$domain"; then

            break
        fi

        error "域名格式错误"
    done

    local keys

    keys=$(generate_reality_keys)

    local private_key
    private_key=$(echo "$keys" | cut -d '|' -f1)

    local public_key
    public_key=$(echo "$keys" | cut -d '|' -f2)

    local shortid

    shortid=$(openssl rand -hex 8)

    write_config \
        "$port" \
        "$uuid" \
        "$domain" \
        "$private_key" \
        "$public_key" \
        "$shortid"

    test_config || return 1

    restart_xray || return 1

    generate_subscription
}

# ================== 修改配置 ==================

modify_config() {

    if [[ ! -f "$XRAY_CONFIG" ]]; then

        error "配置文件不存在"

        return 1
    fi

    local old_port
    old_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")

    local old_uuid
    old_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")

    local old_domain
    old_domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")

    local private_key
    private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG")

    local public_key
    public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$XRAY_CONFIG")

    local shortid
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")

    local port
    local uuid
    local domain

    while true; do

        read -rp "请输入新端口 [当前:${old_port}]: " input_port

        port=${input_port:-$old_port}

        if ! is_valid_port "$port"; then

            error "端口无效"

            continue
        fi

        if [[ "$port" != "$old_port" ]] \
            && is_port_in_use "$port"; then

            error "端口已占用"

            continue
        fi

        break
    done

    while true; do

        read -rp "请输入UUID [当前:${old_uuid}]: " input_uuid

        uuid=${input_uuid:-$old_uuid}

        if is_valid_uuid "$uuid"; then

            break
        fi

        error "UUID 格式错误"
    done

    while true; do

        read -rp "请输入SNI域名 [当前:${old_domain}]: " input_domain

        domain=${input_domain:-$old_domain}

        if is_valid_domain "$domain"; then

            break
        fi

        error "域名格式错误"
    done

    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"

    write_config \
        "$port" \
        "$uuid" \
        "$domain" \
        "$private_key" \
        "$public_key" \
        "$shortid"

    test_config || return 1

    restart_xray || return 1

    generate_subscription

    success "配置修改成功"
}

# ================== 卸载 ==================

uninstall_xray() {

    warn "即将卸载 Xray"

    read -rp "确认卸载？[y/N]: " confirm

    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    execute_official_script "remove --purge"

    rm -f /root/xray_vless_reality.txt

    success "Xray 已卸载"
}

# ================== 显示配置 ==================

show_current_config() {

    if [[ ! -f "$XRAY_CONFIG" ]]; then

        error "配置文件不存在"

        return
    fi

    generate_subscription
}

# ================== 菜单 ==================

show_menu() {

    clear

    local status
    status=$(get_xray_status)

    local version
    version=$(get_xray_version)

    echo -e "${GREEN}=====================================${RESET}"
    echo -e "${GREEN}      Xray Reality 管理面板${RESET}"
    echo -e "${GREEN}=====================================${RESET}"
    echo -e "状态   : ${status}"
    echo -e "版本   : ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}=====================================${RESET}"
    echo -e "${GREEN}1.${RESET} 安装 Xray Reality"
    echo -e "${GREEN}2.${RESET} 更新 Xray"
    echo -e "${GREEN}3.${RESET} 修改配置"
    echo -e "${GREEN}4.${RESET} 查看当前配置"
    echo -e "${GREEN}5.${RESET} 重启 Xray"
    echo -e "${GREEN}6.${RESET} 停止 Xray"
    echo -e "${GREEN}7.${RESET} 查看日志"
    echo -e "${GREEN}8.${RESET} 卸载 Xray"
    echo -e "${GREEN}0.${RESET} 退出"
    echo -e "${GREEN}=====================================${RESET}"
}

# ================== 主循环 ==================

main() {

    pre_check

    while true; do

        show_menu

        read -rp "请输入选项: " choice

        case "$choice" in

            1)
                install_xray
                pause
                ;;

            2)
                update_xray
                pause
                ;;

            3)
                modify_config
                pause
                ;;

            4)
                show_current_config
                pause
                ;;

            5)
                restart_xray
                pause
                ;;

            6)
                systemctl stop xray
                success "Xray 已停止"
                pause
                ;;

            7)
                journalctl -u xray -e --no-pager
                pause
                ;;

            8)
                uninstall_xray
                pause
                ;;

            0)
                exit 0
                ;;

            *)
                error "无效输入"
                pause
                ;;
        esac
    done
}

main "$@"
