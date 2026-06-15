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
readonly SERVICE_NAME="vlessreality"
readonly XRAY_CONFIG="/usr/local/etc/${SERVICE_NAME}/config.json"
readonly XRAY_BINARY="/usr/local/bin/${SERVICE_NAME}"
readonly XRAY_PUBLIC_KEY_FILE="/usr/local/etc/${SERVICE_NAME}/public.key"

# 降级备用版本（当自动获取最新版本失败时使用）
readonly BACKUP_VERSION="26.3.27"

TMP_DIR=$(mktemp -d -t xray.XXXXXX)

# ================== GITHUB 代理 ==================
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

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
    local mode=${1:-"v4"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        # 强制获取 IPv4
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        # 强制获取 IPv6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        # auto 模式：双栈环境优先获取 IPv4 (更适合大众网络)，纯 v6 环境自动fallback到 v6
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        # 如果获取 v4 失败，说明可能是纯 v6 机器，尝试获取 v6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    # 兜底处理：所有接口都失败时，直接输出 127.0.0.1，不报错
    echo "127.0.0.1" && return 0
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

# ================== ShortID 验证 ==================
is_valid_shortid() {
    local len=${#1}
    if [[ "$1" =~ ^[0-9a-fA-F]+$ ]] && (( len % 2 == 0 )) && (( len <= 16 )); then
        return 0
    fi
    return 1
}

# ================== 域名验证 ==================
is_valid_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9](-?[a-zA-Z0-9])*\.)+[A-Za-z]{2,}$ ]]
}

# ================== 架构检测 ==================
get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        armv7l) echo "arm32-v7a" ;;
        *) error "暂不支持的系统架构: $arch"; return 1 ;;
    esac
}

# ================== 自动获取最新版本号 ==================
get_latest_version() {
    local latest_version=""
    info "正在获取 GitHub 最新 Xray 版本号..."
    
    # 优先尝试直连拉取 API
    latest_version=$(curl -fsSL --max-time 5 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
        | jq -r '.tag_name' 2>/dev/null || echo "")
        
    # 如果直连获取失败，轮询代理进行 API 拉取
    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        for proxy in "${GITHUB_PROXY[@]}"; do
            [[ -z "$proxy" ]] && continue
            latest_version=$(curl -fsSL --max-time 5 "${proxy}https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
                | jq -r '.tag_name' 2>/dev/null || echo "")
            [[ -n "$latest_version" && "$latest_version" != "null" ]] && break
        done
    fi

    latest_version="${latest_version#v}"

    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        warn "通过 GitHub 接口获取最新版本失败，将使用内置备用版本: v${BACKUP_VERSION}"
        echo "$BACKUP_VERSION"
    else
        info "成功获取最新版本: v${latest_version}"
        echo "$latest_version"
    fi
}

# ================== 代理下载核心逻辑 ==================
download_file() {
    local url_path="$1"
    local output_file="$2"
    local success=1

    for proxy in "${GITHUB_PROXY[@]}"; do
        info "尝试使用代理下载: ${proxy:-直连}"
        if wget -T 15 -t 2 -O "$output_file" "${proxy}${url_path}"; then
            success=0
            break
        fi
    done
    return $success
}

# ================== 从GitHub下载并解压Xray ==================
download_and_extract_xray() {
    local arch version
    arch=$(get_arch) || return 1
    version=$(get_latest_version)
    
    local download_url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${arch}.zip"
    local zip_file="$TMP_DIR/xray.zip"
    
    info "正在准备从 GitHub 下载 Xray v${version} (${arch})..."
    if ! download_file "$download_url" "$zip_file"; then
        error "从 GitHub 下载 Xray 失败，所有代理均已尝试，请检查网络连接。"
        return 1
    fi
    
    info "正在解压..."
    mkdir -p "$TMP_DIR/extracted"
    if ! unzip -qo "$zip_file" -d "$TMP_DIR/extracted"; then
        error "解压 Xray 压缩包失败，请确保系统已安装 unzip。"
        return 1
    fi
    
    # 安装二进制文件
    mkdir -p "$(dirname "$XRAY_BINARY")"
    rm -f "$XRAY_BINARY"
    cp -f "$TMP_DIR/extracted/xray" "$XRAY_BINARY"
    chmod +x "$XRAY_BINARY"
    
    # 安装 GeoData 资源文件
    mkdir -p "/usr/local/share/${SERVICE_NAME}"
    cp -f "$TMP_DIR/extracted/geoip.dat" "/usr/local/share/${SERVICE_NAME}/" 2>/dev/null || true
    cp -f "$TMP_DIR/extracted/geosite.dat" "/usr/local/share/${SERVICE_NAME}/" 2>/dev/null || true
}

# ================== 配置 Systemd 服务 ==================
setup_systemd_service() {
    info "配置 Systemd 服务 [${SERVICE_NAME}]..."
    
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Xray Vless Reality Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BINARY} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" 2>/dev/null || true
}

# ================== 获取Xray状态 ==================
get_xray_status() {
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
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
    systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
    sleep 1

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        info "${SERVICE_NAME} 启动成功"
        return 0
    fi

    error "${SERVICE_NAME} 启动失败"
    journalctl -u "${SERVICE_NAME}" -n 20 --no-pager || true
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

    mkdir -p "$(dirname "$XRAY_CONFIG")"

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

    mkdir -p /root/proxynode/Reality/

    cat > /root/proxynode/Reality/xray_vless_reality.txt <<EOF
vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}&spx=%2F#${hostname}-VLESS-Reality
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
    echo -e "${YELLOW}📄 V6VPS 请自行替换分享链接中的 IP 地址为 V6 ★${RESET}"
    echo

    if [[ -f /root/proxynode/Reality/xray_vless_reality.txt ]]; then
        echo -e "${GREEN}====== 👉 分享链接 ======${RESET}"
        cat /root/proxynode/Reality/xray_vless_reality.txt
    fi
}

# ================== 配置 Xray ==================
configure_xray() {
    info "开始配置 Reality 节点..."
    local port uuid domain short_id

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

    while true; do
        read -rp "请输入自定义 ShortID (直接回车自动生成 8 位字符): " input_shortid
        if [[ -z "$input_shortid" ]]; then
            short_id=$(openssl rand -hex 4)
            break
        elif is_valid_shortid "$input_shortid"; then
            short_id="$input_shortid"
            break
        else
            error "ShortID 无效！必须为偶数位（最长16位）的十六进制字符（0-9, a-f）。"
        fi
    done

    mkdir -p "/usr/local/etc/${SERVICE_NAME}"

    local keys private_key
    keys=$(generate_reality_keys) || return 1
    private_key=$(echo "$keys" | cut -d '|' -f1)

    write_config "$port" "$uuid" "$domain" "$private_key" "$short_id"
    test_config || return 1
    generate_link
    restart_xray
    show_current_config
}

# ================== 配置自定义Socks5出口 ==================
configure_custom_socks5_outbound() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then 
        error "错误: 未安装，无法配置出口模式。"
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
        error "重启服务失败，当前配置可能与 system 境不兼容。"
        return 1
    fi
    info "已成功切换为 Socks5 出口！"
}

# ================== 安装 ==================
install_xray() {
    info "开始解压安装 Xray..."
    download_and_extract_xray || return 1
    setup_systemd_service
    configure_xray
    info "安装完成并已成功启动服务: ${SERVICE_NAME}"
}

# ================== 更新 ==================
update_xray() {
    info "开始更新 Xray 程序..."
    
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        info "检测到服务正在运行，正在停止服务以进行更新..."
        systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    fi

    info "开始拉取最新 Xray 二进制文件..."
    if ! download_and_extract_xray; then
        error "下载或安装新版本失败，尝试重新启动原服务..."
        restart_xray
        return 1
    fi
    
    if restart_xray; then
        info "最新版更新并启动成功！当前版本: $(get_xray_version)"
    else
        error "更新后服务启动失败，请查看日志。"
        return 1
    fi
}

# ================== 修改配置 ==================
modify_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "配置文件不存在"
        return 1
    fi

    local old_port old_uuid old_domain private_key old_shortid
    old_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "443")
    old_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null || echo "")
    old_domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG" 2>/dev/null || echo "")
    private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG" 2>/dev/null || echo "")
    old_shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG" 2>/dev/null || echo "")

    [[ "$old_shortid" == "null" || -z "$old_shortid" ]] && old_shortid=$(openssl rand -hex 4)

    local port uuid domain shortid

    while true; do
        read -rp "请输入新端口 [当前:${old_port}, 回车不修改]: " input_port
        
        if [[ -z "$input_port" ]]; then
            port="$old_port"
            break
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

    while true; do
        read -rp "请输入ShortID [当前:${old_shortid}, 回车不修改]: " input_shortid
        shortid=${input_shortid:-$old_shortid}
        if is_valid_shortid "$shortid"; then
            break
        else
            error "ShortID 无效！必须为偶数位（最长16位）的十六进制字符（0-9, a-f）。"
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
    warn "即将卸载 vlessreality 服务..."

    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    
    rm -f "$XRAY_BINARY"
    rm -rf "/usr/local/etc/${SERVICE_NAME}"
    rm -rf "/usr/local/share/${SERVICE_NAME}"
    rm -f /root/proxynode/Reality/xray_vless_reality.txt
    
    info "服务已完全卸载并清理残留。"
}

# ================== SNI 优选 ==================
select_best_sni() {
    info "开始优选 SNI 延迟测试"

    local SNIS=(
        amd.com apps.mzstatic.com aws.com azure.microsoft.com beacon.gtv-pub.com
        bing.com catalog.gamepass.com cdn.bizibly.com cdn-dynmedia-1.microsoft.com
        devblogs.microsoft.com fpinit.itunes.apple.com go.microsoft.com
        gray-config-prod.api.arc-cdn.net gray.video-player.arcpublishing.com
        images.nvidia.com r.bing.com services.digitaleast.mobi snap.licdn.com
        statici.icloud.com tag.demandbase.com tag-logger.demandbase.com
        ts1.tc.mm.bing.net ts2.tc.mm.bing.net vs.aws.amazon.com www.apple.com
        www.icloud.com www.microsoft.com www.oracle.com www.xbox.com
        www.xilinx.com xp.apple.com
    )

    local BEST_SNI=""
    local BEST_TIME=999999

    for sni in "${SNIS[@]}"; do
        local start
        start=$(date +%s%N)

        if timeout 3 openssl s_client -connect "${sni}:443" -servername "${sni}" -brief </dev/null >/dev/null 2>&1; then
            local end cost
            end=$(date +%s%N)
            cost=$(( (end - start) / 1000000 ))

            echo "[SNI] $sni -> ${cost}ms"

            if [ $cost -lt $BEST_TIME ]; then
                BEST_TIME=$cost
                BEST_SNI=$sni
            fi
        fi
    done

    if [ -n "$BEST_SNI" ]; then
        info "最优 SNI: $BEST_SNI (${BEST_TIME}ms)"
        echo "$BEST_SNI"
        return 0
    else
        warn "未找到可用 SNI"
        return 1
    fi
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
    echo -e "${GREEN}      VLESS-Reality 面板       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 VLESS-Reality${RESET}"
    echo -e "${GREEN} 2. 更新 VLESS-Reality${RESET}"
    echo -e "${GREEN} 3. 卸载 VLESS-Reality${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 VLESS-Reality${RESET}"
    echo -e "${GREEN} 6. 停止 VLESS-Reality${RESET}"
    echo -e "${GREEN} 7. 重启 VLESS-Reality${RESET}"
    echo -e "${GREEN} 8. 查看服务日志${RESET}"
    echo -e "${GREEN} 9. 查看节点配置${RESET}"
    echo -e "${GREEN}10. 配置Socks5出口${RESET}"
    echo -e "${GREEN}11. SNI域名优选✨${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# ================== 安装依赖 ==================
install_dependencies() {
    if command -v apt &>/dev/null; then
        apt update && apt install -y jq curl wget openssl ca-certificates iproute2 coreutils unzip || true
    elif command -v dnf &>/dev/null; then
        dnf install -y jq curl wget openssl ca-certificates iproute2 coreutils unzip
    elif command -v yum &>/dev/null; then
        yum install -y jq curl wget openssl ca-certificates iproute2 coreutils unzip
    else
        error "未知的包管理器，请手动安装所需的依赖: jq, curl, wget, openssl, unzip"
        exit 1
    fi
}

# ================== 依赖检查 ==================
pre_check() {
    if [[ $(id -u) -ne 0 ]]; then
        error "请使用 root 用户运行"
        exit 1
    fi

    local deps=(jq curl wget openssl ss timeout unzip)
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
            5) systemctl start "${SERVICE_NAME}" &>/dev/null || true; restart_xray; pause ;;
            6) systemctl stop "${SERVICE_NAME}" &>/dev/null || true; info "服务已停止"; pause ;;
            7) restart_xray; pause ;;
            8) journalctl -u "${SERVICE_NAME}" -e --no-pager || true; pause ;;
            9) show_current_config; pause ;;
            10) configure_custom_socks5_outbound; pause ;;
            11) select_best_sni; pause ;;
            0) exit 0 ;;
            *) error "无效输入"; pause ;;
        esac
    done
}

main "$@"
