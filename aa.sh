#!/usr/bin/env bash
#
# Xray VLESS-Encryption Alpine Linux 专属控制面板
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eeuo pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_BINARY="/usr/local/bin/xray"
readonly INIT_SERVICE_PATH="/etc/init.d/xray"
readonly STATE_FILE="/root/xray_encryption_info.txt"
readonly LINK_FILE="/root/xray_vless_encryption_link.txt"
readonly REPO_API_URL="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

TMP_DIR=$(mktemp -d -p /tmp xray_alpine.XXXXXX)

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

get_sb_status() {
    if command -v rc-service &>/dev/null && rc-service xray status >/dev/null 2>&1; then
        echo -e "${GREEN}● 运行中 ${RESET}"
    else
        if pgrep -f "$XRAY_BINARY run" >/dev/null 2>&1; then
            echo -e "${GREEN}● 运行中 (Pidmode)${RESET}"
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
# 3. Alpine OpenRC 守护脚本模版
# =========================================================
write_openrc_script() {
    cat << 'EOF' > "$INIT_SERVICE_PATH"
#!/sbin/openrc-run

description="Xray VLESS-Encryption Service"
supervisor="supervise-daemon"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"

depend() {
    need net
    after firewall
}
EOF
    chmod 755 "$INIT_SERVICE_PATH"
}

# =========================================================
# 4. 核心提取与无缝下载 (摆脱官方 Systemd 脚本束缚)
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

    info "执行纯净解压覆盖..."
    mkdir -p "$(dirname "$XRAY_BINARY")"
    unzip -qjo "$zip_file" "xray" -d "$(dirname "$XRAY_BINARY")"
    chmod 755 "$XRAY_BINARY"

    # 下载附加 Geo 数据资产
    mkdir -p /usr/local/share/xray
    local geoip_url=$(jq -r '.assets[] | select(.name=="geoip.dat") | .browser_download_url' "$release_json")
    local geosite_url=$(jq -r '.assets[] | select(.name=="geosite.dat") | .browser_download_url' "$release_json")
    
    [[ -n "$geoip_url" ]] && curl -L -f -s "$geoip_url" -o /usr/local/share/xray/geoip.dat || true
    [[ -n "$geosite_url" ]] && curl -L -f -s "$geosite_url" -o /usr/local/share/xray/geosite.dat || true
    
    return 0
}

generate_vless_encryption_config() {
    local vlessenc_output
    vlessenc_output=$($XRAY_BINARY vlessenc 2>/dev/null || true)
    if [ -z "$vlessenc_output" ]; then
        error "调用核心生成 VLESS Encryption 配置失败"
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
        error "无法解析内嵌的 VLESS Encryption 后量子证书拓扑"
        return 1
    fi

    echo "${decryption_config}|${encryption_config}"
}

# =========================================================
# 5. 面板核心业务逻辑层
# =========================================================
write_and_show_config() {
    rm -f "$STATE_FILE"
    echo "$ENCRYPTION" > "$STATE_FILE"

    mkdir -p "$(dirname "$XRAY_CONFIG")"
    jq -n \
        --argjson port "$PORT" \
        --arg uuid "$UUID" \
        --arg decryption "$DECRYPTION" \
        --arg flow "xtls-rprx-vision" \
    '{
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "listen": "::",
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": $uuid, "flow": $flow}],
                "decryption": $decryption
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

    # 重启并接管守护体系 (OpenRC/Pid双路兼容)
    if command -v rc-service &>/dev/null; then
        write_openrc_script
        rc-update add xray default >/dev/null 2>&1 || true
        rc-service xray restart >/dev/null 2>&1 || true
        sleep 1
        if rc-service xray status >/dev/null 2>&1; then
            info "Xray VLESS-Encryption 已通过 OpenRC 成功拉起！"
        else
            error "服务异常闪退，可选择选项 8 打印错误日志"
        fi
    else
        pkill -f "$XRAY_BINARY run" || true
        "$XRAY_BINARY" run -c "$XRAY_CONFIG" >/dev/null 2>&1 &
        info "未在系统发现 OpenRC 框架，已直接注入后台独立进程常驻。"
    fi

    showconf
}

inst_singbox() {
    if [[ -f "$XRAY_CONFIG" ]]; then
        warn "系统已检测到历史残留配置。"
        read -rp "是否强制全干洗重新部署？(历史数据会丢失) [y/N]: " CONFIRM_REINST
        [[ "$CONFIRM_REINST" != "y" && "$CONFIRM_REINST" != "Y" ]] && return 0
    fi

    info "🧹 正在整理 Alpine 静态底层组件依赖..."
    if [[ ! -f "$XRAY_BINARY" ]]; then
        download_and_extract_core || return 1
    fi

    local encryption_info
    encryption_info=$(generate_vless_encryption_config) || return 1

    DECRYPTION=$(echo "$encryption_info" | cut -d'|' -f1)
    ENCRYPTION=$(echo "$encryption_info" | cut -d'|' -f2)

    local rand_port
    rand_port=$(get_random_port)
    local rand_uuid
    rand_uuid=$(generate_uuid)
    local hostname_str
    hostname_str=$(hostname -s 2>/dev/null || echo "alpine-vless")
    local default_remark="${hostname_str}-VLESS-E"

    echo "---------------------------------------------"
    read -rp "👉 请输入监听端口 (默认随机分配: ${rand_port}): " INPUT_PORT
    PORT=${INPUT_PORT:-$rand_port}

    read -rp "👉 请输入UUID (默认高强随机: ${rand_uuid}): " INPUT_UUID
    UUID=${INPUT_UUID:-$rand_uuid}

    read -rp "👉 请输入节点备注名称 (默认: ${default_remark}): " INPUT_REMARK
    REMARK=${INPUT_REMARK:-$default_remark}

    write_and_show_config
}

modify_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "未找到正在运行的配置文件，请先执行选项 1 初始化。"
        return 1
    fi

    info "正在拉取现有后量子密钥与加密矩阵快照..."
    
    local current_port current_uuid current_decryption current_encryption
    current_port=$(jq -r '.inbounds[0].port // empty' "$XRAY_CONFIG" 2>/dev/null)
    current_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$XRAY_CONFIG" 2>/dev/null)
    current_decryption=$(jq -r '.inbounds[0].settings.decryption // empty' "$XRAY_CONFIG" 2>/dev/null)
    current_encryption=$(head -n 1 "$STATE_FILE" 2>/dev/null || echo "")

    if [[ -z "$current_decryption" || -z "$current_encryption" ]]; then
        error "快照损坏或缺失加解密对称密钥对，建议通过选项 1 重置！"
        return 1
    fi

    local current_remark=""
    if [[ -f "$STATE_FILE" ]]; then
        current_remark=$(grep -E "^REMARK=" "$STATE_FILE" | cut -d"'" -f2 || true)
    fi

    echo "---------------------------------------------"
    echo -e "${YELLOW}提示：回车(Enter)默认保留括弧内当前原值${RESET}"
    echo "---------------------------------------------"

    read -rp "👉 修改监听端口 (当前: ${current_port}): " INPUT_PORT
    PORT=${INPUT_PORT:-$current_port}

    read -rp "👉 修改UUID (当前: ${current_uuid}): " INPUT_UUID
    UUID=${INPUT_UUID:-$current_uuid}

    read -rp "👉 修改节点备注名称 (当前: ${current_remark:-VLESS-E}): " INPUT_REMARK
    REMARK=${INPUT_REMARK:-${current_remark:-VLESS-E}}

    DECRYPTION="$current_decryption"
    ENCRYPTION="$current_encryption"

    write_and_show_config
}

update_singbox() {
    if [[ ! -f "$XRAY_BINARY" ]]; then
        error "未检测到核心，无法更新。"
        return 1
    fi

    warn "准备开始平滑拉取 GitHub 最新发行核心..."
    download_and_extract_core || return 1

    info "重载进程..."
    if command -v rc-service &>/dev/null; then
        rc-service xray restart >/dev/null 2>&1 || true
    else
        pkill -f "$XRAY_BINARY run" || true
        "$XRAY_BINARY" run -c "$XRAY_CONFIG" >/dev/null 2>&1 &
    fi
    info "Xray 核心已成功平滑迭代完毕。"
}

uninstall_singbox() {
    warn "执行彻底清洗与数据解绑..."
    if command -v rc-service &>/dev/null; then
        rc-service xray stop >/dev/null 2>&1 || true
        rc-update del xray default >/dev/null 2>&1 || true
    else
        pkill -f "$XRAY_BINARY run" || true
    fi
    rm -f "$XRAY_BINARY" "$INIT_SERVICE_PATH" "$LINK_FILE" "$STATE_FILE"
    rm -rf /usr/local/etc/xray /usr/local/share/xray
    info "全量环境已清洗干净。"
}

showconf() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "无基础配置记录。"
        return 1
    fi

    local uuid port encryption server_ip current_remark
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
    encryption=$(head -n 1 "$STATE_FILE" 2>/dev/null)
    server_ip=$(get_public_ip)
    
    current_remark="VLESS-E"
    if [[ -f "$STATE_FILE" ]]; then
        current_remark=$(grep -E "^REMARK=" "$STATE_FILE" | cut -d"'" -f2 || echo "VLESS-E")
    fi

    local encoded_remark
    encoded_remark=$(jq -rn --arg x "$current_remark" '$x|@uri')
    local address_for_url=$server_ip
    if [[ $server_ip == *":"* ]]; then address_for_url="[${server_ip}]"; fi

    local vless_link="vless://${uuid}@${address_for_url}:${port}?encryption=${encryption}&flow=xtls-rprx-vision&type=tcp&security=none#${encoded_remark}"
    echo "$vless_link" > "$LINK_FILE"

    echo -e "${GREEN}====== VLESS-Encryption 节点配置信息 ======${RESET}"
    echo -e "${GREEN}服务器公网 IP :${RESET} ${server_ip}"
    echo -e "${GREEN}服务监听端口   :${RESET} ${port}"
    echo -e "${GREEN}用户 UUID      :${RESET} ${uuid}"
    echo -e "${GREEN}协议与加密     :${RESET} VLESS Encryption (native + 0-RTT + ML-KEM-768)"
    echo -e "${GREEN}推荐底层流控   :${RESET} xtls-rprx-vision"
    echo -e "${GREEN}节点自定义备注 :${RESET} ${current_remark}"
    echo -e "${YELLOW}📄 V6VPS 请自行替换 IP 地址为 V6 ★${RESET}"
    echo "---------------------------------------------"
    echo -e "${GREEN}👉 v2rayN 分享链接 (已存至 $LINK_FILE):${RESET}"
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
        info "安装 Alpine 专属环境依赖与后量子兼容层库 (gcompat / unzip)..."
        apk add --no-cache jq curl wget openssl iproute2 coreutils gcompat bash unzip || true
    fi
}

# =========================================================
# 7. 主循环菜单
# =========================================================
menu() {
    check_environment

    while true; do
        clear
        local status version port_show
        status=$(get_sb_status)
        version=$(get_installed_version)
        port_show=$(get_current_port_display)

        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}    Xray VLESS-Encryption 面板   ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}状态   :${RESET} $status"
        echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
        echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}1. 安装 VLESS-Encryption${RESET}" 
        echo -e "${GREEN}2. 更新 VLESS-Encryption${RESET}"
        echo -e "${GREEN}3. 卸载 VLESS-Encryption${RESET}"
        echo -e "${GREEN}4. 修改配置${RESET}"
        echo -e "${GREEN}5. 启动 VLESS-Encryption${RESET}"
        echo -e "${GREEN}6. 停止 VLESS-Encryption${RESET}"
        echo -e "${GREEN}7. 重启 VLESS-Encryption${RESET}"
        echo -e "${GREEN}8. 查看日志${RESET}"
        echo -e "${GREEN}9. 查看节点配置${RESET}"
        echo -e "${GREEN}0. 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"

        local choice=""
        read -r -p $'\033[32m请输入选项: \033[0m' choice || true
        [[ -z "$choice" ]] && continue

        case "$choice" in
            1) inst_singbox; pause ;;
            2) update_singbox; pause ;;
            3) uninstall_singbox; pause ;;
            4) modify_config; pause ;;
            5) 
                if command -v rc-service &>/dev/null; then
                    rc-service xray start && info "服务已成功启动！"
                else
                    pkill -f "$XRAY_BINARY run" || true
                    "$XRAY_BINARY" run -c "$XRAY_CONFIG" >/dev/null 2>&1 &
                    info "托管守护开启"
                fi
                pause ;;
            6) 
                if command -v rc-service &>/dev/null; then
                    rc-service xray stop && info "服务已成功停止！"
                else
                    pkill -f "$XRAY_BINARY run" && info "后台进程已终止！"
                fi
                pause ;;
            7) 
                if command -v rc-service &>/dev/null; then
                    rc-service xray restart && info "服务已成功重启！"
                else
                    pkill -f "$XRAY_BINARY run" || true
                    "$XRAY_BINARY" run -c "$XRAY_CONFIG" >/dev/null 2>&1 &
                fi
                pause ;;
            8) 
                if [[ -f /var/log/messages ]]; then
                    echo -e "${CYAN}--- 最近 50 行核心系统相关日志 ---${RESET}"
                    tail -n 50 /var/log/messages | grep -E 'xray|supervise-daemon' || tail -n 50 /var/log/messages
                    echo "--------------------------------------"
                else
                    warn "系统暂未生成全局日志快照：/var/log/messages"
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
