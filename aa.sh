#!/usr/bin/env bash
#
# Xray (VLESS-Encryption + REALITY) Alpine Linux 专属独立控制面板
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eeuo pipefail
export LANG=en_US.UTF-8

# --- 完全隔离的独立路径与服务名称配置 ---
readonly SERVICE_NAME="xray-pqreality"
readonly XRAY_CONFIG="/usr/local/etc/${SERVICE_NAME}/config.json"
readonly XRAY_BINARY="/usr/local/bin/${SERVICE_NAME}"
readonly INIT_SERVICE_PATH="/etc/init.d/${SERVICE_NAME}"
readonly STATE_DIR="/root/proxynode/vlessEncryptionReality"
readonly STATE_FILE="${STATE_DIR}/encryption_info.txt"
readonly REALITY_FILE="${STATE_DIR}/reality_info.txt"  # 存储格式: pbk|sni|sid
readonly LINK_FILE="${STATE_DIR}/vless_link.txt"
readonly REPO_API_URL="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

TMP_DIR=$(mktemp -d -p /tmp xray_alpine_pq.XXXXXX)

# ================== cleanup ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

# 终端规范颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# =========================================================
# 2. 基础底层工具函数 (适配 Alpine 环境)
# =========================================================
info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

get_public_ip() {
    local ip=''
    for url in https://api.ipify.org https://ip.sb https://checkip.amazonaws.com; do
        ip=$(curl -4s --max-time 5 "$url" 2>/dev/null || true)
        [[ -n "$ip" ]] && { echo "$ip"; return; }
    done
    hostname -i | awk '{print $1}' 2>/dev/null || echo "127.0.0.1"
}

get_random_port() {
    local rand_port
    while true; do
        rand_port=$((RANDOM % 55536 + 10000))
        if ! ss -tuln | awk '{print $5}' | grep -qE "[:.]${rand_port}$"; then
            echo "$rand_port"
            return 0
        fi
    done
}

get_installed_version() {
    if [[ -f "$XRAY_BINARY" ]]; then
        "$XRAY_BINARY" version 2>/dev/null | head -n 1 | awk '{print $2}' || echo "未知版本"
    else
        echo "未安装"
    fi
}

get_xray_status() {
    if command -v rc-service &>/dev/null && rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        echo -e "${GREEN}● 运行中 ${RESET}"
    else
        # 通过匹配专属的独立二进制路径来判断进程，不干扰标准 xray 进程
        if pgrep -f "$XRAY_BINARY run" >/dev/null 2>&1; then
            echo -e "${GREEN}● 运行中 ${RESET}"
        else
            echo -e "${RED}● 未运行${RESET}"
        fi
    fi
}

get_current_port_display() {
    if [[ -f "$XRAY_CONFIG" ]]; then
        local port
        port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "")
        echo "${port:- -}"
    else echo "-"; fi
}

generate_uuid() {
    if [ -f "$XRAY_BINARY" ] && [ -x "$XRAY_BINARY" ]; then
        $XRAY_BINARY uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

# =========================================================
# 3. Alpine OpenRC 守护脚本模板
# =========================================================
write_openrc_script() {
    cat << EOF > "$INIT_SERVICE_PATH"
#!/sbin/openrc-run

description="Xray VLESS-Encryption+REALITY Independent Service ($SERVICE_NAME)"
supervisor="supervise-daemon"
command="$XRAY_BINARY"
command_args="run -c $XRAY_CONFIG"

depend() {
    need net
    after firewall
}
EOF
    chmod 755 "$INIT_SERVICE_PATH"
}

# =========================================================
# 4. 核心提取与无缝下载 (改写覆盖路径以实现完全独立)
# =========================================================
download_and_extract_core() {
    local arch
    case "$(uname -m)" in
        'x86_64') arch="64" ;;
        'aarch64' | 'armv8') arch="arm64-v8a" ;;
        *) error "不支持的 Alpine 系统架构: $(uname -m)"; return 1 ;;
    esac

    info "正在自 GitHub 获取 Xray 最新发版矩阵..."
    local release_json="$TMP_DIR/release.json"
    if ! curl -fsSL "$REPO_API_URL" -o "$release_json"; then
        error "获取 GitHub 发行列表失败，请检查网络"
        return 1
    fi

    local download_url
    download_url=$(jq -r --arg arch "Xray-linux-${arch}.zip" '.assets[] | select(.name==$arch) | .browser_download_url' "$release_json")

    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        error "未能在当前架构中匹配到有效的发布包"
        return 1
    fi

    info "开始下载 Xray 核心主程序组件..."
    local zip_file="$TMP_DIR/xray.zip"
    if ! curl -L -f -# "$download_url" -o "$zip_file"; then
        error "下载 Xray 压缩归档失败"
        return 1
    fi

    info "执行纯净解压并重命名隔离目标..."
    mkdir -p "$(dirname "$XRAY_BINARY")"
    # 解压出来后将其命名为专属的二进制文件名，不覆盖原系统可能存在的 /usr/local/bin/xray
    unzip -qjo "$zip_file" "xray" -d "$TMP_DIR"
    mv -f "$TMP_DIR/xray" "$XRAY_BINARY"
    chmod 755 "$XRAY_BINARY"

    # 下载附加 Geo 数据资产 (存放于专属重命名目录中以绝后患)
    readonly GEO_DIR="/usr/local/share/${SERVICE_NAME}"
    mkdir -p "$GEO_DIR"
    local geoip_url=$(jq -r '.assets[] | select(.name=="geoip.dat") | .browser_download_url' "$release_json")
    local geosite_url=$(jq -r '.assets[] | select(.name=="geosite.dat") | .browser_download_url' "$release_json")
    
    [[ -n "$geoip_url" ]] && curl -L -f -s "$geoip_url" -o "${GEO_DIR}/geoip.dat" || true
    [[ -n "$geosite_url" ]] && curl -L -f -s "$geosite_url" -o "${GEO_DIR}/geosite.dat" || true
    
    return 0
}

generate_vless_encryption_config() {
    local vlessenc_output
    vlessenc_output=$($XRAY_BINARY vlessenc 2>/dev/null || true)
    if [ -z "$vlessenc_output" ]; then
        error "生成 VLESS Encryption 配置失败"
        return 1
    fi

    local decryption_config=""
    local encryption_config=""
    local in_mlkem_section=false

    while IFS= read -r line; do
        if [[ "$line" == *"Authentication: ML-KEM-768, Post-Quantum"* ]]; then
            in_mlkem_section=true
            continue
        fi

        if [ "$in_mlkem_section" = true ]; then
            if [[ "$line" == *'"decryption":'* ]]; then
                decryption_config=$(echo "$line" | sed 's/.*"decryption": "\([^"]*\)".*/\1/')
            elif [[ "$line" == *'"encryption":'* ]]; then
                if echo "$line" | grep -q '.*"encryption": "[^"]*"'; then
                    encryption_config=$(echo "$line" | sed 's/.*"encryption": "\([^"]*\)".*/\1/')
                else
                    encryption_config=$(echo "$line" | sed 's/.*"encryption": "\([^"]*\).*/\1/')
                    read -r next_line
                    encryption_config="${encryption_config}${next_line}"
                    encryption_config=$(echo "$encryption_config" | tr -d '"' | tr -d '[:space:]')
                fi
                break
            fi
        fi
    done <<< "$vlessenc_output"

    if [ -z "$decryption_config" ] || [ -z "$encryption_config" ]; then
        error "无法解析 VLESS Encryption 配置。"
        return 1
    fi

    echo "${decryption_config}|${encryption_config}"
}

generate_reality_keys() {
    local key_pair
    key_pair=$($XRAY_BINARY x25519 2>/dev/null || true)
    if [ -z "$key_pair" ]; then
        error "生成 REALITY 密钥对失败！"
        return 1
    fi

    local private_key=$(echo "$key_pair" | grep -i "Private" | sed 's/[[:space:]]//g' | cut -d':' -f2)
    local public_key=$(echo "$key_pair" | grep -E -i "(Public|Password)" | sed 's/[[:space:]]//g' | cut -d':' -f2)

    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        error "无法解析 REALITY 密钥对。"
        return 1
    fi
    echo "${private_key}|${public_key}"
}

# =========================================================
# 4. 面板核心交互与配置文件处理
# =========================================================
write_and_show_config() {
    mkdir -p "$STATE_DIR"
    
    rm -f "$STATE_FILE" "$REALITY_FILE"
    echo "$ENCRYPTION" > "$STATE_FILE"
    echo "${PUBLIC_KEY}|${SNI}|${SHORT_ID}" > "$REALITY_FILE"

    mkdir -p "$(dirname "$XRAY_CONFIG")"
    
    # 注入专属的 assets 路径，确保其读取自己隔离目录下的 geoip.dat / geosite.dat
    jq -n \
        --argjson port "$PORT" \
        --arg uuid "$UUID" \
        --arg decryption "$DECRYPTION" \
        --arg private_key "$PRIVATE_KEY" \
        --arg sni "$SNI" \
        --arg short_id "$SHORT_ID" \
        --arg flow "xtls-rprx-vision" \
        --arg asset_dir "/usr/local/share/${SERVICE_NAME}" \
    '{
        "log": {"loglevel": "warning"},
        "assets": {"dir": $asset_dir},
        "inbounds": [{
            "listen": "::",
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": $uuid, "flow": $flow}],
                "decryption": $decryption
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": ($sni + ":443"),
                    "xver": 0,
                    "serverNames": [$sni],
                    "privateKey": $private_key,
                    "shortIds": [$short_id],
                    "fingerprint": "chrome"
                }
            }
        }],
        "outbounds": [{
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv4v6"
            }
        }]
    }' > "$XRAY_CONFIG"

    chmod 644 "$XRAY_CONFIG"
    
    SERVER_IP=$(get_public_ip)
    cat << EOF >> "$STATE_FILE"
PORT='${PORT}'
UUID='${UUID}'
REMARK='${REMARK}'
SERVER_IP='${SERVER_IP}'
EOF

    # 重启并接管守护体系 (独立 OpenRC/Pid 隔离控制)
    if command -v rc-service &>/dev/null; then
        write_openrc_script
        rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
        rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || true
        sleep 1
        if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
            info "Xray 独立专属服务已通过 OpenRC 启动！"
        else
            error "独立服务启动异常，可选择菜单 8 查看测试输出。"
        fi
    else
        pkill -f "$XRAY_BINARY run" || true
        "$XRAY_BINARY" run -c "$XRAY_CONFIG" >/dev/null 2>&1 &
        info "非 OpenRC 环境，已将独立进程注入后台运行。"
    fi

    showconf
}

# =========================================================
# 5. 主流程控制模块与更新功能
# =========================================================
inst_xray() {
    if [[ -f "$XRAY_CONFIG" ]]; then
        warn "系统检测到本独立面板已存在配置。"
        read -rp "是否强制清空重新部署？ [y/N]: " CONFIRM_REINST
        [[ "$CONFIRM_REINST" != "y" && "$CONFIRM_REINST" != "Y" ]] && return 0
    fi

    info "清理并准备专属的 Alpine 静态组件依赖环境..."
    if [[ ! -f "$XRAY_BINARY" ]]; then
        download_and_extract_core || return 1
    fi

    local encryption_info
    encryption_info=$(generate_vless_encryption_config) || return 1
    DECRYPTION=$(echo "$encryption_info" | cut -d'|' -f1)
    ENCRYPTION=$(echo "$encryption_info" | cut -d'|' -f2)

    local reality_keys
    reality_keys=$(generate_reality_keys) || return 1
    PRIVATE_KEY=$(echo "$reality_keys" | cut -d'|' -f1)
    PUBLIC_KEY=$(echo "$reality_keys" | cut -d'|' -f2)

    local rand_port rand_uuid rand_sid hostname_str default_remark default_sni
    rand_port=$(get_random_port)
    rand_uuid=$(generate_uuid)
    rand_sid=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \t\n')
    hostname_str=$(hostname -s 2>/dev/null || echo "alpine")
    default_remark="${hostname_str}-VLESS-E-Reality"
    default_sni="www.amazon.com"

    echo "---------------------------------------------"
    read -rp "👉 请输入监听端口 (直接回车随机分配: ${rand_port}): " INPUT_PORT
    PORT=${INPUT_PORT:-$rand_port}

    read -rp "👉 请输入UUID (直接回车高强随机: ${rand_uuid}): " INPUT_UUID
    UUID=${INPUT_UUID:-$rand_uuid}

    read -rp "👉 请输入 REALITY SNI 伪装域名 (默认: ${default_sni}): " INPUT_SNI
    SNI=${INPUT_SNI:-$default_sni}

    read -rp "👉 请输入 REALITY Short ID (直接回车使用随机: ${rand_sid}): " INPUT_SID
    SHORT_ID=${INPUT_SID:-$rand_sid}

    read -rp "👉 请输入节点备注名称 (默认: ${default_remark}): " INPUT_REMARK
    REMARK=${INPUT_REMARK:-$default_remark}

    write_and_show_config
}

modify_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "未找到运行的专属配置，请先执行选项 1 安装。"
        return 1
    fi

    info "正在拉取现有后量子密钥与 REALITY 矩阵快照..."
    
    local current_port current_uuid current_decryption current_private_key current_sni current_short_id current_encryption reality_info current_public_key
    current_port=$(jq -r '.inbounds[0].port // empty' "$XRAY_CONFIG" 2>/dev/null)
    current_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$XRAY_CONFIG" 2>/dev/null)
    current_decryption=$(jq -r '.inbounds[0].settings.decryption // empty' "$XRAY_CONFIG" 2>/dev/null)
    current_private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "$XRAY_CONFIG" 2>/dev/null)
    current_sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$XRAY_CONFIG" 2>/dev/null)
    current_short_id=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "$XRAY_CONFIG" 2>/dev/null)
    
    current_encryption=$(head -n 1 "$STATE_FILE" 2>/dev/null || echo "")
    reality_info=$(cat "$REALITY_FILE" 2>/dev/null || echo "")
    current_public_key=$(echo "$reality_info" | cut -d'|' -f1 || true)

    if [[ -z "$current_decryption" || -z "$current_private_key" || -z "$current_encryption" || -z "$current_public_key" ]]; then
        error "加解密快照记录受损，为防节点失联，请执行选项 1 全新独立安装。"
        return 1
    fi

    local current_remark=""
    if [[ -f "$STATE_FILE" ]]; then
        current_remark=$(grep -E "^REMARK=" "$STATE_FILE" | cut -d"'" -f2 || true)
    fi

    echo "---------------------------------------------"
    echo -e "${YELLOW}提示：回车(Enter)保留括号内的当前原设定值${RESET}"
    echo "---------------------------------------------"

    read -rp "👉 修改监听端口 (当前: ${current_port}): " INPUT_PORT
    PORT=${INPUT_PORT:-$current_port}

    read -rp "👉 修改UUID (当前: ${current_uuid}): " INPUT_UUID
    UUID=${INPUT_UUID:-$current_uuid}

    read -rp "👉 修改 REALITY SNI 域名 (当前: ${current_sni}): " INPUT_SNI
    SNI=${INPUT_SNI:-$current_sni}

    read -rp "👉 修改 REALITY Short ID (当前: ${current_short_id}): " INPUT_SID
    SHORT_ID=${INPUT_SID:-$current_short_id}

    read -rp "👉 修改节点备注名称 (当前: ${current_remark:-VLESS-E-REALITY}): " INPUT_REMARK
    REMARK=${INPUT_REMARK:-${current_remark:-VLESS-E-REALITY}}

    DECRYPTION="$current_decryption"
    ENCRYPTION="$current_encryption"
    PRIVATE_KEY="$current_private_key"
    PUBLIC_KEY="$current_public_key"

    write_and_show_config
}

update_xray() {
    if [[ ! -f "$XRAY_BINARY" ]]; then
        error "未检测到已安装的专属核心，无法执行升级。"
        return 1
    fi

    warn "开始获取最新的 GitHub 发行版核心..."
    download_and_extract_core || return 1

    info "重启专属服务组件中..."
    if command -v rc-service &>/dev/null; then
        rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || true
    else
        pkill -f "$XRAY_BINARY run" || true
        "$XRAY_BINARY" run -c "$XRAY_CONFIG" >/dev/null 2>&1 &
    fi
    info "Xray 独立核心已成功平滑迭代完毕。"
}

uninstall_xray() {
    warn "执行彻底卸载专属独立服务与配置数据清洗..."
    if command -v rc-service &>/dev/null; then
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
    else
        pkill -f "$XRAY_BINARY run" || true
    fi
    rm -f "$XRAY_BINARY" "$INIT_SERVICE_PATH"
    rm -rf "$STATE_DIR" "/usr/local/etc/${SERVICE_NAME}" "/usr/local/share/${SERVICE_NAME}"
    info "Xray 专属独立面板与专属核心已完全从系统中卸载。"
}

showconf() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "未发现生效的专属配置文件。"
        return 1
    fi

    local uuid port encryption reality_info public_key sni short_id server_ip current_remark encoded_remark address_for_url vless_link
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
    encryption=$(head -n 1 "$STATE_FILE" 2>/dev/null)
    
    reality_info=$(cat "$REALITY_FILE" 2>/dev/null || echo "")
    public_key=$(echo "$reality_info" | cut -d'|' -f1)
    sni=$(echo "$reality_info" | cut -d'|' -f2)
    short_id=$(echo "$reality_info" | cut -d'|' -f3)

    server_ip=$(get_public_ip)
    
    current_remark="VLESS-E-REALITY"
    if [[ -f "$STATE_FILE" ]]; then
        current_remark=$(grep -E "^REMARK=" "$STATE_FILE" | cut -d"'" -f2 || echo "VLESS-E-REALITY")
    fi

    encoded_remark=$(jq -rn --arg x "$current_remark" '$x|@uri')
    address_for_url=$server_ip
    if [[ $server_ip == *":"* ]]; then address_for_url="[${server_ip}]"; fi

    vless_link="vless://${uuid}@${address_for_url}:${port}?encryption=${encryption}&security=reality&sni=${sni}&sid=${short_id}&fp=chrome&pbk=${public_key}&flow=xtls-rprx-vision&type=tcp#${encoded_remark}"
    echo "$vless_link" > "$LINK_FILE"

    echo -e "${GREEN}====== VLESS-Encryption + Reality 节点信息 ======${RESET}"
    echo -e "${GREEN}服务器公网 IP   :${RESET} ${server_ip}"
    echo -e "${GREEN}服务监听端口     :${RESET} ${port}"
    echo -e "${GREEN}用户 UUID        :${RESET} ${uuid}"
    echo -e "${GREEN}协议与加密形态   :${RESET} VLESS Encryption (native + 0-RTT + ML-KEM-768)"
    echo -e "${GREEN}安全伪装类型     :${RESET} Reality"
    echo -e "${GREEN}流控传输阻断     :${RESET} xtls-rprx-vision (TCP)"
    echo -e "${GREEN}伪装目标 SNI     :${RESET} ${sni}"
    echo -e "${GREEN}REALITY ShortID  :${RESET} ${short_id}"
    echo -e "${GREEN}REALITY 公钥 pbk :${RESET} ${public_key}"
    echo -e "${GREEN}节点自定义备注   :${RESET} ${current_remark}"
    echo -e "${YELLOW}📄 V6VPS 请自行替换分享链接中的 IP 为 V6 格式 ★${RESET}"
    echo "---------------------------------------------"
    echo -e "${GREEN}👉 v2rayN 链接 (已存至 $LINK_FILE):${RESET}"
    echo -e "${YELLOW}${vless_link}${RESET}"
    echo "---------------------------------------------"
}

# =========================================================
# 6. 环境强制自校正
# =========================================================
check_environment() {
    if [[ $(id -u) -ne 0 ]]; then error "请切换至 root 用户运行此面板脚本。" && exit 1; fi

    local deps=(jq curl wget openssl ss awk grep tr unzip)
    local missing=0

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then missing=1 && break; fi
    done

    if ! apk info -e gcompat >/dev/null 2>&1; then missing=1; fi

    if [[ "$missing" -eq 1 ]]; then
        info "正在为您配置 Alpine 环境与后量子兼容依赖 (gcompat / unzip)..."
        apk add --no-cache jq curl wget openssl iproute2 coreutils gcompat bash unzip || true
    fi
}

# =========================================================
# 7. 面板主菜单
# =========================================================
menu() {
    check_environment

    while true; do
        clear
        local status version port_show
        status=$(get_xray_status)
        version=$(get_installed_version)
        port_show=$(get_current_port_display)

        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} Xray VLESS-Encrypt+Reality 面板 ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}状态   :${RESET} $status"
        echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
        echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1. 安装 Xray VLESS-Encrypt+Reality${RESET}"
        echo -e "${GREEN} 2. 更新 Xray${RESET}"
        echo -e "${GREEN} 3. 卸载 Xray${RESET}"
        echo -e "${GREEN} 4. 修改配置${RESET}"
        echo -e "${GREEN} 5. 启动 Xray${RESET}"
        echo -e "${GREEN} 6. 停止 Xray${RESET}"
        echo -e "${GREEN} 7. 重启 Xray${RESET}"
        echo -e "${GREEN} 8. 查看日志${RESET}"
        echo -e "${GREEN} 9. 查看节点配置${RESET}"
        echo -e "${GREEN}10. 配置Socks5出口${RESET}"
        echo -e "${GREEN}11. SNI域名优选✨${RESET}"
        echo -e "${GREEN} 0. 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"

        local choice=""
        read -r -p $'\033[32m请输入选项: \033[0m' choice || true
        [[ -z "$choice" ]] && continue

        case "$choice" in
            1) inst_xray; pause ;;
            2) update_xray; pause ;;
            3) uninstall_xray; pause ;;
            4) modify_config; pause ;;
            5) 
                if command -v rc-service &>/dev/null; then
                    rc-service "$SERVICE_NAME" start && info "独立服务已成功启动！"
                else
                    pkill -f "$XRAY_BINARY run" || true
                    "$XRAY_BINARY" run -c "$XRAY_CONFIG" >/dev/null 2>&1 &
                    info "专属独立进程已在后台拉起！"
                fi
                pause ;;
            6) 
                if command -v rc-service &>/dev/null; then
                    rc-service "$SERVICE_NAME" stop && info "独立服务已成功停止！"
                else
                    pkill -f "$XRAY_BINARY run" && info "专属后台进程已终止！"
                fi
                pause ;;
            7) 
                if command -v rc-service &>/dev/null; then
                    rc-service "$SERVICE_NAME" restart && info "独立服务已成功重启！"
                else
                    pkill -f "$XRAY_BINARY run" || true
                    "$XRAY_BINARY" run -c "$XRAY_CONFIG" >/dev/null 2>&1 &
                fi
                pause ;;
            8) 
                if [[ -f /var/log/messages ]]; then
                    echo -e "${CYAN}--- 最近 50 行专属系统服务日志 ---${RESET}"
                    tail -n 50 /var/log/messages | grep -E "${SERVICE_NAME}|supervise-daemon" || tail -n 50 /var/log/messages
                    echo "--------------------------------------"
                else
                    warn "系统暂未建立全局通用日志追踪：/var/log/messages"
                fi
                if [[ -f "$XRAY_BINARY" && -f "$XRAY_CONFIG" ]]; then
                    "$XRAY_BINARY" run -test -config "$XRAY_CONFIG" || true
                fi
                pause ;;
            9) showconf; pause ;;
            0) exit 0 ;;
            *) error "无效输入，请重新选择。"; sleep 1 ;;
        esac
    done
}

menu "$@"
