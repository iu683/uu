#!/bin/bash

# =========================================================
# Xray VLESS-Encryption (ML-KEM-768) + REALITY 管理脚本
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
readonly SERVICE_NAME="vlessenc-reality"
readonly XRAY_CONFIG="/usr/local/etc/${SERVICE_NAME}/config.json"
readonly XRAY_BINARY="/usr/local/bin/${SERVICE_NAME}"
readonly STATE_DIR="/usr/local/etc/${SERVICE_NAME}/state"
readonly ENC_KEY_FILE="${STATE_DIR}/encryption.key"  # 存储后量子加密客户端用的原生 encryption 密文
readonly REALITY_KEY_FILE="${STATE_DIR}/reality.key" # 存储格式: privkey|pubkey|sni|sid

# 降级备用版本
readonly BACKUP_VERSION="24.12.31"

TMP_DIR=$(mktemp -d -t xray_enc.XXXXXX)

# ================== cleanup ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

# ================== 日志 ==================
info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

# ================== 获取公网IP ==================
get_public_ip() {
    local ip
    for cmd in "curl -4fsSL --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null || true)
            if [[ -n "${ip:-}" ]]; then echo "$ip"; return 0; fi
        done
    done
    return 1
}

# ================== 检查与验证工具 ==================
check_port() {
    local port="$1"
    if ss -tuln | awk '{print $5}' | grep -qE "[:.]${port}$"; then return 1; fi
    return 0
}

is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]; }

get_random_port() {
    local rand_port
    while true; do
        rand_port=$((RANDOM % 55536 + 10000))
        if check_port "$rand_port"; then echo "$rand_port"; return 0; fi
    done
}

is_valid_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; }
is_valid_shortid() {
    local len=${#1}
    [[ "$1" =~ ^[0-9a-fA-F]+$ ]] && (( len % 2 == 0 )) && (( len <= 16 ))
}
is_valid_domain() { [[ "$1" =~ ^([a-zA-Z0-9](-?[a-zA-Z0-9])*\.)+[A-Za-z]{2,}$ ]]; }

get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        *) error "暂不支持的系统架构: $arch"; return 1 ;;
    esac
}

get_latest_version() {
    local latest_version
    info "正在获取 GitHub 最新 Xray 版本号..."
    latest_version=$(curl -fsSL --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
        | jq -r '.tag_name' 2>/dev/null || echo "")
    latest_version="${latest_version#v}"

    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        warn "获取最新版本失败，将使用内置备用版本: v${BACKUP_VERSION}"
        echo "$BACKUP_VERSION"
    else
        info "成功获取最新版本: v${latest_version}"
        echo "$latest_version"
    fi
}

download_and_extract_xray() {
    local arch version
    arch=$(get_arch) || return 1
    version=$(get_latest_version)
    
    local download_url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${arch}.zip"
    local zip_file="$TMP_DIR/xray.zip"
    
    info "正在下载 Xray v${version} (${arch})..."
    if ! curl -L -fsSL "$download_url" -o "$zip_file"; then
        error "下载 Xray 失败，请检查网络。"
        return 1
    fi
    
    mkdir -p "$TMP_DIR/extracted"
    unzip -qo "$zip_file" -d "$TMP_DIR/extracted"
    
    chmod +x "$TMP_DIR/extracted/xray"
    if ! "$TMP_DIR/extracted/xray" help 2>/dev/null | grep -q "vlessenc"; then
        error "拉取的 Xray 核心不支持 vlessenc (后量子加密)，请确保使用的是最新官方原生核心。"
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
Description=Xray VLESS Encryption ML-KEM-768 Reality Service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BINARY} run -config ${XRAY_CONFIG}
Restart=on-failure
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

get_listen_ip() {
    if sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q '= 1'; then echo "0.0.0.0"; else echo "::"; fi
}

test_config() { "$XRAY_BINARY" run -test -config "$XRAY_CONFIG" &>/dev/null; }

restart_xray() {
    systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        info "服务启动成功"
        return 0
    fi
    error "服务启动失败，错误日志："
    journalctl -u "${SERVICE_NAME}" -n 10 --no-pager || true
    return 1
}

generate_vless_encryption_config() {
    info "正在通过后量子算法生成 VLESS-Encryption 密钥对..."
    local vlessenc_output
    vlessenc_output=$("$XRAY_BINARY" vlessenc 2>/dev/null || true)
    if [[ -z "$vlessenc_output" ]]; then
        error "无法调用 xray vlessenc 生成后量子密钥对"
        return 1
    fi

    local decryption_config encryption_config
    decryption_config=$(echo "$vlessenc_output" | jq -c '.decryption // empty' 2>/dev/null)
    encryption_config=$(echo "$vlessenc_output" | jq -r '.encryption // empty' 2>/dev/null)

    if [[ -z "$decryption_config" || -z "$encryption_config" ]]; then
        error "后量子加解密密钥解析失败。"
        return 1
    fi
    mkdir -p "$STATE_DIR"
    echo "$encryption_config" > "$ENC_KEY_FILE"
    echo -n "${decryption_config}"
}

generate_reality_keys() {
    info "正在生成 REALITY x25519 密钥对..."
    local key_pair
    if ! key_pair=$("$XRAY_BINARY" x25519 2>/dev/null); then
        error "REALITY 密钥生成失败"
        return 1
    fi
    local private_key public_key
    private_key=$(echo "$key_pair" | grep -i "Private" | awk -F ': ' '{print $2}' | tr -d '\r ')
    public_key=$(echo "$key_pair" | grep -i "Public" | awk -F ': ' '{print $2}' | tr -d '\r ')
    echo "${private_key}|${public_key}"
}

write_config() {
    local port="$1" uuid="$2" domain="$3" private_key="$4" shortid="$5" decryption_config="$6"
    local listen_ip
    listen_ip=$(get_listen_ip)

    mkdir -p "$(dirname "$XRAY_CONFIG")"

    jq -n \
        --arg listen "$listen_ip" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --argjson decryption "$decryption_config" \
        --arg private_key "$private_key" \
        --arg sni "$domain" \
        --arg short_id "$shortid" \
        '
        {
          "log": { "loglevel": "warning" },
          "inbounds": [
            {
              "listen": $listen,
              "port": $port,
              "protocol": "vless",
              "settings": {
                "clients": [ { "id": $uuid, "flow": "xtls-rprx-vision" } ],
                "decryption": $decryption
              },
              "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                  "show": false,
                  "dest": ($sni + ":443"),
                  "xver": 0,
                  "serverNames": [ $sni ],
                  "privateKey": $private_key,
                  "shortIds": [ $short_id ],
                  "fingerprint": "chrome"
                }
              },
              "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
              }
            }
          ],
          "outbounds": [
            {
              "protocol": "freedom",
              "settings": { "domainStrategy": "UseIPv4v6" }
            }
          ]
        }
        ' > "$XRAY_CONFIG"
        chmod 644 "$XRAY_CONFIG"
}

generate_link() {
    local ip
    if ! ip=$(get_public_ip); then error "获取公网 IP 失败"; return 1; fi

    local uuid port domain shortid public_key encryption
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null)
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null)
    domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG" 2>/dev/null)
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG" 2>/dev/null)
    
    public_key=$(cat "${REALITY_KEY_FILE}" | cut -d'|' -f2 2>/dev/null || echo "")
    encryption=$(cat "${ENC_KEY_FILE}" 2>/dev/null || echo "")

    local display_ip="$ip"
    [[ "$ip" =~ ":" ]] && display_ip="[$ip]"

    local hostname
    hostname=$(hostname -s 2>/dev/null | tr ' ' '_')
    [[ -z "$hostname" ]] && hostname="Xray"

    local encoded_remark
    encoded_remark=$(jq -rn --arg x "${hostname}-VLESS-Enc-Reality" '$x|@uri')

    cat > /root/xray_vless_reality.txt <<EOF
vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=${encryption}&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#${encoded_remark}
EOF
}

show_current_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "配置文件不存在"; return; fi

    local ip uuid port domain shortid public_key encryption outbound_mode
    ip=$(get_public_ip || echo "未知")
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null)
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null)
    domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG" 2>/dev/null)
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG" 2>/dev/null)
    public_key=$(cat "${REALITY_KEY_FILE}" | cut -d'|' -f2 2>/dev/null || echo "未知")
    encryption=$(cat "${ENC_KEY_FILE}" 2>/dev/null || echo "未知")
    
    local current_protocol
    current_protocol=$(jq -r '.outbounds[0].protocol // "freedom"' "$XRAY_CONFIG" 2>/dev/null)
    outbound_mode=$([[ "$current_protocol" == "socks" ]] && echo "Socks5 链式代理" || echo "直连 (Freedom)")

    echo -e "${GREEN}====== 当前 VLESS-Encryption + REALITY 配置 ======${RESET}"
    echo -e "${YELLOW}IP地址      : ${ip}${RESET}"
    echo -e "${YELLOW}监听端口    : ${port}${RESET}"
    echo -e "${YELLOW}用户 UUID   : ${uuid}${RESET}"
    echo -e "${YELLOW}协议安全形态: VLESS Encryption (Native + 0-RTT + ML-KEM-768)${RESET}"
    echo -e "${YELLOW}REALITY SNI : ${domain}${RESET}"
    echo -e "${YELLOW}REALITY 公钥: ${public_key}${RESET}"
    echo -e "${YELLOW}ShortID     : ${shortid}${RESET}"
    echo -e "${YELLOW}出口模式    : ${outbound_mode}${RESET}"
    echo

    if [[ -f /root/xray_vless_reality.txt ]]; then
        echo -e "${GREEN}====== 👉 订阅链接 ======${RESET}"
        cat /root/xray_vless_reality.txt
    fi
}

configure_xray() {
    info "开始配置后量子加密节点..."
    local port uuid domain short_id decryption_config private_key public_key

    while true; do
        read -rp "请输入端口 (直接回车随机分配端口): " input_port
        if [[ -z "$input_port" ]]; then
            port=$(get_random_port); info "已为您随机分配未被占用端口: $port"; break
        elif is_valid_port "$input_port"; then
            if ! check_port "$input_port"; then error "端口 ${input_port} 已被占用，请重新输入。"; continue; fi
            port="$input_port"; break
        else error "端口无效"; fi
    done

    while true; do
        read -rp "请输入UUID (默认:自动生成): " input_uuid
        if [[ -z "${input_uuid:-}" ]]; then
            uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "7415d2b8-1454-4da8-963b-4663e8322851"); break
        elif is_valid_uuid "$input_uuid"; then uuid="$input_uuid"; break
        else error "UUID 格式无效"; fi
    done

    while true; do
        read -rp "请输入SNI域名 (默认:www.amazon.com): " input_domain
        domain=${input_domain:-www.amazon.com}
        if is_valid_domain "$domain"; then break; else error "域名格式无效"; fi
    done

    while true; do
        read -rp "请输入自定义 ShortID (直接回车自动生成 8 位十六进制指纹): " input_shortid
        if [[ -z "$input_shortid" ]]; then
            short_id=$(openssl rand -hex 4); break
        elif is_valid_shortid "$input_shortid"; then short_id="$input_shortid"; break
        else error "ShortID 无效！必须为偶数位（最长16位）的十六进制字符。"; fi
    done

    decryption_config=$(generate_vless_encryption_config) || return 1

    local r_keys
    r_keys=$(generate_reality_keys) || return 1
    private_key=$(echo "$r_keys" | cut -d '|' -f1)
    public_key=$(echo "$r_keys" | cut -d '|' -f2)
    
    echo "${private_key}|${public_key}|${domain}|${short_id}" > "${REALITY_KEY_FILE}"

    write_config "$port" "$uuid" "$domain" "$private_key" "$short_id" "$decryption_config"
    test_config || return 1
    generate_link
    restart_xray
    show_current_config
}

configure_custom_socks5_outbound() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "错误: 未安装，无法配置出口模式。"; return; fi
    local mode current_protocol tmp_file
    current_protocol=$(jq -r '.outbounds[0].protocol // "freedom"' "$XRAY_CONFIG" 2>/dev/null)

    echo "---------------------------------------------"
    echo "请选择出口模式："
    echo -e "当前模式: $( [[ "$current_protocol" == "socks" ]] && echo -e "${YELLOW}Socks5${RESET}" || echo -e "${GREEN}直连${RESET}" )"
    echo "1) 直连出口"
    echo "2) Socks5 出口"
    echo "0) 取消"
    echo "---------------------------------------------"

    read -rp "请输入选项 [0-2]: " mode || true
    case "$mode" in
        1)
            tmp_file=$(mktemp)
            jq '.outbounds = [{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}]' "$XRAY_CONFIG" > "$tmp_file"
            mv "$tmp_file" "$XRAY_CONFIG" && chmod 644 "$XRAY_CONFIG"
            restart_xray && info "已成功切换为直连出口！"
            ;;
        2)
            info "配置自定义 Socks5 出口代理..."
            local socks_host socks_port socks_user socks_pass
            read -rp "请输入 Socks5 服务器地址/IP: " socks_host || true
            [[ -z "$socks_host" ]] && return
            while true; do
                read -rp "请输入 Socks5 端口 (默认: 1080): " socks_port || true
                socks_port=${socks_port:-1080}
                if is_valid_port "$socks_port"; then break; else error "端口无效"; fi
            done
            read -rp "请输入 Socks5 用户名 (直接空回车表示无密认证): " socks_user || true
            socks_pass=""
            [[ -n "$socks_user" ]] && { read -rs -p "请输入 Socks5 密码: " socks_pass || true; echo; }

            tmp_file=$(mktemp)
            if [[ -n "$socks_user" ]]; then
                jq --arg host "$socks_host" --argjson port "$socks_port" --arg user "$socks_user" --arg pass "$socks_pass" \
                '.outbounds = [{"protocol": "socks", "tag": "custom-socks5-out", "settings": {"servers": [{"address": $host, "port": $port, "users": [{"user": $user, "pass": $pass}]}]}}]' \
                "$XRAY_CONFIG" > "$tmp_file"
            else
                jq --arg host "$socks_host" --argjson port "$socks_port" \
                '.outbounds = [{"protocol": "socks", "tag": "custom-socks5-out", "settings": {"servers": [{"address": $host, "port": $port}]}}]' \
                "$XRAY_CONFIG" > "$tmp_file"
            fi
            mv "$tmp_file" "$XRAY_CONFIG" && chmod 644 "$XRAY_CONFIG"
            restart_xray && info "已成功切换为 Socks5 出口代理！"
            ;;
        *) info "已取消操作。" ;;
    esac
}

install_xray() {
    info "开始拉取后量子加密定制版 Xray 环境..."
    download_and_extract_xray || return 1
    setup_systemd_service
    configure_xray
    info "后量子安全节点部署全流程完成！"
}

update_xray() {
    info "开始平滑更新 Xray 核心主程序..."
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    fi
    if ! download_and_extract_xray; then
        error "下载失败，正在回滚重启旧主程序..."
        restart_xray; return 1
    fi
    restart_xray && info "更新成功！当前版本: $(get_xray_version)"
}

modify_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then error "配置文件不存在"; return 1; fi

    local old_port old_uuid old_domain old_shortid private_key decryption_config
    old_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null)
    old_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null)
    old_domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG" 2>/dev/null)
    private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG" 2>/dev/null)
    old_shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG" 2>/dev/null)
    decryption_config=$(jq -c '.inbounds[0].settings.decryption' "$XRAY_CONFIG" 2>/dev/null)

    local port uuid domain shortid
    while true; do
        read -rp "请输入新端口 [当前:${old_port}, 回车不修改]: " input_port
        if [[ -z "$input_port" ]]; then port="$old_port"; break
        elif [[ "${input_port,,}" == "rand" ]]; then port=$(get_random_port); break
        elif is_valid_port "$input_port"; then
            if [[ "$input_port" != "$old_port" ]] && ! check_port "$input_port"; then error "端口占用"; continue; fi
            port="$input_port"; break
        else error "端口无效"; fi
    done

    read -rp "请输入UUID [当前:${old_uuid}, 回车不修改]: " input_uuid
    uuid=${input_uuid:-$old_uuid}

    read -rp "请输入SNI域名 [当前:${old_domain}, 回车不修改]: " input_domain
    domain=${input_domain:-$old_domain}

    read -rp "请输入ShortID [当前:${old_shortid}, 回车不修改]: " input_shortid
    shortid=${input_shortid:-$old_shortid}

    write_config "$port" "$uuid" "$domain" "$private_key" "$shortid" "$decryption_config"
    test_config || return 1
    
    # 同步把修改后的 sni 与 shortid 刷回本地文件，防止生成失效链接
    local pbk
    pbk=$(cat "${REALITY_KEY_FILE}" | cut -d'|' -f2 2>/dev/null || echo "")
    echo "${private_key}|${pbk}|${domain}|${shortid}" > "${REALITY_KEY_FILE}"
    
    generate_link
    restart_xray
    info "配置平滑修改完毕！"
}

uninstall_xray() {
    warn "即将完全移除后量子加密 ${SERVICE_NAME} 安全服务..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    rm -f "$XRAY_BINARY"
    rm -rf "/usr/local/etc/${SERVICE_NAME}"
    rm -rf "/usr/local/share/${SERVICE_NAME}"
    rm -f /root/xray_vless_reality.txt
    info "卸载彻底清理完成。"
}

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
        if [[ -f "$XRAY_CONFIG" ]]; then
            read -rp "检测到安全节点已安装，是否将优选 SNI 自动应用到配置？[y/N]: " sync_sni
            if [[ "$sync_sni" =~ ^[Yy]$ ]]; then
                local tmp_file=$(mktemp)
                jq --arg sni "$BEST_SNI" '.inbounds[0].streamSettings.realitySettings.serverNames = [$sni] | .inbounds[0].streamSettings.realitySettings.dest = ($sni + ":443")' "$XRAY_CONFIG" > "$tmp_file"
                mv "$tmp_file" "$XRAY_CONFIG" && chmod 644 "$XRAY_CONFIG"
                
                # 联动更新文件
                local priv pbk shortid
                priv=$(cat "${REALITY_KEY_FILE}" | cut -d'|' -f1 2>/dev/null || echo "")
                pbk=$(cat "${REALITY_KEY_FILE}" | cut -d'|' -f2 2>/dev/null || echo "")
                shortid=$(cat "${REALITY_KEY_FILE}" | cut -d'|' -f4 2>/dev/null || echo "")
                echo "${priv}|${pbk}|${BEST_SNI}|${shortid}" > "${REALITY_KEY_FILE}"
                
                generate_link
                restart_xray && info "最优 SNI 已一键应用并重新生成链接！"
            fi
        fi
        return 0
    else
        warn "未找到可用 SNI"
        return 1
    fi
}

show_menu() {
    clear
    local status version port_show
    status=$(get_xray_status)
    version=$(get_xray_version)
    port_show=$([[ -f "$XRAY_CONFIG" ]] && jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "-")

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   Xray Encryption+Reality 面板   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Encryption+Reality${RESET}" 
    echo -e "${GREEN}2. 更新 Xray${RESET}"
    echo -e "${GREEN}3. 卸载 Xray${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Xray${RESET}"
    echo -e "${GREEN}6. 停止 Xray${RESET}"
    echo -e "${GREEN}7. 重启 Xray${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}10. 配置Socks5出口${RESET}"
    echo -e "${GREEN}11. SNI域名优选✨${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

install_dependencies() {
    if command -v apt &>/dev/null; then
        apt update && apt install -y jq curl wget openssl ca-certificates iproute2 coreutils unzip || true
    elif command -v dnf &>/dev/null; then
        dnf install -y jq curl wget openssl ca-certificates iproute2 coreutils unzip
    elif command -v yum &>/dev/null; then
        yum install -y jq curl wget openssl ca-certificates iproute2 coreutils unzip
    else
        error "未检出支持的系统包管理器，请手动补充安装: jq, curl, openssl, unzip"
        exit 1
    fi
}

pre_check() {
    [[ $(id -u) -ne 0 ]] && { error "错误: 请提升至 root 权限账户运行此面板。"; exit 1; }
    local deps=(jq curl wget openssl ss timeout unzip) missing=0
    for cmd in "${deps[@]}"; do if ! command -v "$cmd" >/dev/null 2>&1; then missing=1; break; fi; done
    [[ "$missing" -eq 1 ]] && { info "检测到系统缺失底层运行环境，启动自动化自愈安装..."; install_dependencies; }
}

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
            6) systemctl stop "${SERVICE_NAME}" &>/dev/null || true; info "进程已挂起"; pause ;;
            7) restart_xray; pause ;;
            8) journalctl -u "${SERVICE_NAME}" -e --no-pager || true; pause ;;
            9) show_current_config; pause ;;
            10) configure_custom_socks5_outbound; pause ;;
            11) select_best_sni; pause ;;
            0) exit 0 ;;
            *) error "无效选择"; pause ;;
        esac
    done
}

main "$@"
