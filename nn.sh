#!/bin/bash

# =========================================================
# Xray VLESS-Reality 管理脚本
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
readonly SCRIPT_VERSION="9.0"

readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_BINARY="/usr/local/bin/xray"
readonly XRAY_PUBLIC_KEY_FILE="/usr/local/etc/xray/public.key"

readonly INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"

TMP_DIR=$(mktemp -d -t xray.XXXXXX)

# ================== cleanup ==================
cleanup() {

    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

# ================== 日志 ==================
info() {

    echo -e "${GREEN}[信息] $*${RESET}"
}

warn() {

    echo -e "${YELLOW}[警告] $*${RESET}"
}

error() {

    echo -e "${RED}[错误] $*${RESET}"
}

pause() {

    read -n 1 -s -r -p "按任意键返回菜单..."
    echo
}

# ================== 获取公网IP ==================
get_public_ip() {

    local ip

    for url in \
        "https://api.ipify.org" \
        "https://ip.sb" \
        "https://checkip.amazonaws.com"; do

        ip=$(curl -4fsSL --max-time 5 "$url" 2>/dev/null || true)

        if [[ -n "${ip:-}" ]]; then

            echo "$ip"

            return 0
        fi
    done

    return 1
}

# ================== 检查端口 ==================
check_port() {

    local port="$1"

    if ss -tuln | awk '{print $5}' | grep -qE "[:.]${port}$"; then

        error "端口 ${port} 已被占用"

        return 1
    fi

    return 0
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

    [[ "$1" =~ ^([a-zA-Z0-9](-?[a-zA-Z0-9])*\.)+[A-Za-z]{2,}$ ]]
}

# ================== 下载官方安装脚本 ==================
download_install_script() {

    local file="$TMP_DIR/install.sh"

    info "下载 Xray 安装脚本..."

    curl -fsSL "$INSTALL_SCRIPT_URL" -o "$file"

    chmod +x "$file"

    echo "$file"
}

# ================== 修复官方 service nobody 警告 ==================
fix_xray_service() {

    local service_file="/etc/systemd/system/xray.service"

    [[ ! -f "$service_file" ]] && return 0

    if grep -q '^User=nobody' "$service_file"; then

        info "修复 xray.service 用户..."

        sed -i 's/^User=nobody/User=xray/' "$service_file"
    fi

    if grep -q '^Group=nobody' "$service_file"; then

        sed -i 's/^Group=nobody/Group=xray/' "$service_file"
    fi

    systemctl daemon-reload
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

    if [[ -x "$XRAY_BINARY" ]]; then

        "$XRAY_BINARY" version 2>/dev/null \
            | head -n 1 \
            | awk '{print $2}'

    else

        echo "未安装"
    fi
}

# ================== 获取监听地址 ==================
get_listen_ip() {

    echo "0.0.0.0"
}

# ================== 测试配置 ==================
test_config() {

    if "$XRAY_BINARY" run -test -config "$XRAY_CONFIG"; then

        info "Xray 配置测试通过"

        return 0
    fi

    error "配置测试失败"

    return 1
}

# ================== 重启服务 ==================
restart_xray() {

    systemctl restart xray

    sleep 2

    if systemctl is-active --quiet xray; then

        info "Xray 启动成功"

        return 0
    fi

    error "Xray 启动失败"

    journalctl -u xray -n 30 --no-pager

    return 1
}

# ================== 生成 Reality 密钥 ==================
generate_reality_keys() {

    info "正在生成 Reality 密钥..."

    local key_pair

    key_pair=$("$XRAY_BINARY" x25519)

    local private_key
    private_key=$(echo "$key_pair" | awk '/Private/{print $3}')

    local public_key
    public_key=$(echo "$key_pair" | awk '/Public/{print $3}')

    if [[ -z "${private_key:-}" ]]; then

        error "privateKey 为空"

        return 1
    fi

    if [[ -z "${public_key:-}" ]]; then

        error "publicKey 为空"

        return 1
    fi

    echo "$public_key" > "$XRAY_PUBLIC_KEY_FILE"

    echo "${private_key}|${public_key}"
}

# ================== 获取 PublicKey ==================
get_public_key() {

    [[ -f "$XRAY_PUBLIC_KEY_FILE" ]] && cat "$XRAY_PUBLIC_KEY_FILE"
}

# ================== 写配置 ==================
write_config() {

    local port="$1"
    local uuid="$2"
    local domain="$3"
    local private_key="$4"
    local shortid="$5"

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
        "realitySettings": {
          "show": false,
          "dest": "${domain}:443",
          "xver": 0,
          "serverNames": [
            "${domain}"
          ],
          "privateKey": "${private_key}",
          "shortIds": [
            "${shortid}"
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
      "protocol": "freedom"
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

    local shortid
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")

    local public_key
    public_key=$(get_public_key)

    cat > /root/xray_vless_reality.txt <<EOF
vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}&spx=%2F#Reality
EOF
}

# ================== 显示配置 ==================
show_current_config() {

    [[ ! -f "$XRAY_CONFIG" ]] && return

    local ip
    ip=$(get_public_ip || echo "未知")

    local uuid
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")

    local port
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")

    local domain
    domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")

    local shortid
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")

    local public_key
    public_key=$(get_public_key)

    echo -e "${GREEN}====== 当前配置 ======${RESET}"

    echo -e "${YELLOW}IP地址      : ${ip}${RESET}"
    echo -e "${YELLOW}端口        : ${port}${RESET}"
    echo -e "${YELLOW}UUID        : ${uuid}${RESET}"
    echo -e "${YELLOW}SNI         : ${domain}${RESET}"
    echo -e "${YELLOW}PublicKey   : ${public_key}${RESET}"
    echo -e "${YELLOW}ShortID     : ${shortid}${RESET}"

    echo

    if [[ -f /root/xray_vless_reality.txt ]]; then

        echo -e "${GREEN}====== VLESS 链接 ======${RESET}"

        cat /root/xray_vless_reality.txt
    fi
}

# ================== 配置 Xray ==================
configure_xray() {

    info "开始配置 Xray Reality..."

    local port
    local uuid
    local domain

    while true; do

        read -rp "请输入端口 (默认:443): " input_port

        port=${input_port:-443}

        if is_valid_port "$port"; then

            check_port "$port" || continue

            break

        else

            error "端口无效"
        fi
    done

    while true; do

        read -rp "请输入UUID (默认:自动生成): " input_uuid

        if [[ -z "${input_uuid:-}" ]]; then

            uuid=$(cat /proc/sys/kernel/random/uuid)

            break

        elif is_valid_uuid "$input_uuid"; then

            uuid="$input_uuid"

            break

        else

            error "UUID 格式无效"
        fi
    done

    while true; do

        read -rp "请输入SNI域名 (默认:www.amazon.com): " input_domain

        domain=${input_domain:-www.amazon.com}

        if is_valid_domain "$domain"; then

            break

        else

            error "域名格式无效"
        fi
    done

    local keys
    keys=$(generate_reality_keys) || return 1

    local private_key
    private_key=$(echo "$keys" | cut -d '|' -f1)

    local short_id
    short_id=$(openssl rand -hex 4)

    write_config \
        "$port" \
        "$uuid" \
        "$domain" \
        "$private_key" \
        "$short_id"

    test_config || return 1

    generate_link

    restart_xray

    show_current_config
}

# ================== 安装 ==================
install_xray() {

    info "开始安装 Xray..."

    local install_script

    install_script=$(download_install_script) || return 1

    bash "$install_script" install

    bash "$install_script" install-geodata

    systemctl enable xray

    fix_xray_service

    configure_xray

    info "Xray 已安装完成"
}

# ================== 更新 ==================
update_xray() {

    info "更新 Xray..."

    local install_script

    install_script=$(download_install_script) || return 1

    bash "$install_script" install

    bash "$install_script" install-geodata

    fix_xray_service

    restart_xray
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

    local shortid
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")

    if [[ -z "${private_key:-}" || "$private_key" == "null" ]]; then

        warn "检测到 privateKey 丢失，重新生成..."

        local keys
        keys=$(generate_reality_keys) || return 1

        private_key=$(echo "$keys" | cut -d '|' -f1)
    fi

    if [[ -z "${shortid:-}" || "$shortid" == "null" ]]; then

        shortid=$(openssl rand -hex 4)
    fi

    local port
    local uuid
    local domain

    while true; do

        read -rp "请输入新端口 [当前:${old_port}]: " input_port

        port=${input_port:-$old_port}

        if is_valid_port "$port"; then

            if [[ "$port" != "$old_port" ]]; then

                check_port "$port" || continue
            fi

            break

        else

            error "端口无效"
        fi
    done

    while true; do

        read -rp "请输入UUID [当前:${old_uuid}]: " input_uuid

        uuid=${input_uuid:-$old_uuid}

        if is_valid_uuid "$uuid"; then

            break

        else

            error "UUID 格式无效"
        fi
    done

    while true; do

        read -rp "请输入SNI域名 [当前:${old_domain}]: " input_domain

        domain=${input_domain:-$old_domain}

        if is_valid_domain "$domain"; then

            break

        else

            error "域名格式无效"
        fi
    done

    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"

    write_config \
        "$port" \
        "$uuid" \
        "$domain" \
        "$private_key" \
        "$shortid"

    test_config || return 1

    generate_link

    restart_xray

    info "配置修改成功"
}

# ================== 卸载 ==================
uninstall_xray() {

    warn "即将卸载 Xray"

    read -rp "确认卸载？[y/N]: " confirm

    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    systemctl stop xray || true

    local install_script

    install_script=$(download_install_script) || return 1

    bash "$install_script" remove --purge

    rm -f /root/xray_vless_reality.txt

    info "Xray 已卸载"
}

# ================== 菜单 ==================
show_menu() {

    clear

    local status
    status=$(get_xray_status)

    local version
    version=$(get_xray_version)

    local port_show="-"

    if [[ -f "$XRAY_CONFIG" ]]; then

        port_show=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
    fi

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Xray Reality 管理面板      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "状态   : $status"
    echo -e "版本   : ${YELLOW}${version}${RESET}"
    echo -e "端口   : ${YELLOW}${port_show}${RESET}"
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

# ================== 安装依赖 ==================
install_dependencies() {

    apt update

    apt install -y \
        jq \
        curl \
        wget \
        openssl \
        ca-certificates \
        iproute2 \
        coreutils
}

# ================== 依赖检查 ==================
pre_check() {

    if [[ $(id -u) -ne 0 ]]; then

        error "请使用 root 用户运行"

        exit 1
    fi

    local deps=(
        jq
        curl
        wget
        openssl
        ss
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

        info "安装依赖..."

        install_dependencies
    fi
}

# ================== 主循环 ==================
main() {

    pre_check

    while true; do

        show_menu

        read -r -p $'\033[32m请输入选项: \033[0m' choice

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
                uninstall_xray
                pause
                ;;

            4)
                modify_config
                pause
                ;;

            5)
                systemctl start xray
                restart_xray
                pause
                ;;

            6)
                systemctl stop xray
                info "Xray 已停止"
                pause
                ;;

            7)
                restart_xray
                pause
                ;;

            8)
                journalctl -u xray -e --no-pager
                pause
                ;;

            9)
                show_current_config
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
