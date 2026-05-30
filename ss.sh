#!/bin/bash

# =========================================================
# Xray VLESS-Reality-XHTTP 管理脚本(Alpine Linux )
# =========================================================

set -Eeuo pipefail

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ================== 🚀 服务自定义重命名 ==================
readonly SERV_NAME="xray-xhttp"

# ================== 📂 自定义分享链接存放路径 ==================
readonly X_LINK_DIR="/root/proxynode/Reality"

# ================== 路径与日志 (自动联动) ==================
readonly X_DIR="/etc/${SERV_NAME}"
readonly X_CONFIG="${X_DIR}/config.json"
readonly X_BIN="/usr/local/bin/${SERV_NAME}"
readonly X_PBK="${X_DIR}/public.key"
readonly X_LINK="${X_LINK_DIR}/${SERV_NAME}_vless_reality.txt"
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
        echo -e "${RED}● 未运行 ${RESET}"
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
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    error "无法获取公网 IP 地址。" && return 1
}

HOSTNAME=$(hostname -s | sed 's/ /_/g')

# ================== 配置写入 (支持自定义 Path) ==================
write_config() {
    local port=$1 uuid=$2 domain=$3 pri=$4 sid=$5 path=$6
    local outbound=${7:-'{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}'}
    mkdir -p "$X_DIR" && chmod 755 "$X_DIR"
    
    cat > "$X_CONFIG" <<EOF
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "port": $port,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$uuid"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "xhttp",
            "security": "reality",
            "xhttpSettings": {
                "path": "$path"
            },
            "realitySettings": {
                "dest": "$domain:443",
                "serverNames": ["$domain"],
                "privateKey": "$pri",
                "shortIds": ["$sid"],
                "fingerprint": "chrome"
            }
        },
        "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }],
    "outbounds": [$outbound]
}
EOF
}

# ================== SNI 优选 ==================
select_best_sni() {
    info "开始优选 SNI 延迟测试..."
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
        start=$(date +%s%N)
        if timeout 2 openssl s_client -connect ${sni}:443 -servername ${sni} -brief </dev/null >/dev/null 2>&1; then
            end=$(date +%s%N)
            cost=$(( (end - start) / 1000000 ))
            echo -e "${GREEN}[SNI] $sni -> ${cost}ms${RESET}"
            if [ $cost -lt $BEST_TIME ]; then
                BEST_TIME=$cost; BEST_SNI=$sni
            fi
        fi
    done

    if [ -n "$BEST_SNI" ]; then
        info "最优 SNI: $BEST_SNI (${BEST_TIME}ms)"
        return 0
    else
        warn "未找到可用 SNI"
        return 1
    fi
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
    
    local curr_port=$(jq -r '.inbounds[0].port' "$X_CONFIG")
    local curr_domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$X_CONFIG")
    local curr_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$X_CONFIG")
    local pri=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$X_CONFIG")
    local curr_sid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$X_CONFIG")
    local curr_path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // "/"' "$X_CONFIG")
    local pub=$(cat "$X_PBK")
    local curr_outbound=$(jq -c '.outbounds[0]' "$X_CONFIG")

    # 1. 修改端口
    local n_port
    while true; do
        read -p "请输入新端口 (回车保持 $curr_port): " n_port
        n_port=${n_port:-$curr_port}
        is_valid_port "$n_port" && break || error "端口无效，请输入 1-65535 之间的数字。"
    done

    # 2. 修改域名
    read -p "请输入新域名 (回车保持 $curr_domain): " n_domain
    n_domain=${n_domain:-$curr_domain}
    
    # 3. 修改 UUID
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

    # 4. 修改 ShortID
    local n_sid
    while true; do
        read -p "请输入新 ShortID (回车保持 $curr_sid): " n_sid
        n_sid=${n_sid:-$curr_sid}
        if [[ "$n_sid" =~ ^[0-9a-fA-F]+$ ]] && (( ${#n_sid} % 2 == 0 )) && (( ${#n_sid} >= 2 && ${#n_sid} <= 16 )); then
            break
        else
            error "ShortID 格式不正确，必须是偶数长度的十六进制字符（2-16位）。"
        fi
    done

    # 5. 修改 Path
    read -p "请输入新 XHTTP Path (回车保持 $curr_path): " n_path
    n_path=${n_path:-$curr_path}
    [[ "$n_path" != /* ]] && n_path="/${n_path}" # 自动纠正缺少的斜杠

    write_config "$n_port" "$n_uuid" "$n_domain" "$pri" "$n_sid" "$n_path" "$curr_outbound"
    rc-service "$SERV_NAME" restart
    
    local ip=$(get_public_ip)
    mkdir -p "$X_LINK_DIR"
    echo "vless://$n_uuid@$ip:$n_port?encryption=none&type=xhttp&security=reality&sni=$n_domain&fp=chrome&pbk=$pub&sid=$n_sid&path=$(echo "$n_path" | jq -sRr @uri)#$HOSTNAME-${SERV_NAME}" > "$X_LINK"
    info "配置已更新并成功重启服务！"
}

# ================== 安装与管理 ==================
install_xray() {
    info "正在安装依赖与内核..."
    apk update && apk add curl unzip openssl jq uuidgen gcompat libc6-compat bc > /dev/null 2>&1
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
        echo -ne "${GREEN}请输入伪装域名 (回车 www.amazon.com): ${RESET}"; read domain; [[ -z "$domain" ]] && domain="www.amazon.com"
        
        # 1. 自定义 UUID
        local uuid
        while true; do
            echo -ne "${GREEN}请输入自定义 UUID (回车随机生成): ${RESET}"; read input_uuid
            if [[ -z "$input_uuid" ]]; then
                uuid=$(uuidgen)
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

        # 2. 自定义 ShortID
        local sid
        while true; do
            echo -ne "${GREEN}请输入自定义 ShortID (回车随机生成): ${RESET}"; read input_sid
            if [[ -z "$input_sid" ]]; then
                sid=$(openssl rand -hex 4)
                break
            else
                if [[ "$input_sid" =~ ^[0-9a-fA-F]+$ ]] && (( ${#input_sid} % 2 == 0 )) && (( ${#input_sid} >= 2 && ${#input_sid} <= 16 )); then
                    sid="$input_sid"
                    break
                else
                    error "ShortID 格式不正确。"
                fi
            fi
        done
        
        # 3. 自定义 XHTTP Path
        # 5. XHTTP Path 随机生成逻辑
        echo -ne "${GREEN}请输入自定义 XHTTP Path (回车默认随机生成): ${RESET}"; read path
        if [[ -z "$path" ]]; then
            path="/$(openssl rand -hex 4)"
            info "👉 采用随机 Path: $path"
        else
            [[ "$path" != /* ]] && path="/${path}" # 自动补齐首位斜杠
        fi
        
        local keys=$($X_BIN x25519)
        local pri=$(echo "$keys" | grep "Private" | awk '{print $NF}')
        local pub=$(echo "$keys" | grep "Public" | awk '{print $NF}')
        
        echo "$pub" > "$X_PBK"
        write_config "$port" "$uuid" "$domain" "$pri" "$sid" "$path"
        
        # 写入独立名称的 OpenRC 服务脚本
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
    
    local ip=$(get_public_ip)
    local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$X_CONFIG")
    local port=$(jq -r '.inbounds[0].port' "$X_CONFIG")
    local domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$X_CONFIG")
    local pub=$(cat "$X_PBK" 2>/dev/null || echo "N/A")
    local sid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$X_CONFIG")
    local path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // "/"' "$X_CONFIG")
    
    # 链接中注入了对 path 的 URL 编码处理，防特殊字符破坏结构
    local link="vless://$uuid@$ip:$port?encryption=none&type=xhttp&security=reality&sni=$domain&fp=chrome&pbk=$pub&sid=$sid&path=$(echo "$path" | jq -sRr @uri)#$HOSTNAME-${SERV_NAME}"
    
    mkdir -p "$X_LINK_DIR"
    echo "$link" > "$X_LINK"

    show_current_config
}

# ================== 显示配置 ==================
show_current_config() {
    if [[ ! -f "$X_CONFIG" ]]; then
        error "配置文件不存在"
        return
    fi

    local ip uuid port domain shortid public_key path outbound_mode
    ip=$(get_public_ip || echo "未知")
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$X_CONFIG" 2>/dev/null || echo "未知")
    port=$(jq -r '.inbounds[0].port' "$X_CONFIG" 2>/dev/null || echo "未知")
    domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$X_CONFIG" 2>/dev/null || echo "未知")
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$X_CONFIG" 2>/dev/null || echo "未知")
    path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // "/"' "$X_CONFIG" 2>/dev/null || echo "/")
    public_key=$(cat "$X_PBK" 2>/dev/null || echo "N/A")
    
    local current_protocol=$(jq -r '.outbounds[0].protocol // "freedom"' "$X_CONFIG" 2>/dev/null || echo "freedom")
    [[ "$current_protocol" == "socks" ]] && outbound_mode="Socks5 链式代理" || outbound_mode="直连 (Freedom)"

    echo -e "\n${GREEN}====== 当前配置详情 ======${RESET}"
    echo -e "${YELLOW}独立系统服务: ${SERV_NAME}${RESET}"
    echo -e "${YELLOW}传输协议    : VLESS + Reality + XHTTP${RESET}"
    echo -e "${YELLOW}IP地址      : ${ip}${RESET}"
    echo -e "${YELLOW}端口        : ${port}${RESET}"
    echo -e "${YELLOW}UUID        : ${uuid}${RESET}"
    echo -e "${YELLOW}SNI/域名    : ${domain}${RESET}"
    echo -e "${YELLOW}PublicKey   : ${public_key}${RESET}"
    echo -e "${YELLOW}ShortID     : ${shortid}${RESET}"
    echo -e "${BLUE}XHTTP Path  : ${path}${RESET}"
    echo -e "${YELLOW}出口模式    : ${outbound_mode}${RESET}"
    echo -e "${YELLOW}分享存放路径: ${X_LINK}${RESET}"
    
    if [[ -f "$X_LINK" ]]; then
        echo -e "${GREEN}====== 👉 v2rayN / Sing-box 分享链接 ======${RESET}"
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
    echo -e "${GREEN}  Xray Vless+Reality+XHTTP 面板  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 Xray Vless+Reality+XHTTP${RESET}"
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
        11) select_best_sni; pause ;;
        0) exit 0 ;;
        *) error "无效选项"; sleep 1 ;;
    esac
done
