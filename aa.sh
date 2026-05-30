#!/usr/bin/env bash
#
# Xray (VLESS-Encryption) 控制面板
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eeuo pipefail
export LANG=en_US.UTF-8

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# ================== 基础变量 ==================
readonly SERVICE_NAME="vlessenc"
readonly XRAY_CONFIG="/usr/local/etc/${SERVICE_NAME}/config.json"
readonly XRAY_BINARY="/usr/local/bin/${SERVICE_NAME}"
readonly STATE_FILE="/usr/local/etc/${SERVICE_NAME}/xray_encryption_info.txt"
readonly LINK_FILE="/root/proxynode/encryption/xray_vless_encryption_link.txt"

# 降级备用版本（当自动获取最新版本失败时使用）
readonly BACKUP_VERSION="26.3.27"

TMP_DIR=$(mktemp -d -t xray_enc.XXXXXX)

# ================== cleanup ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

# ================== 日志与交互 ==================
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
            if [[ -n "${ip:-}" ]]; then
                echo "$ip"
                return 0
            fi
        done
    done

    for cmd in "curl -6fsSL --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ipv6.ip.sb"; do
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
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
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
    local latest_version
    info "正在获取 GitHub 最新 Xray 版本号..."
    
    latest_version=$(curl -fsSL --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
        | jq -r '.tag_name' 2>/dev/null || echo "")
        
    latest_version="${latest_version#v}"

    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        warn "通过 GitHub API 获取最新版本失败，将使用内置备用版本: v${BACKUP_VERSION}"
        echo "$BACKUP_VERSION"
    else
        info "成功获取最新版本: v${latest_version}"
        echo "$latest_version"
    fi
}

# ================== 从GitHub下载并解压Xray ==================
download_and_extract_xray() {
    local arch version
    arch=$(get_arch) || return 1
    version=$(get_latest_version)
    
    local download_url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${arch}.zip"
    local zip_file="$TMP_DIR/xray.zip"
    
    info "正在从 GitHub 下载 Xray v${version} (${arch})..."
    if ! curl -L -fsSL "$download_url" -o "$zip_file"; then
        error "从 GitHub 下载 Xray 失败，请检查网络连接。"
        return 1
    fi
    
    info "正在解压..."
    mkdir -p "$TMP_DIR/extracted"
    if ! unzip -qo "$zip_file" -d "$TMP_DIR/extracted"; then
        error "解压 Xray 压缩包失败，请确保系统已安装 unzip。"
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

# ================== 配置 Systemd 服务 ==================
setup_systemd_service() {
    info "配置 Systemd 服务 [${SERVICE_NAME}]..."
    
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Xray VLESS Encryption Service
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

# ================== 获取服务状态与基础参数 ==================
get_xray_status() {
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        echo -e "${GREEN}● 运行中${RESET}"
    else
        echo -e "${RED}● 未运行${RESET}"
    fi
}

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

get_listen_ip() {
    if sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q '= 1'; then
        echo "0.0.0.0"
    else
        echo "::"
    fi
}

test_config() {
    if "$XRAY_BINARY" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        info "Configuration OK"
        return 0
    fi
    error "配置测试失败"
    return 1
}

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

# ================== 解析与提取 VLESS 加密对 ==================
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
                    encryption_config=$(echo "$line" | sed 's/.*"encryption": "\([^"]*\)..*/\1/')
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

# ================== 写底层配置 ==================
write_config() {
    local port="$1"
    local uuid="$2"
    local decryption="$3"
    
    local listen_ip
    listen_ip=$(get_listen_ip)

    mkdir -p "$(dirname "$XRAY_CONFIG")"

    jq -n \
        --arg listen "${listen_ip}" \
        --argjson port "${port}" \
        --arg uuid "${uuid}" \
        --arg decryption "${decryption}" \
        --arg flow "xtls-rprx-vision" \
    '{
      "log": {"loglevel": "warning"},
      "inbounds": [{
        "listen": $listen,
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
}

# ================== 生成分享链接 ==================
generate_link() {
    mkdir -p "$(dirname "$LINK_FILE")"
    local ip
    if ! ip=$(get_public_ip); then
        error "获取公网 IP 失败"
        return 1
    fi

    local uuid port encryption remark
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null || echo "error")
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "443")
    
    encryption=$(head -n 1 "$STATE_FILE" 2>/dev/null || echo "")
    remark=$(grep -E "^REMARK=" "$STATE_FILE" | cut -d"'" -f2 2>/dev/null || echo "VLESS-Enc")

    local display_ip="$ip"
    [[ "$ip" =~ ":" ]] && display_ip="[$ip]"

    local encoded_remark
    encoded_remark=$(jq -rn --arg x "$remark" '$x|@uri')

    cat > "$LINK_FILE" <<EOF
vless://${uuid}@${display_ip}:${port}?encryption=${encryption}&flow=xtls-rprx-vision&type=tcp&security=none#${encoded_remark}
EOF
}

# ================== 显示配置 ==================
show_current_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "配置文件不存在"
        return
    fi

    local ip uuid port encryption remark outbound_mode
    ip=$(get_public_ip || echo "未知")
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
    
    encryption=$(head -n 1 "$STATE_FILE" 2>/dev/null || echo "未知")
    remark=$(grep -E "^REMARK=" "$STATE_FILE" | cut -d"'" -f2 2>/dev/null || echo "VLESS-E")
    
    local current_protocol
    current_protocol=$(jq -r '.outbounds[0].protocol // "freedom"' "$XRAY_CONFIG" 2>/dev/null || echo "freedom")
    if [[ "$current_protocol" == "socks" ]]; then
        outbound_mode="Socks5 链式代理"
    else
        outbound_mode="直连 (Freedom)"
    fi

    echo -e "${GREEN}====== VLESS-Encryption 节点配置信息 ======${RESET}"
    echo -e "${YELLOW}服务器公网 IP  : ${ip}${RESET}"
    echo -e "${YELLOW}服务监听端口    : ${port}${RESET}"
    echo -e "${YELLOW}用户 UUID       : ${uuid}${RESET}"
    echo -e "${YELLOW}协议与加密      : VLESS Encryption (native + 0-RTT + ML-KEM-768)${RESET}"
    echo -e "${YELLOW}推荐底层流控    : xtls-rprx-vision${RESET}"
    echo -e "${YELLOW}出口模式        : ${outbound_mode}${RESET}"
    echo -e "${YELLOW}节点自定义备注  : ${remark}${RESET}"
    echo -e "${YELLOW}📄 V6VPS 请自行替换分享链接中的 IP 地址为 V6 ★${RESET}"
    echo

    if [[ -f "$LINK_FILE" ]]; then
        echo -e "${GREEN}====== 👉 V2rayN 分享链接 (已存至 $LINK_FILE) ======${RESET}"
        cat "$LINK_FILE"
    fi
}

# ================== 核心交互配置处理 ==================
configure_xray() {
    info "开始配置 VLESS-Encryption 节点..."
    local port uuid remark

    while true; do
        read -rp "请输入监听端口 (直接回车随机分配端口): " input_port
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
        read -rp "请输入UUID (直接回车自动随机生成): " input_uuid
        if [[ -z "${input_uuid:-}" ]]; then
            if [ -x "$XRAY_BINARY" ]; then
                uuid=$("$XRAY_BINARY" uuid)
            else
                uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "7415d2b8-1454-4da8-963b-4663e8322851")
            fi
            break
        elif is_valid_uuid "$input_uuid"; then
            uuid="$input_uuid"
            break
        else
            error "UUID 格式无效"
        fi
    done

    local hostname_str
    hostname_str=$(hostname 2>/dev/null || echo "linux")
    read -rp "请输入节点备注名称 (默认: ${hostname_str}-VLESS-E): " input_remark
    remark=${input_remark:-${hostname_str}-VLESS-E}

    mkdir -p "$(dirname "$XRAY_CONFIG")"

    # 新建流程生成底层加解密配置对
    local encryption_info
    encryption_info=$(generate_vless_encryption_config) || return 1
    
    local decryption encryption
    decryption=$(echo "$encryption_info" | cut -d'|' -f1)
    encryption=$(echo "$encryption_info" | cut -d'|' -f2)

    # 写入状态文件（第一行为密文，其余为元数据环境）
    echo "$encryption" > "$STATE_FILE"
    cat << EOF >> "$STATE_FILE"
PORT='${port}'
UUID='${uuid}'
REMARK='${remark}'
EOF

    write_config "$port" "$uuid" "$decryption"
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
        error "重启服务失败，当前配置可能与系统环境不兼容。"
        return 1
    fi
    info "已成功切换为 Socks5 出口！"
}

# ================== 安装 ==================
install_xray() {
    info "开始拉取部署 Xray 核心组件..."
    download_and_extract_xray || return 1
    setup_systemd_service
    configure_xray
    info "安装完成并已成功启动服务: ${SERVICE_NAME}"
}

# ================== 更新 ==================
update_xray() {
    info "开始平滑更新 Xray 核心程序..."
    
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        info "检测到服务正在运行，正在暂退服务进行文件覆盖..."
        systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    fi

    if ! download_and_extract_xray; then
        error "下载或部署新版本失败，尝试拉起原有服务..."
        restart_xray
        return 1
    fi
    
    if restart_xray; then
        generate_link
        info "最新版平滑更新成功！当前核心版本: $(get_xray_version)"
    else
        error "更新后服务拉起失败，请查看日志。"
        return 1
    fi
}

# ================== 修改配置 ==================
modify_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "配置文件不存在，请先执行安装流程"
        return 1
    fi

    local old_port old_uuid old_decryption old_encryption old_remark
    old_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "443")
    old_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null || echo "")
    old_decryption=$(jq -r '.inbounds[0].settings.decryption' "$XRAY_CONFIG" 2>/dev/null || echo "")
    old_encryption=$(head -n 1 "$STATE_FILE" 2>/dev/null || echo "")
    old_remark=$(grep -E "^REMARK=" "$STATE_FILE" | cut -d"'" -f2 2>/dev/null || echo "VLESS-E")

    if [[ -z "$old_decryption" || -z "$old_encryption" ]]; then
        error "提取加解密密钥底座失败，停止原地修改。请使用选项 1 重新安装。"
        return 1
    fi

    local port uuid remark

    while true; do
        read -rp "请输入新端口 [当前:${old_port}, 回车不修改]: " input_port
        if [[ -z "$input_port" ]]; then
            port="$old_port"
            break
        elif [[ "${input_port,,}" == "rand" ]]; then
            port=$(get_random_port)
            info "已重分配空闲随机端口: $port"
            break
        elif is_valid_port "$input_port"; then
            if [[ "$input_port" != "$old_port" ]]; then
                if ! check_port "$input_port"; then
                    error "端口 ${input_port} 已被占用，请重新换一个。"
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
        read -rp "请输入UUID [当前:${old_uuid}, 回车不修改]: " input_uuid
        uuid=${input_uuid:-$old_uuid}
        if is_valid_uuid "$uuid"; then
            break
        else
            error "UUID 格式无效"
        fi
    done

    read -rp "请输入节点备注名称 [当前:${old_remark}, 回车不修改]: " input_remark
    remark=${input_remark:-$old_remark}

    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"

    # 平滑修改，完美保留加解密密钥，拒绝重新计算
    echo "$old_encryption" > "$STATE_FILE"
    cat << EOF >> "$STATE_FILE"
PORT='${port}'
UUID='${uuid}'
REMARK='${remark}'
EOF

    write_config "$port" "$uuid" "$old_decryption"
    test_config || return 1
    generate_link
    restart_xray
    info "配置修改成功"
}

# ================== 卸载 ==================
uninstall_xray() {
    warn "即将开始完全卸载 ${SERVICE_NAME} 服务..."

    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    
    rm -f "$XRAY_BINARY"
    rm -rf "/usr/local/etc/${SERVICE_NAME}"
    rm -rf "/usr/local/share/${SERVICE_NAME}"
    rm -f "$LINK_FILE"
    
    info "服务已成功卸载，相关的配置底座与元数据已全部清理。"
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
    echo -e "${GREEN}     VLESS-Encryption 面板       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 VLESS-Encryption${RESET}"
    echo -e "${GREEN} 2. 更新 VLESS-Encryption${RESET}"
    echo -e "${GREEN} 3. 卸载 VLESS-Encryption${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 VLESS-Encryption${RESET}"
    echo -e "${GREEN} 6. 停止 VLESS-Encryption${RESET}"
    echo -e "${GREEN} 7. 重启 VLESS-Encryption${RESET}"
    echo -e "${GREEN} 8. 查看服务日志${RESET}"
    echo -e "${GREEN} 9. 查看节点配置${RESET}"
    echo -e "${GREEN}10. 配置Socks5出口${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# ================== 安装依赖 ==================
install_dependencies() {
    if command -v apt &>/dev/null; then
        apt update && apt install -y jq curl wget sed coreutils unzip iproute2 || true
    elif command -v dnf &>/dev/null; then
        dnf install -y jq curl wget sed coreutils unzip iproute2
    elif command -v yum &>/dev/null; then
        yum install -y jq curl wget sed coreutils unzip iproute2
    else
        error "未知的包管理器，请手动补充环境包: jq, curl, wget, unzip"
        exit 1
    fi
}

# ================== 依赖检查 ==================
pre_check() {
    if [[ $(id -u) -ne 0 ]]; then
        error "错误: 请切换至 root 用户运行此面板脚本。"
        exit 1
    fi

    local deps=(jq curl wget unzip ss awk sed)
    local missing=0

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing=1
            break
        fi
    done

    if [[ "$missing" -eq 1 ]]; then
        info "正在初始化并安装缺失的环境依赖组件..."
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
            6) systemctl stop "${SERVICE_NAME}" &>/dev/null || true; info "服务已成功停止"; pause ;;
            7) restart_xray; pause ;;
            8) journalctl -u "${SERVICE_NAME}" -e --no-pager || true; pause ;;
            9) show_current_config; pause ;;
            10) configure_custom_socks5_outbound; pause ;;
            0) exit 0 ;;
            *) error "无效输入"; pause ;;
        esac
    done
}

main "$@"
