#!/bin/bash

# ==============================================================================
# VLESS-Reality-xHTTP 一键安装管理脚本
# ==============================================================================

# --- Shell 严格模式 ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="V-xHTTP-2.2"
readonly xray_config_path="/usr/local/etc/xray/config.json"
readonly xray_binary_path="/usr/local/bin/xray"
readonly xray_install_script_url="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"

# --- 颜色定义 ---
readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'

# --- 全局变量 ---
xray_status_info=""
is_quiet=false

# --- 辅助函数 ---
error() { echo -e "\n$red[✖] $1$none\n" >&2; }
info() { [[ "$is_quiet" = false ]] && echo -e "\n$yellow[!] $1$none\n"; }
success() { [[ "$is_quiet" = false ]] && echo -e "\n$green[✔] $1$none\n"; }

spinner() {
    local pid=$1; local spinstr='|/-\'
    if [[ "$is_quiet" = true ]]; then
        wait "$pid"
        return
    fi
    while ps -p "$pid" > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\r"
    done
    printf "    \r"
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    error "无法获取公网 IP 地址。" && return 1
}

execute_official_script() {
    local args="$1"
    bash <(curl -L "$xray_install_script_url") $args &> /dev/null &
    spinner $!
    wait $! || return 1
}

is_valid_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

is_port_in_use() {
    local port=$1
    if command -v ss &>/dev/null; then
        ss -tuln 2>/dev/null | grep -q ":$port "
    else
        timeout 1 bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null
    fi
}

is_valid_uuid() {
    local uuid=$1
    [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

is_valid_domain() {
    local domain=$1
    [[ "$domain" =~ ^[a-zA-Z0-9-]{1,63}(\.[a-zA-Z0-9-]{1,63})+$ ]] && [[ "$domain" != *--* ]]
}

pre_check() {
    [[ $(id -u) != 0 ]] && error "错误: 您必须以root用户身份运行此脚本" && exit 1
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null || ! command -v openssl &>/dev/null; then
        info "检测到缺失依赖 (jq/curl/openssl)，正在自动安装..."
        (DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y jq curl openssl) &> /dev/null &
        spinner $!
    fi
}

check_xray_status() {
    if [[ ! -f "$xray_binary_path" ]]; then xray_status_info="  Xray 状态: ${red}未安装${none}"; return; fi
    local service_status
    if systemctl is-active --quiet xray 2>/dev/null; then service_status="${green}运行中 (xHTTP)${none}"; else service_status="${yellow}未运行${none}"; fi
    xray_status_info="  Xray 状态: ${green}已安装${none} | ${service_status}"
}

# --- 核心逻辑 ---
write_config() {
    local port=$1 uuid=$2 domain=$3 private_key=$4 public_key=$5 shortid=${6:-}
    local xhttp_path="/$(openssl rand -hex 4)"

    [[ -z "$shortid" ]] && shortid=$(openssl rand -hex 8)

    # --- 新增：确保配置目录存在 ---
    mkdir -p "$(dirname "$xray_config_path")"

    jq -n \
        --argjson port "$port" --arg uuid "$uuid" --arg domain "$domain" \
        --arg private_key "$private_key" --arg public_key "$public_key" \
        --arg shortid "$shortid" --arg path "$xhttp_path" \
    '{
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "listen": "0.0.0.0",
            "port": $port,
            "protocol": "vless",
            "settings": {"clients": [{"id": $uuid}], "decryption": "none"},
            "streamSettings": {
                "network": "xhttp",
                "security": "reality",
                "realitySettings": {
                    "show": false, "dest": ($domain + ":443"), "xver": 0,
                    "serverNames": [$domain], "privateKey": $private_key,
                    "publicKey": $public_key, "shortIds": [$shortid]
                },
                "xhttpSettings": {"path": $path, "mode": "speed"}
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
        }],
        "outbounds": [{"protocol": "freedom"}]
    }' > "$xray_config_path"
}
# --- 菜单功能函数 ---
install_xray() {
    if [[ -f "$xray_binary_path" ]]; then
        info "检测到 Xray 已安装。继续操作将覆盖现有配置。"
        read -p "是否继续？[y/N]: " confirm
        [[ ! $confirm =~ ^[yY]$ ]] && return
    fi
    
    local port uuid domain
    while true; do
        read -p "$(echo -e "请输入端口 [1-65535] (默认: ${cyan}443${none}): ")" port
        [ -z "$port" ] && port=443
        if is_valid_port "$port" && ! is_port_in_use "$port"; then break; else error "端口无效或被占用"; fi
    done

    read -p "$(echo -e "请输入UUID (留空随机): ")" uuid
    [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)

    read -p "$(echo -e "请输入SNI域名 (默认: ${cyan}learn.microsoft.com${none}): ")" domain
    [ -z "$domain" ] && domain="learn.microsoft.com"

    # 在 install_xray 函数中修改这两行
    local key_pair=$($xray_binary_path x25519 2>/dev/null)
    local private_key=$(echo "$key_pair" | awk -F': ' '/PrivateKey/ {print $2}' | tr -d '[:space:]')
    local public_key=$(echo "$key_pair" | awk -F': ' '/PublicKey/ {print $2}' | tr -d '[:space:]')

    write_config "$port" "$uuid" "$domain" "$pri" "$pub"
    systemctl restart xray && success "安装成功！"
    view_subscription_info
}

modify_config() {
    [[ ! -f "$xray_config_path" ]] && error "未安装 Xray" && return
    local c_port=$(jq -r '.inbounds[0].port' "$xray_config_path")
    local c_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$xray_config_path")
    local c_domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$xray_config_path")
    local pri=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$xray_config_path")
    local pub=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$xray_config_path")
    local sid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$xray_config_path")

    read -p "端口 (当前 $c_port): " n_port; [[ -z "$n_port" ]] && n_port=$c_port
    read -p "UUID (当前 $c_uuid): " n_uuid; [[ -z "$n_uuid" ]] && n_uuid=$c_uuid
    read -p "SNI  (当前 $c_domain): " n_domain; [[ -z "$n_domain" ]] && n_domain=$c_domain

    write_config "$n_port" "$n_uuid" "$n_domain" "$pri" "$pub" "$sid"
    systemctl restart xray && success "配置修改成功！"
    view_subscription_info
}

view_subscription_info() {
    [[ ! -f "$xray_config_path" ]] && error "配置文件不存在, 请先安装。" && return 1
    
    local ip=$(get_public_ip || echo "127.0.0.1")
    local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$xray_config_path")
    local port=$(jq -r '.inbounds[0].port' "$xray_config_path")
    local domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$xray_config_path")
    local public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$xray_config_path")
    local shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$xray_config_path")
    local xhttp_path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$xray_config_path")
    local xhttp_mode=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.mode' "$xray_config_path")

    # 对 Path 进行 URL 编码 (将 / 转换为 %2F)
    local encoded_path=$(echo -n "$xhttp_path" | sed 's/\//%2F/g')
    
    # 构造标准 VLESS 链接
    local display_ip=$ip && [[ $ip =~ ":" ]] && display_ip="[$ip]"
    local link_name="$(hostname)-VLESS-XHTTP"
    local vless_url="vless://${uuid}@${display_ip}:${port}?encryption=none&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}&type=xhttp&path=${encoded_path}&mode=${xhttp_mode}#${link_name}"

    echo -e "\n$green --- Xray VLESS-Reality-xHTTP 订阅信息 --- $none"
    echo -e "$yellow 地址: $cyan$ip$none"
    echo -e "$yellow 端口: $cyan$port$none"
    echo -e "$yellow UUID: $cyan$uuid$none"
    echo -e "$yellow SNI:  $cyan$domain$none"
    echo -e "$yellow Path: $cyan$xhttp_path$none (Mode: $xhttp_mode)"
    echo -e "----------------------------------------------------------------"
    echo -e "$green 标准订阅链接 (可直接导入): $none"
    echo -e "$cyan${vless_url}${none}"
    echo -e "----------------------------------------------------------------"
}

# --- 菜单界面 ---
main_menu() {
    while true; do
        clear
        echo -e "$cyan Xray VLESS-Reality-XHTTP 一键安装管理脚本$none"
        echo "---------------------------------------------"
        check_xray_status
        echo -e "${xray_status_info}"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装/重装 Xray (VLESS-XHTTP)"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 Xray"
        printf "  ${yellow}%-2s${none} %-35s\n" "3." "重启 Xray"
        printf "  ${red}%-2s${none} %-35s\n" "4." "卸载 Xray"
        printf "  ${magenta}%-2s${none} %-35s\n" "5." "查看 Xray 日志"
        printf "  ${cyan}%-2s${none} %-35s\n" "6." "修改节点配置"
        printf "  ${green}%-2s${none} %-35s\n" "7." "查看订阅信息"
        echo "---------------------------------------------"
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "退出脚本"
        echo "---------------------------------------------"
        read -p "请输入选项 [0-7]: " choice

        case $choice in
            1) install_xray ;;
            2) execute_official_script "install" && success "更新成功" ;;
            3) systemctl restart xray && success "已重启" ;;
            4) execute_official_script "remove --purge" && success "已卸载" ;;
            5) journalctl -u xray -f ;;
            6) modify_config ;;
            7) view_subscription_info ;;
            0) exit 0 ;;
            *) error "无效选项" ;;
        esac
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

pre_check
main_menu
