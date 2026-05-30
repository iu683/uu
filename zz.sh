#!/bin/bash

# =========================================================
# Xray VLESS-Encryption 管理脚本(Alpine Linux) 
# =========================================================

set -Eeuo pipefail

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ================== 🚀 服务自定义重命名 ==================
readonly SERV_NAME="xray-vless-encrypt"

# ================== 📂 自定义分享链接存放路径 ==================
readonly X_LINK_DIR="/root/proxynode/vlessencryption"

# ================== 路径与日志 (自动联动) ==================
readonly X_DIR="/etc/${SERV_NAME}"
readonly X_CONFIG="${X_DIR}/config.json"
readonly X_BIN="/usr/local/bin/${SERV_NAME}"
readonly X_LINK="${X_LINK_DIR}/${SERV_NAME}_vless.txt"
readonly X_STATE="${X_DIR}/encryption_matrix.state"
readonly X_LOG="/var/log/${SERV_NAME}.log"
readonly INIT_FILE="/etc/init.d/${SERV_NAME}"

# ================== 核心工具 ==================
info() { echo -e "${GREEN}[信息] $*${RESET}"; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}"; }
error() { echo -e "${RED}[错误] $*${RESET}"; }
pause() { echo; echo -ne "${GREEN}按任意键返回菜单...${RESET}"; read -n 1 -s; echo; }

is_valid_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

restart_xray() {
    rc-service "$SERV_NAME" restart >/dev/null 2>&1 || true
    sleep 1
    if rc-service "$SERV_NAME" status 2>/dev/null | grep -q "started"; then
        return 0
    else
        return 1
    fi
}

get_xray_status() {
    if rc-service "$SERV_NAME" status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}● 运行中 ${RESET}"
    else 
        if pgrep -f "$X_BIN run" >/dev/null 2>&1; then
            echo -e "${GREEN}● 运行中 ${RESET}"
        else
            echo -e "${RED}● 未运行 ${RESET}"
        fi
    fi
}

get_xray_version() {
    if [[ -x "$X_BIN" ]]; then
        "$X_BIN" version 2>/dev/null | head -n 1 | awk '{print $2}'
    else
        echo "未安装"
    fi
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

generate_vless_encryption_config() {
    local vlessenc_output
    vlessenc_output=$($X_BIN vlessenc 2>/dev/null || true)
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

HOSTNAME=$(hostname -s | sed 's/ /_/g')

# ================== 配置写入 ==================
write_config() {
    local port=$1 uuid=$2 decryption=$3
    local outbound=${4:-'{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}'}
    mkdir -p "$X_DIR" && chmod 755 "$X_DIR"
    
    jq -n \
        --arg listen "::" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg flow "" \
        --arg decryption "$decryption" \
        --argjson outbound "[$outbound]" \
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
        "outbounds": $outbound
    }' > "$X_CONFIG"
}

# ================== 出口模式配置 ==================
configure_custom_socks5_outbound() {
    if [[ ! -f "$X_CONFIG" ]]; then 
        error "错误: Xray 未安装，无法配置出口模式。"
        return
    fi

    local mode current_protocol tmp_file
    current_protocol=$(jq -r '.outbounds[0].protocol // "freedom"' "$X_CONFIG" 2>/dev/null || echo "freedom")

    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请选择出口模式：${RESET}"
    [[ "$current_protocol" == "socks" ]] && echo -e "${YELLOW} (当前: Socks5)${RESET}" || echo -e "${GREEN} (当前: 直连)${RESET}"
    echo -e "${GREEN}1) 直连出口${RESET}"
    echo -e "${GREEN}2) Socks5出口${RESET}"
    echo -e "${GREEN}0) 取消${RESET}"
    echo -e "${GREEN}================================${RESET}"

    echo -ne "${GREEN}请输入选项 [0-2]: ${RESET}"; read mode
    case "$mode" in
        1)
            tmp_file=$(mktemp)
            jq '.outbounds = [{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}]' "$X_CONFIG" > "$tmp_file"
            cp "$X_CONFIG" "${X_CONFIG}.bak.$(date +%s)"
            mv "$tmp_file" "$X_CONFIG"
            restart_xray && info "已成功切换为直连出口！" || error "切换失败。"
            return ;;
        2) ;;
        *) info "已取消配置"; return ;;
    esac

    info "配置自定义 Socks5 出口代理..."
    local s_host s_port s_user s_pass
    echo -ne "${GREEN}请输入 Socks5 服务器地址/IP: ${RESET}"; read s_host
    [[ -z "$s_host" ]] && return

    while true; do
        echo -ne "${GREEN}请输入 Socks5 端口 (默认: 1080): ${RESET}"; read s_port
        [[ -z "$s_port" ]] && s_port=1080
        is_valid_port "$s_port" && break || error "端口无效，请输入 1-65535 之间的数字。"
    done

    echo -ne "${GREEN}请输入 Socks5 用户名 (无则回车): ${RESET}"; read s_user
    if [[ -n "$s_user" ]]; then
        echo -ne "${GREEN}请输入 Socks5 密码: ${RESET}"; read -s s_pass; echo
    else
        s_pass=""
    fi

    tmp_file=$(mktemp)
    if [[ -n "$s_user" ]]; then
        jq --arg host "$s_host" --argjson port "$s_port" --arg user "$s_user" --arg pass "$s_pass" \
            '.outbounds = [{"protocol": "socks", "tag": "custom-out", "settings": {"servers": [{"address": $host, "port": $port, "users": [{"user": $user, "pass": $pass}]}]}}]' \
            "$X_CONFIG" > "$tmp_file"
    else
        jq --arg host "$s_host" --argjson port "$s_port" \
            '.outbounds = [{"protocol": "socks", "tag": "custom-out", "settings": {"servers": [{"address": $host, "port": $port}]}}]' \
            "$X_CONFIG" > "$tmp_file"
    fi

    cp "$X_CONFIG" "${X_CONFIG}.bak.$(date +%s)"
    mv "$tmp_file" "$X_CONFIG"
    restart_xray && info "已成功切换为 Socks5 出口！" || error "重启失败，请检查 Socks5 信息。"
}

# 修改配置
modify_config() {
    if [[ ! -f "$X_CONFIG" ]]; then error "请先安装 Xray"; return; fi
    if [[ ! -f "$X_STATE" ]]; then error "快照状态文件缺失，请重新安装以初始化矩阵"; return; fi
    
    local curr_port=$(jq -r '.inbounds[0].port' "$X_CONFIG")
    local curr_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$X_CONFIG")
    local curr_decryption=$(jq -r '.inbounds[0].settings.decryption' "$X_CONFIG")
    local curr_encryption=$(cat "$X_STATE")
    local curr_outbound=$(jq -c '.outbounds[0]' "$X_CONFIG")

    # 1. 修改端口
    local n_port
    while true; do
        read -p "请输入新端口 (回车保持 $curr_port): " n_port
        n_port=${n_port:-$curr_port}
        is_valid_port "$n_port" && break || error "端口无效，请输入 1-65535 之间的数字。"
    done

    # 2. 修改 UUID
    local n_uuid
    while true; do
        read -p "请输入新 UUID (回车保持 $curr_uuid): " n_uuid
        n_uuid=${n_uuid:-$curr_uuid}
        if [[ "$n_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            break
        else
            error "UUID 格式不正确，请重新输入。"
        fi
    done

    write_config "$n_port" "$n_uuid" "$curr_decryption" "$curr_outbound"
    rc-service "$SERV_NAME" restart
    
    # 重新生成链接
    local ip=$(get_public_ip || echo "127.0.0.1")
    local host_addr=$ip
    if [[ $ip == *":"* ]]; then host_addr="[$ip]"; fi
    
    mkdir -p "$X_LINK_DIR"
    echo "vless://$n_uuid@$host_addr:$n_port?encryption=$curr_encryption&security=none&type=tcp#$HOSTNAME-vless-Encryption" > "$X_LINK"
    info "配置已更新并成功重启服务！"
}

# ================== 安装与管理 ==================
install_xray() {
    info "正在安装依赖与内核..."
    apk update && apk add curl unzip jq uuidgen gcompat libc6-compat bc openssl > /dev/null 2>&1
    mkdir -p "$X_DIR" && sync
    
    local arch=$(uname -m | sed 's/x86_64/64/;s/aarch64/arm64-v8a/')
    local ver=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
    
    info "下载 Xray $ver ($arch)..."
    curl -L -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/$ver/Xray-linux-$arch.zip"
    unzip -o /tmp/xray.zip -d /tmp/xray_tmp > /dev/null
    mv -f /tmp/xray_tmp/xray "$X_BIN" && chmod +x "$X_BIN"
    rm -rf /tmp/xray*
    
    if [[ ! -f "$X_CONFIG" ]]; then
        echo -ne "${GREEN}请输入入站端口 (回车随机): ${RESET}"; read port; [[ -z "$port" ]] && port=$((RANDOM % 45535 + 10000))
        
        # 1. 自定义 UUID
        local uuid
        while true; do
            echo -ne "${GREEN}请输入自定义 UUID (回车随机生成): ${RESET}"; read input_uuid
            if [[ -z "$input_uuid" ]]; then
                if [ -x "$X_BIN" ]; then
                    uuid=$($X_BIN uuid 2>/dev/null || uuidgen)
                else
                    uuid=$(uuidgen)
                fi
                break
            else
                if [[ "$input_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
                    uuid="$input_uuid"
                    break
                else
                    error "UUID 格式不正确，请重新输入。"
                fi
            fi
        done

        # 2. 生成抗量子对称矩阵对
        info "正在实时构建后量子加解密通信矩阵..."
        local encryption_info
        encryption_info=$(generate_vless_encryption_config)
        
        local decryption=$(echo "$encryption_info" | cut -d'|' -f1)
        local encryption=$(echo "$encryption_info" | cut -d'|' -f2)
        
        # 锁存客户端密钥快照
        echo "$encryption" > "$X_STATE"
        
        write_config "$port" "$uuid" "$decryption"
        
        # 写入 OpenRC 服务脚本
        cat << EOF > "$INIT_FILE"
#!/sbin/openrc-run
command="${X_BIN}"
command_args="run -c ${X_CONFIG}"
command_background="yes"
pidfile="/run/${SERV_NAME}.pid"
output_log="$X_LOG"
error_log="$X_LOG"
EOF
        chmod +x "$INIT_FILE"
        touch "$X_LOG"
        rc-update add "$SERV_NAME" default >/dev/null 2>&1
    fi

    rc-service "$SERV_NAME" restart
    
    # 读取配置生成分享链接
    local ip=$(get_public_ip || echo "127.0.0.1")
    local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$X_CONFIG")
    local port=$(jq -r '.inbounds[0].port' "$X_CONFIG")
    local encryption=$(cat "$X_STATE")
    
    local host_addr=$ip
    if [[ $ip == *":"* ]]; then host_addr="[$ip]"; fi
    
    local link="vless://$uuid@$host_addr:$port?encryption=$encryption&security=none&type=tcp#$HOSTNAME-vless-Encryption"
    
    mkdir -p "$X_LINK_DIR"
    echo "$link" > "$X_LINK"

    show_current_config
}

# ================== 显示配置 (全功能看板对接) ==================
show_current_config() {
    if [[ ! -f "$X_CONFIG" ]]; then
        error "配置文件不存在"
        return
    fi

    local ip uuid port outbound_mode remark
    ip=$(get_public_ip || echo "未知")
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$X_CONFIG" 2>/dev/null || echo "未知")
    port=$(jq -r '.inbounds[0].port' "$X_CONFIG" 2>/dev/null || echo "未知")
    remark="$HOSTNAME-${SERV_NAME}"
    
    local current_protocol=$(jq -r '.outbounds[0].protocol // "freedom"' "$X_CONFIG" 2>/dev/null || echo "freedom")
    [[ "$current_protocol" == "socks" ]] && outbound_mode="Socks5 链式代理" || outbound_mode="直连 (Freedom)"

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

    if [[ -f "$X_LINK" ]]; then
        echo -e "${GREEN}====== 👉 V2rayN 分享链接 (已存至 $X_LINK) ======${RESET}"
        cat "$X_LINK"
    fi
}

# ================== 菜单 ==================
show_menu() {
    clear
    local status=$(get_xray_status)
    local version=$(get_xray_version)
    local port_show="-"
    [[ -f "$X_CONFIG" ]] && port_show=$(jq -r '.inbounds[0].port' "$X_CONFIG" 2>/dev/null || echo "-")

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   Xray VLESS-Encryption 面板    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 Xray VLESS-Encryption${RESET}"
    echo -e "${GREEN} 2. 更新 Xray${RESET}"
    echo -e "${GREEN} 3. 卸载 Xray${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 Xray${RESET}"
    echo -e "${GREEN} 6. 停止 Xray${RESET}"
    echo -e "${GREEN} 7. 重启 Xray${RESET}"
    echo -e "${GREEN} 8. 查看日志${RESET}"
    echo -e "${GREEN} 9. 查看节点配置${RESET}"
    echo -e "${GREEN}10. 配置Socks5出口${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

while true; do
    show_menu
    echo -ne "${GREEN}请输入选项: ${RESET}"; read choice
    case $choice in
        1|2) install_xray; pause ;;
        3) 
            rc-service "$SERV_NAME" stop 2>/dev/null || true
            rc-update del "$SERV_NAME" default 2>/dev/null || true
            rm -rf "$X_DIR" "$X_BIN" "$INIT_FILE" "$X_LINK" "$X_LOG"
            info "卸载完成"
            pause 
            ;;
        4) modify_config; pause ;;
        5) rc-service "$SERV_NAME" start; pause ;;
        6) rc-service "$SERV_NAME" stop; pause ;;
        7) rc-service "$SERV_NAME" restart; pause ;;
        8) [[ -f "$X_LOG" ]] && tail -f "$X_LOG" || error "暂无日志"; pause ;;
        9) show_current_config || error "无配置"; pause ;;
        10) configure_custom_socks5_outbound; pause ;;
        0) exit 0 ;;
        *) error "无效选项"; sleep 1 ;;
    esac
done
