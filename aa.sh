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
readonly SCRIPT_VERSION="8.4"

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
    echo -e "${GREEN}[信息] $*${RESET}" >&2
}

warn() {
    echo -e "${YELLOW}[警告] $*${RESET}" >&2
}

error() {
    echo -e "${RED}[错误] $*${RESET}" >&2
}

pause() {
    read -n 1 -s -r -p "按任意键返回菜单..." || true
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
            "https://api.ipify.org" \
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
check_port() {
    local port="$1"

    if ss -tuln | awk '{print $5}' | grep -qE "[:.]${port}$"; then
        return 1  # 被占用
    fi

    return 0  # 没用占用
}

# ================== 验证端口格式 ==================
is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] \
        && [[ "$1" -ge 1 ]] \
        && [[ "$1" -le 65535 ]]
}

# ================== 获取可用随机端口 ==================
get_random_port() {
    local rand_port
    while true; do
        rand_port=$((RANDOM % 55536 + 10000))
        if check_port "$rand_port"; then
            echo "$rand_port"
            return 0
        fi
    done
}

# ================== UUID验证 ==================
is_valid_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

# ================== 域名验证 ==================
is_valid_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9](-?[a-zA-Z0-9])*\.)+[A-Za-z]{2,}$ ]]
}

# ================== 下载官方安装脚本 ==================
download_install_script() {
    local file="$TMP_DIR/install.sh"

    info "下载 Xray 安装脚本..."

    if ! curl -fsSL "$INSTALL_SCRIPT_URL" -o "$file"; then
        error "下载 Xray 安装脚本失败"
        return 1
    fi

    chmod +x "$file"
    echo "$file"
}

# ================== 获取Xray状态 ==================
get_xray_status() {
    if systemctl is-active --quiet xray 2>/dev/null; then
        echo -e "${GREEN}● 运行中${RESET}"
    else
        echo -e "${RED}● 未运行${RESET}"
    fi
}

# ================== 获取版本 ==================
get_xray_version() {
    if [[ -x "$XRAY_BINARY" ]]; then
        "$XRAY_BINARY" version 2>/dev/null \
            | grep -i "Xray" \
            | head -n 1 \
            | awk '{print $2}' || echo "未知"
    else
        echo "未安装"
    fi
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

# ================== 测试配置 ==================
test_config() {
    if "$XRAY_BINARY" run -test -config "$XRAY_CONFIG"; then
        info "Configuration OK"
        return 0
    fi

    error "配置测试失败"
    return 1
}

# ================== 重启服务 ==================
restart_xray() {
    systemctl restart xray 2>/dev/null || true
    sleep 1

    if systemctl is-active --quiet xray 2>/dev/null; then
        info "Xray 启动成功"
        return 0
    fi

    error "Xray 启动失败"
    journalctl -u xray -n 20 --no-pager || true
    return 1
}

# ================== 生成 Reality 密钥 ==================
generate_reality_keys() {
    info "正在生成 Reality 密钥..."
    local key_pair

    if ! key_pair=$(timeout 10 "$XRAY_BINARY" x25519 2>/dev/null); then
        error "Reality 密钥生成失败"
        return 1
    fi

    local private_key
    private_key=$(echo "$key_pair" \
        | grep -i "Private" \
        | awk -F ': ' '{print $2}' \
        | tr -d '\r')

    local public_key
    public_key=$(echo "$key_pair" \
        | grep -i "Public" \
        | awk -F ': ' '{print $2}' \
        | tr -d '\r')

    if [[ -z "${private_key:-}" || -z "${public_key:-}" ]]; then
        error "生成的密钥对无效或为空"
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
    if ! ip=$(get_public_ip); then
        error "获取公网 IP 失败"
        return 1
    fi

    local uuid port domain shortid public_key
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null || echo "error")
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "443")
    domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG" 2>/dev/null || echo "www.amazon.com")
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG" 2>/dev/null || echo "null")
    public_key=$(get_public_key)

    local display_ip="$ip"
    [[ "$ip" =~ ":" ]] && display_ip="[$ip]"

    local hostname
    hostname=$(hostname -s 2>/dev/null | tr ' ' '_')
    [[ -z "$hostname" ]] && hostname="Xray"

    cat > /root/xray_vless_reality.txt <<EOF
vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}&spx=%2F#${hostname}-Reality
EOF
}

# ================== 显示配置 ==================
show_current_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "配置文件不存在"
        return
    fi

    local ip uuid port domain shortid public_key outbound_mode
    ip=$(get_public_ip || echo "未知")
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
    domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
    public_key=$(get_public_key)
    
    local current_protocol
    current_protocol=$(jq -r '.outbounds[0].protocol // "freedom"' "$XRAY_CONFIG" 2>/dev/null || echo "freedom")
    if [[ "$current_protocol" == "socks" ]]; then
        outbound_mode="Socks5 链式代理"
    else
        outbound_mode="直连 (Freedom)"
    fi

    echo -e "${GREEN}====== 当前配置 ======${RESET}"
    echo -e "${YELLOW}IP地址      : ${ip}${RESET}"
    echo -e "${YELLOW}端口        : ${port}${RESET}"
    echo -e "${YELLOW}UUID        : ${uuid}${RESET}"
    echo -e "${YELLOW}SNI         : ${domain}${RESET}"
    echo -e "${YELLOW}PublicKey   : ${public_key}${RESET}"
    echo -e "${YELLOW}ShortID     : ${shortid}${RESET}"
    echo -e "${YELLOW}出口模式    : ${outbound_mode}${RESET}"
    echo

    if [[ -f /root/xray_vless_reality.txt ]]; then
        echo -e "${GREEN}====== VLESS 链接 ======${RESET}"
        cat /root/xray_vless_reality.txt
    fi
}

# ================== 配置 Xray ==================
configure_xray() {
    info "开始配置 Xray Reality..."
    local port uuid domain

    while true; do
        read -rp "请输入端口 (直接回车随机分配端口): " input_port
        if [[ -z "$input_port" ]]; then
            port=$(get_random_port)
            info "已为您随机分配未被占用端口: $port"
            break
        elif is_valid_port "$input_port"; then
            if ! check_port "$input_port"; then
                error "端口 ${input_port} 已被占用，请重新输入。"
                continue
            fi
            port="$input_port"
            break
        else
            error "端口无效"
        fi
    done

    while true; do
        read -rp "请输入UUID (默认:自动生成): " input_uuid
        if [[ -z "${input_uuid:-}" ]]; then
            uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "7415d2b8-1454-4da8-963b-4663e8322851")
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

    local keys private_key short_id
    keys=$(generate_reality_keys) || return 1
    private_key=$(echo "$keys" | cut -d '|' -f1)
    short_id=$(openssl rand -hex 4)

    write_config "$port" "$uuid" "$domain" "$private_key" "$short_id"
    test_config || return 1
    generate_link
    restart_xray
    show_current_config
}

# ================== 配置自定义Socks5出口 ==================
configure_custom_socks5_outbound() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then 
        error "错误: Xray 未安装，无法配置出口模式。"
        return
    fi

    local mode current_protocol tmp_file
    current_protocol=$(jq -r '.outbounds[0].protocol // "freedom"' "$XRAY_CONFIG" 2>/dev/null || echo "freedom")

    echo "---------------------------------------------"
    echo "请选择出口模式："
    if [[ "$current_protocol" == "socks" ]]; then
        echo -e "当前模式: ${YELLOW}Socks5${RESET}"
    else
        echo -e "当前模式: ${GREEN}直连${RESET}"
    fi
    echo "1) 直连出口"
    echo "2) Socks5 出口"
    echo "0) 取消"
    echo "---------------------------------------------"

    read -rp "请输入选项 [0-2]: " mode || true
    case "$mode" in
        1)
            tmp_file=$(mktemp)
            jq '.outbounds = [{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}]' "$XRAY_CONFIG" > "$tmp_file"
            if ! jq empty "$tmp_file" >/dev/null 2>&1; then
                rm -f "$tmp_file"
                error "生成的直连配置无效。"
                return 1
            fi
            cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"
            mv "$tmp_file" "$XRAY_CONFIG"
            chmod 644 "$XRAY_CONFIG" 2>/dev/null || true
            if ! restart_xray; then
                error "切换到直连失败。"
                return 1
            fi
            info "已成功切换为直连出口！"
            return
            ;;
        2)
            ;;
        0|"")
            info "已取消配置。"
            return
            ;;
        *)
            error "无效选项，请输入 0-2 之间的数字。"
            return 1
            ;;
    esac

    info "配置自定义 Socks5 出口代理..."

    local socks_host socks_port socks_user socks_pass

    read -rp "请输入 Socks5 服务器地址/IP: " socks_host || true
    [[ -z "$socks_host" ]] && info "已取消配置。" && return

    while true; do
        read -rp "请输入 Socks5 端口 (默认: 1080): " socks_port || true
        [[ -z "$socks_port" ]] && socks_port=1080
        if is_valid_port "$socks_port"; then
            break
        else
            error "端口无效，请输入一个1-65535之间的数字。"
        fi
    done

    read -rp "请输入 Socks5 用户名 (若无密码认证请直接留空回车): " socks_user || true
    if [[ -n "$socks_user" ]]; then
        read -rs -p "请输入 Socks5 密码: " socks_pass || true
        echo
    else
        socks_pass=""
    fi

    tmp_file=$(mktemp)

    if [[ -n "$socks_user" ]]; then
        jq \
            --arg host "$socks_host" \
            --argjson port "$socks_port" \
            --arg user "$socks_user" \
            --arg pass "$socks_pass" \
            '
            .outbounds = [
              {
                "protocol": "socks",
                "tag": "custom-socks5-out",
                "settings": {
                  "servers": [
                    {
                      "address": $host,
                      "port": $port,
                      "users": [
                        {
                          "user": $user,
                          "pass": $pass
                        }
                      ]
                    }
                  ]
                }
              }
            ]
            ' "$XRAY_CONFIG" > "$tmp_file"
    else
        jq \
            --arg host "$socks_host" \
            --argjson port "$socks_port" \
            '
            .outbounds = [
              {
                "protocol": "socks",
                "tag": "custom-socks5-out",
                "settings": {
                  "servers": [
                    {
                      "address": $host,
                      "port": $port
                    }
                  ]
                }
              }
            ]
            ' "$XRAY_CONFIG" > "$tmp_file"
    fi

    if ! jq empty "$tmp_file" >/dev/null 2>&1; then
        rm -f "$tmp_file"
        error "生成的 Socks5 配置无效，请检查输入后重试。"
        return 1
    fi

    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"
    mv "$tmp_file" "$XRAY_CONFIG"
    chmod 644 "$XRAY_CONFIG" 2>/dev/null || true

    if ! restart_xray; then
        error "Xray 重启失败，当前配置可能与系统环境不兼容。"
        return 1
    fi
    info "已成功切换为 Socks5 出口！"
}

# ================== 安装 ==================
install_xray() {
    info "开始安装 Xray..."
    local install_script
    install_script=$(download_install_script) || return 1

    bash "$install_script" install
    bash "$install_script" install-geodata
    systemctl enable xray 2>/dev/null || true
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
    restart_xray
}

# ================== 修改配置 ==================
modify_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "配置文件不存在"
        return 1
    fi

    local old_port old_uuid old_domain private_key shortid
    old_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "443")
    old_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null || echo "")
    old_domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG" 2>/dev/null || echo "")
    private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG" 2>/dev/null || echo "")
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG" 2>/dev/null || echo "")

    [[ "$shortid" == "null" || -z "$shortid" ]] && shortid=$(openssl rand -hex 4)

    local port uuid domain

    while true; do
        read -rp "请输入新端口 [当前:${old_port}, 回车不修改]: " input_port
        
        # 核心修改：如果为空，直接保持 old_port 
        if [[ -z "$input_port" ]]; then
            port="$old_port"
            break
        # 进阶支持：显式输入 rand 或 rand 触发随机分配
        elif [[ "${input_port,,}" == "rand" ]]; then
            port=$(get_random_port)
            info "已为您重分配随机端口: $port"
            break
        elif is_valid_port "$input_port"; then
            if [[ "$input_port" != "$old_port" ]]; then
                if ! check_port "$input_port"; then
                    error "端口 ${input_port} 已被占用，请更换。"
                    continue
                fi
            fi
            port="$input_port"
            break
        else
            error "端口无效，请输入 1-65535 之间的数字。"
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

    write_config "$port" "$uuid" "$domain" "$private_key" "$shortid"
    test_config || return 1
    generate_link
    restart_xray
    info "配置修改成功"
}

# ================== 卸载 ==================
uninstall_xray() {
    warn "即将卸载 Xray"

    systemctl stop xray 2>/dev/null || true
    local install_script
    install_script=$(download_install_script) || return 1

    bash "$install_script" remove --purge
    rm -f /root/xray_vless_reality.txt
    info "Xray 已卸载"
}

# ================== 菜单 ==================
show_menu() {
    clear
    local status version port_show
    status=$(get_xray_status)
    version=$(get_xray_version)
    port_show="-"

    if [[ -f "$XRAY_CONFIG" ]]; then
        port_show=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "-")
    fi

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Xray Reality 管理面板      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "状态   : $status"
    echo -e "版本   : ${YELLOW}${version}${RESET}"
    echo -e "端口   : ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 Xray Reality${RESET}"
    echo -e "${GREEN} 2. 更新 Xray${RESET}"
    echo -e "${GREEN} 3. 卸载 Xray${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 Xray${RESET}"
    echo -e "${GREEN} 6. 停止 Xray${RESET}"
    echo -e "${GREEN} 7. 重启 Xray${RESET}"
    echo -e "${GREEN} 8. 查看日志${RESET}"
    echo -e "${GREEN} 9. 查看当前配置${RESET}"
    echo -e "${GREEN}10. 配置Socks5出口${RESET}"
    echo -e "0. 退出"
    echo -e "${GREEN}================================${RESET}"
}

# ================== 安装依赖 ==================
install_dependencies() {
    if command -v apt &>/dev/null; then
        apt update && apt install -y jq curl wget openssl ca-certificates iproute2 coreutils || true
    elif command -v dnf &>/dev/null; then
        dnf install -y jq curl wget openssl ca-certificates iproute2 coreutils
    elif command -v yum &>/dev/null; then
        yum install -y jq curl wget openssl ca-certificates iproute2 coreutils
    else
        error "未知的包管理器，请手动安装所需的依赖: jq, curl, wget, openssl"
        exit 1
    fi
}

# ================== 依赖检查 ==================
pre_check() {
    if [[ $(id -u) -ne 0 ]]; then
        error "请使用 root 用户运行"
        exit 1
    fi

    local deps=(jq curl wget openssl ss timeout)
    local missing=0

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing=1
            break
        fi
    done

    if [[ "$missing" -eq 1 ]]; then
        info "检测到缺失依赖，正在安装..."
        install_dependencies
    fi
}

# ================== 主循环 ==================
main() {
    pre_check

    while true; do
        show_menu
        
        local choice=""
        read -r -p $'\033[32m请输入选项: \033[0m' choice || true
        
        [[ -z "$choice" ]] && continue

        case "$choice" in
            1) install_xray; pause ;;
            2) update_xray; pause ;;
            3) uninstall_xray; pause ;;
            4) modify_config; pause ;;
            5) systemctl start xray &>/dev/null || true; restart_xray; pause ;;
            6) systemctl stop xray &>/dev/null || true; info "Xray 已停止"; pause ;;
            7) restart_xray; pause ;;
            8) journalctl -u xray -e --no-pager || true; pause ;;
            9) show_current_config; pause ;;
            10) configure_custom_socks5_outbound; pause ;;
            0) exit 0 ;;
            *) error "无效输入"; pause ;;
        esac
    done
}

main "$@"
