#!/bin/bash

# =========================================================
# Xray VLESS-REALITY-xhttp  管理脚本
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
readonly SERVICE_NAME="vless-xhttp"
readonly XRAY_CONFIG="/usr/local/etc/${SERVICE_NAME}/config.json"
readonly XRAY_BINARY="/usr/local/bin/${SERVICE_NAME}"
readonly XRAY_PUBLIC_KEY_FILE="/usr/local/etc/${SERVICE_NAME}/public.key"

# 降级备用版本
readonly BACKUP_VERSION="26.3.27"

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
    for cmd in "curl -4fsSL --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null || true)
            if [[ -n "${ip:-}" ]]; then echo "$ip"; return 0; fi
        done
    done
    for cmd in "curl -6fsSL --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ipv6.ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null || true)
            if [[ -n "${ip:-}" ]]; then echo "$ip"; return 0; fi
        done
    done
    return 1
}

# ================== 检查与校验 ==================
check_port() {
    local port="$1"
    if ss -tuln | awk '{print $5}' | grep -qE "[:.]${port}$"; then return 1; fi
    return 0
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

get_random_port() {
    local rand_port
    while true; do
        rand_port=$((RANDOM % 55536 + 10000))
        if check_port "$rand_port"; then echo "$rand_port"; return 0; fi
    done
}

is_valid_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

is_valid_shortid() {
    local len=${#1}
    if [[ "$1" =~ ^[0-9a-fA-F]+$ ]] && (( len % 2 == 0 )) && (( len <= 16 )); then return 0; fi
    return 1
}

is_valid_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9](-?[a-zA-Z0-9])*\.)+[A-Za-z]{2,}$ ]]
}

is_valid_path() {
    [[ "$1" =~ ^\/[a-zA-Z0-9\/_-]+$ ]]
}

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

get_latest_version() {
    local latest_version
    info "正在获取 GitHub 最新 Xray 版本号..."
    latest_version=$(curl -fsSL --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | jq -r '.tag_name' 2>/dev/null || echo "")
    latest_version="${latest_version#v}"
    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        warn "拉取最新版本失败，将使用内置备用版本: v${BACKUP_VERSION}"
        echo "$BACKUP_VERSION"
    else
        info "成功获取最新版本: v${latest_version}"
        echo "$latest_version"
    fi
}

# ================== 下载并安装 ==================
download_and_extract_xray() {
    local arch version
    arch=$(get_arch) || return 1
    version=$(get_latest_version)
    local download_url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${arch}.zip"
    local zip_file="$TMP_DIR/xray.zip"
    
    info "正在下载 Xray v${version} (${arch})..."
    if ! curl -L -fsSL "$download_url" -o "$zip_file"; then
        error "从 GitHub 下载 Xray 失败"
        return 1
    fi
    
    info "正在解压..."
    mkdir -p "$TMP_DIR/extracted"
    if ! unzip -qo "$zip_file" -d "$TMP_DIR/extracted"; then
        error "解压失败，请确保系统已安装 unzip。"
        return 1
    fi
    
    mkdir -p "$(dirname "$XRAY_BINARY")"
    rm -f "$XRAY_BINARY"
    cp -f "$TMP_DIR/extracted/xray" "$XRAY_BINARY"
    chmod +x "$XRAY_BINARY"
    
    mkdir -p "/usr/local/share/${SERVICE_NAME}"
    cp -f "$TMP_DIR/extracted/geoip.dat" "/usr/local/share/${SERVICE_NAME}/" 2>/dev/null || true
    cp -f "$TMP_DIR/extracted/geosite.dat" "/usr/local/share/${SERVICE_NAME}/" 2>/dev/null || true
}

setup_systemd_service() {
    info "配置 Systemd 服务 [${SERVICE_NAME}]..."
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Xray Vless Reality xhttp Service
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

get_xray_status() {
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        echo -e "${GREEN}● 运行中${RESET}"
    else
        echo -e "${RED}● 未运行${RESET}"
    fi
}

get_xray_version() {
    if [[ -x "$XRAY_BINARY" ]]; then
        "$XRAY_BINARY" version 2>/dev/null | grep -i "Xray" | head -n 1 | awk '{print $2}' || echo "未知"
    else
        echo "未安装"
    fi
}

test_config() {
    if "$XRAY_BINARY" run -test -config "$XRAY_CONFIG"; then
        info "配置测试成功！"
        return 0
    fi
    error "配置测试失败"
    return 1
}

restart_xray() {
    systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        info "服务启动成功"
        return 0
    fi
    error "服务启动失败"
    journalctl -u "${SERVICE_NAME}" -n 20 --no-pager || true
    return 1
}

generate_reality_keys() {
    info "正在生成 Reality 密钥对..."
    local key_pair private_key public_key
    if ! key_pair=$(timeout 10 "$XRAY_BINARY" x25519 2>/dev/null); then
        error "密钥生成失败"
        return 1
    fi
    private_key=$(echo "$key_pair" | grep -i "Private" | awk -F ': ' '{print $2}' | tr -d '\r')
    public_key=$(echo "$key_pair" | grep -i "Public" | awk -F ': ' '{print $2}' | tr -d '\r')
    echo "$public_key" > "$XRAY_PUBLIC_KEY_FILE"
    echo "${private_key}|${public_key}"
}

get_public_key() {
    [[ -f "$XRAY_PUBLIC_KEY_FILE" ]] && cat "$XRAY_PUBLIC_KEY_FILE"
}

# ================== 使用 JQ 动态安全写配置 ==================
write_config() {
    local port="$1"
    local uuid="$2"
    local domain="$3"
    local private_key="$4"
    local shortid="$5"
    local path="$6"

    mkdir -p "$(dirname "$XRAY_CONFIG")"

    jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg target "$domain" \
        --arg privateKey "$private_key" \
        --arg shortId "$shortid" \
        --arg path "$path" \
      '{
        "log": {"loglevel": "warning"},
        "inbounds": [{
          "listen": "::",
          "port": $port,
          "protocol": "vless",
          "settings": {
            "clients": [{"id": $uuid}],
            "decryption": "none"
          },
          "streamSettings": {
            "network": "xhttp",
            "security": "reality",
            "realitySettings": {
              "show": false,
              "dest": ($target + ":443"),
              "serverNames": [$target],
              "privateKey": $privateKey,
              "shortIds": [$shortId]
            },
            "xhttpSettings": {
              "host": "",
              "path": $path
            }
          },
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls", "quic"],
            "metadataOnly": false
          }
        }],
        "outbounds": [{
          "protocol": "freedom",
          "settings": {
            "domainStrategy": "UseIPv4v6"
          }
        }]
      }' > "$XRAY_CONFIG"
}

# ================== 生成分享链接 ==================
generate_link() {
    local ip uuid port domain shortid public_key path display_ip hostname
    if ! ip=$(get_public_ip); then error "获取公网 IP 失败"; return 1; fi

    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null)
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null)
    domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG" 2>/dev/null)
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG" 2>/dev/null)
    path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$XRAY_CONFIG" 2>/dev/null)
    public_key=$(get_public_key)

    display_ip="$ip"
    [[ "$ip" =~ ":" ]] && display_ip="[$ip]"
    hostname=$(hostname -s 2>/dev/null | tr ' ' '_')
    [[ -z "$hostname" ]] && hostname="Xray"

    cat > /root/xray_vless_reality.txt <<EOF
vless://${uuid}@${display_ip}:${port}?encryption=none&type=xhttp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}&path=${path}#${hostname}-xhttp
EOF
}

# ================== 显示节点信息 ==================
show_current_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "配置文件不存在"; return; fi
    local ip uuid port domain shortid public_key path outbound_mode current_protocol
    ip=$(get_public_ip || echo "未知")
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null)
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null)
    domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG" 2>/dev/null)
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG" 2>/dev/null)
    path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$XRAY_CONFIG" 2>/dev/null)
    public_key=$(get_public_key)
    
    current_protocol=$(jq -r '.outbounds[0].protocol // "freedom"' "$XRAY_CONFIG" 2>/dev/null)
    outbound_mode=$([[ "$current_protocol" == "socks" ]] && echo "Socks5 链式代理" || echo "直连 (Freedom)")

    echo -e "${GREEN}====== 当前配置 ======${RESET}"
    echo -e "${YELLOW}IP地址      : ${ip}${RESET}"
    echo -e "${YELLOW}端口        : ${port}${RESET}"
    echo -e "${YELLOW}UUID        : ${uuid}${RESET}"
    echo -e "${YELLOW}SNI (域名)  : ${domain}${RESET}"
    echo -e "${YELLOW}PublicKey   : ${public_key}${RESET}"
    echo -e "${YELLOW}ShortID     : ${shortid}${RESET}"
    echo -e "${YELLOW}XHTTP Path  : ${path}${RESET}"
    echo -e "${YELLOW}出口模式    : ${outbound_mode}${RESET}"
    echo

    if [[ -f /root/xray_vless_reality.txt ]]; then
        echo -e "${GREEN}====== 👉 v2rayN 分享链接 ======${RESET}"
        cat /root/xray_vless_reality.txt
    fi
}

# ================== 配置节点逻辑 ==================
configure_xray() {
    info "开始配置 Reality-xhttp 节点..."
    local port uuid domain short_id path input_port input_uuid input_domain input_shortid input_path keys private_key

    while true; do
        read -rp "请输入端口 (直接回车随机分配端口): " input_port
        if [[ -z "$input_port" ]]; then
            port=$(get_random_port); info "分配未占用端口: $port"; break
        elif is_valid_port "$input_port"; then
            if ! check_port "$input_port"; then error "端口已被占用，请更换"; continue; fi
            port="$input_port"; break
        else error "端口无效"; fi
    done

    while true; do
        read -rp "请输入UUID (直接回车自动生成): " input_uuid
        if [[ -z "${input_uuid:-}" ]]; then
            uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"); break
        elif is_valid_uuid "$input_uuid"; then uuid="$input_uuid"; break
        else error "UUID 格式无效"; fi
    done

    while true; do
        read -rp "请输入SNI域名 (默认:www.amazon.com): " input_domain
        domain=${input_domain:-www.amazon.com}
        if is_valid_domain "$domain"; then break; else error "域名格式无效"; fi
    done

    while true; do
        read -rp "请输入自定义 ShortID (直接回车自动生成 8 位): " input_shortid
        if [[ -z "$input_shortid" ]]; then short_id=$(openssl rand -hex 4); break
        elif is_valid_shortid "$input_shortid"; then short_id="$input_shortid"; break
        else error "必须为偶数位（最长16位）的十六进制字符(0-9, a-f)"; fi
    done

    while true; do
        read -rp "请输入XHTTP路径 (默认: 随机路径): " input_path
        if [[ -z "$input_path" ]]; then
            path="/$(openssl rand -hex 4)"; break
        else
            [[ ! "$input_path" =~ ^\/ ]] && input_path="/$input_path"
            if is_valid_path "$input_path"; then path="$input_path"; break; else error "路径格式无效"; fi
        fi
    done

    mkdir -p "/usr/local/etc/${SERVICE_NAME}"
    keys=$(generate_reality_keys) || return 1
    private_key=$(echo "$keys" | cut -d '|' -f1)

    write_config "$port" "$uuid" "$domain" "$private_key" "$short_id" "$path"
    test_config || return 1
    generate_link
    restart_xray
    show_current_config
}

# ================== 链式代理出口配置 ==================
configure_custom_socks5_outbound() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "请先完成安装！"; return; fi
    local mode current_protocol tmp_file socks_host socks_port socks_user socks_pass
    current_protocol=$(jq -r '.outbounds[0].protocol // "freedom"' "$XRAY_CONFIG" 2>/dev/null)

    echo "---------------------------------------------"
    echo "请选择出口模式 (当前: $([[ "$current_protocol" == "socks" ]] && echo -e "${YELLOW}Socks5${RESET}" || echo -e "${GREEN}直连${RESET}"))"
    echo "1) 直连出口"
    echo "2) Socks5 出口"
    echo "0) 取消"
    echo "---------------------------------------------"
    read -rp "请输入选项 [0-2]: " mode || true
    
    if [[ "$mode" == "1" ]]; then
        tmp_file=$(mktemp)
        jq '.outbounds = [{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}]' "$XRAY_CONFIG" > "$tmp_file"
        mv "$tmp_file" "$XRAY_CONFIG" && chmod 644 "$XRAY_CONFIG"
        restart_xray && info "已成功切换为直连出口！"
        return
    elif [[ "$mode" != "2" ]]; then
        info "已取消"; return
    fi

    read -rp "请输入 Socks5 服务器地址/IP: " socks_host
    [[ -z "$socks_host" ]] && return
    while true; do
        read -rp "请输入 Socks5 端口 (默认: 1080): " socks_port; socks_port=${socks_port:-1080}
        if is_valid_port "$socks_port"; then break; else error "端口无效"; fi
    done
    read -rp "请输入 Socks5 用户名 (若无认证直接留空回车): " socks_user
    socks_pass=""
    if [[ -n "$socks_user" ]]; then read -rs -p "请输入 Socks5 密码: " socks_pass; echo; fi

    tmp_file=$(mktemp)
    if [[ -n "$socks_user" ]]; then
        jq --arg host "$socks_host" --argjson port "$socks_port" --arg user "$socks_user" --arg pass "$socks_pass" \
        '.outbounds = [{"protocol": "socks", "tag": "socks-out", "settings": {"servers": [{"address": $host, "port": $port, "users": [{"user": $user, "pass": $pass}]}]}}]' "$XRAY_CONFIG" > "$tmp_file"
    else
        jq --arg host "$socks_host" --argjson port "$socks_port" \
        '.outbounds = [{"protocol": "socks", "tag": "socks-out", "settings": {"servers": [{"address": $host, "port": $port}]}}]' "$XRAY_CONFIG" > "$tmp_file"
    fi

    mv "$tmp_file" "$XRAY_CONFIG" && chmod 644 "$XRAY_CONFIG"
    restart_xray && info "Socks5出口代理配置成功！"
}

# ================== 修改节点配置逻辑 ==================
modify_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "配置文件不存在"; return 1; fi
    local old_port old_uuid old_domain private_key old_shortid old_path port uuid domain shortid path input_port input_uuid input_domain input_shortid input_path

    old_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
    old_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
    old_domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")
    private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG")
    old_shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")
    old_path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // "/random"' "$XRAY_CONFIG")

    while true; do
        read -rp "请输入新端口 [当前:${old_port}, 回车不修改]: " input_port
        if [[ -z "$input_port" ]]; then port="$old_port"; break
        elif is_valid_port "$input_port"; then
            if [[ "$input_port" != "$old_port" ]] && ! check_port "$input_port"; then error "端口占用"; continue; fi
            port="$input_port"; break
        else error "端口无效"; fi
    done

    read -rp "请输入UUID [当前:${old_uuid}, 回车不修改]: " input_uuid
    uuid=${input_uuid:-$old_uuid}

    read -rp "请输入SNI域名 [当前:${old_domain}, 回车不修改]: " input_domain
    domain=${input_domain:-$old_domain}

    while true; do
        read -rp "请输入ShortID [当前:${old_shortid}, 回车不修改]: " input_shortid
        shortid=${input_shortid:-$old_shortid}
        if is_valid_shortid "$shortid"; then break; else error "格式错误"; fi
    done

    while true; do
        read -rp "请输入XHTTP路径 [当前:${old_path}, 回车不修改]: " input_path
        path=${input_path:-$old_path}
        [[ ! "$path" =~ ^\/ ]] && path="/$path"
        if is_valid_path "$path"; then break; else error "格式错误"; fi
    done

    write_config "$port" "$uuid" "$domain" "$private_key" "$shortid" "$path"
    test_config || return 1
    generate_link
    restart_xray
    info "配置修改成功！"
}

# ================== 其他面板维护命令 ==================
install_xray() {
    info "开始拉取、解压并初始化安装 Xray-core..."
    download_and_extract_xray || return 1
    setup_systemd_service
    configure_xray
}

update_xray() {
    info "更新 Xray-core 二进制内核..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    if download_and_extract_xray && restart_xray; then
        info "升级完成！当前核心版本: $(get_xray_version)"
    else
        error "升级失败，正在尝试恢复..."
        restart_xray
    fi
}

uninstall_xray() {
    warn "即将全盘卸载并清理 vless-xhttp 服务..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    rm -f "$XRAY_BINARY"
    rm -rf "/usr/local/etc/${SERVICE_NAME}" "/usr/local/share/${SERVICE_NAME}" /root/xray_vless_reality.txt
    info "服务已成功卸载并安全清理。"
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


# ================== 菜单系统 ==================
show_menu() {
    clear
    local status version port_show
    status=$(get_xray_status)
    version=$(get_xray_version)
    port_show=$([[ -f "$XRAY_CONFIG" ]] && jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "-")

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    VLESS-Reality-xhttp 面板     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 VLESS-Reality-xhttp${RESET}"
    echo -e "${GREEN} 2. 更新 VLESS-Reality-xhttp${RESET}"
    echo -e "${GREEN} 3. 卸载 VLESS-Reality-xhttp${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 VLESS-Reality-xhttp${RESET}"
    echo -e "${GREEN} 6. 停止 VLESS-Reality-xhttp${RESET}"
    echo -e "${GREEN} 7. 重启 VLESS-Reality-xhttp${RESET}"
    echo -e "${GREEN} 8. 查看服务日志${RESET}"
    echo -e "${GREEN} 9. 查看节点配置${RESET}"
    echo -e "${GREEN}10. 配置Socks5出口${RESET}"
    echo -e "${GREEN}11. SNI域名优选✨${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

pre_check() {
    if [[ $(id -u) -ne 0 ]]; then error "请切换到 root 用户运行"; exit 1; fi
    local missing=0 deps=(jq curl wget openssl ss timeout unzip)
    for cmd in "${deps[@]}"; do if ! command -v "$cmd" >/dev/null 2>&1; then missing=1; break; fi; done
    if [[ "$missing" -eq 1 ]]; then
        info "正在安装必须依赖项..."
        if command -v apt &>/dev/null; then apt update && apt install -y jq curl wget openssl ca-certificates iproute2 unzip || true
        elif command -v dnf &>/dev/null; then dnf install -y jq curl wget openssl ca-certificates iproute2 unzip
        elif command -v yum &>/dev/null; then yum install -y jq curl wget openssl ca-certificates iproute2 unzip; fi
    fi
}

main() {
    pre_check
    while true; do
        show_menu
        local choice=""
        read -r -p $'\033[32m请输入数字选项: \033[0m' choice || true
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
            *) error "无效选项"; pause ;;
        esac
    done
}

main "$@"
