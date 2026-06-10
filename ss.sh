#!/bin/bash

# =========================================================
# Xray VLESS-Reality 管理脚本 (Alpine Linux)
# =========================================================

set -Eeuo pipefail

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ================== 路径与日志 ==================
readonly SERV_NAME="xray-reality"
readonly X_DIR="/etc/${SERV_NAME}"
readonly X_CONFIG="${X_DIR}/config.json"
readonly X_BIN="/usr/local/bin/${SERV_NAME}"
readonly X_PBK="${X_DIR}/public.key"
readonly X_LINK="/root/proxynode/Reality/${SERV_NAME}_vless_reality.txt"
readonly X_LOG="/var/log/${SERV_NAME}.log"
readonly INIT_FILE="/etc/init.d/${SERV_NAME}"

# ================== GITHUB 代理加速池 ==================
readonly GITHUB_PROXY=(
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
    '' # 留空代表直连，作为兜底保底
)

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


# ✨ 终极双栈/纯v6 智能 IP 获取引擎
get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
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

    error "无法获取公网 IP 地址，请检查网络或 DNS 设置！" && echo "127.0.0.1" && return 1
}

HOSTNAME=$(hostname -s | sed 's/ /_/g')

# ================== 配置写入 ==================
write_config() {
    local port=$1 uuid=$2 domain=$3 pri=$4 sid=$5
    local outbound=${6:-'{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}'}
    mkdir -p "$X_DIR" && chmod 755 "$X_DIR"
    cat > "$X_CONFIG" <<EOF
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "port": $port, "protocol": "vless",
        "settings": { "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}], "decryption": "none" },
        "streamSettings": {
            "network": "tcp", "security": "reality",
            "realitySettings": {
                "dest": "$domain:443", "serverNames": ["$domain"],
                "privateKey": "$pri", "shortIds": ["$sid"], "fingerprint": "chrome"
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
        # 兼容纯 v6 机器的解析，允许 openssl 自由选择最快的地址族
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

# ================== 出口模式配置  ==================
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
    local pub=$(cat "$X_PBK")
    local curr_outbound=$(jq -c '.outbounds[0]' "$X_CONFIG")

    local n_port
    while true; do
        read -p "请输入新端口 (回车保持 $curr_port): " n_port
        n_port=${n_port:-$curr_port}
        is_valid_port "$n_port" && break || error "端口无效，请输入 1-65535 之间的数字。"
    done

    read -p "请输入新域名 (回车保持 $curr_domain): " n_domain
    n_domain=${n_domain:-$curr_domain}
    
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

    local n_sid
    while true; do
        read -p "请输入新 ShortID (回车保持 $curr_sid): " n_sid
        n_sid=${n_sid:-$curr_sid}
        if [[ "$n_sid" =~ ^[0-9a-fA-F]+$ ]] && (( ${#n_sid} % 2 == 0 )) && (( ${#n_sid} >= 2 && ${#n_sid} <= 16 )); then
            break
        else
            error "ShortID 格式不正确，必须是缩写至2-16位的偶数长度十六进制字符。"
        fi
    done

    write_config "$n_port" "$n_uuid" "$n_domain" "$pri" "$n_sid" "$curr_outbound"
    rc-service "$SERV_NAME" restart
    
    local ip=$(get_public_ip)
    mkdir -p "$(dirname "$X_LINK")"
    echo "vless://$n_uuid@$ip:$n_port?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=$n_domain&fp=chrome&pbk=$pub&sid=$n_sid#$HOSTNAME-Reality" > "$X_LINK"
    info "配置已更新并成功重启服务！"
}

# ================== 安装与管理 ==================
install_xray() {
    info "正在安装与检测系统依赖..."
    apk update && apk add curl unzip openssl jq uuidgen gcompat libc6-compat bc > /dev/null 2>&1
    mkdir -p "$X_DIR" && sync
    
    local arch=$(uname -m | sed 's/x86_64/64/;s/aarch64/arm64-v8a/')
    local ver=""
    
    # ✨ 升级：结合代理池获取最新发布版本号
    info "正在检索 Xray-core 官方最新发布版本..."
    for proxy in "${GITHUB_PROXY[@]}"; do
        local api_url="${proxy}https://api.github.com/repos/XTLS/Xray-core/releases/latest"
        info "尝试通过代理 [ ${proxy:-直连} ] 获取版本号..."
        ver=$(wget -qO- --timeout=5 --no-check-certificate "$api_url" | jq -r .tag_name 2>/dev/null || echo "")
        if [[ -n "$ver" && "$ver" != "null" ]]; then
            info "成功获取最新版本: $ver"
            break
        fi
    done

    if [[ -z "$ver" || "$ver" == "null" ]]; then
        ver="v26.3.27"
        warn "所有代理池检索超时，将为您安装高稳定保障版本: $ver"
    fi
    
    # ✨ 升级：结合代理池进行文件下载（多池轮询，死磕下载直至成功）
    local download_success=false
    for proxy in "${GITHUB_PROXY[@]}"; do
        local dl_url="${proxy}https://github.com/XTLS/Xray-core/releases/download/$ver/Xray-linux-$arch.zip"
        info "正在通过代理 [ ${proxy:-直连} ] 下载 Xray $ver ($arch)..."
        
        if wget --no-check-certificate --timeout=15 -O /tmp/xray.zip "$dl_url" 2>/dev/null; then
            if [ -s /tmp/xray.zip ]; then
                download_success=true
                break
            fi
        fi
        warn "当前代理下载失败，正在切换至下一款代理..."
    done

    if [ "$download_success" = false ]; then
        error "所有代理池节点及直连模式均下载失败，请检查您的 VPS 的 IPv6/IPv4 DNS 是否配置正常！"
        return 1
    fi
    
    unzip -o /tmp/xray.zip -d /tmp/xray_tmp > /dev/null
    mv -f /tmp/xray_tmp/xray "$X_BIN" && chmod +x "$X_BIN"
    rm -rf /tmp/xray*
    
    if [[ ! -f "$X_CONFIG" ]]; then
        echo -ne "${GREEN}请输入入站端口 (回车随机): ${RESET}"; read port; [[ -z "$port" ]] && port=$((RANDOM % 45535 + 10000))
        echo -ne "${GREEN}请输入伪装域名 (回车 www.amazon.com): ${RESET}"; read domain; [[ -z "$domain" ]] && domain="www.amazon.com"
        
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
                    error "ShortID 格式不正确，必须是偶数长度的十六进制。"
                fi
            fi
        done
        
        local keys=$($X_BIN x25519)
        local pri=$(echo "$keys" | grep "Private" | awk '{print $NF}')
        local pub=$(echo "$keys" | grep "Public" | awk '{print $NF}')
        
        echo "$pub" > "$X_PBK"
        write_config "$port" "$uuid" "$domain" "$pri" "$sid"
        
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
    
    local ip=$(get_public_ip "auto")

    # ✨ 核心修复：如果是 IPv6 地址，自动为其包裹中括号 []，如果是 v4 则保持原样
    if [[ "$ip" == *":"* ]]; then
        info "检测到当前使用 IPv6 落地，已自动为您进行标准的 [方括号] 封装！"
        local link_ip="[$ip]"
    else
        local link_ip="$ip"
    fi

    # 拼接标准节点链接
    local link="vless://$uuid@${link_ip}:$port?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=$domain&fp=chrome&pbk=$pub&sid=$sid#$HOSTNAME-vless-Reality"
    
    mkdir -p "$(dirname "$X_LINK")"
    echo "$link" > "$X_LINK"

    show_current_config
}

# ================== 显示配置  ==================
show_current_config() {
    if [[ ! -f "$X_CONFIG" ]]; then
        error "配置文件不存在"
        return
    fi

    local ip uuid port domain shortid public_key outbound_mode
    ip=$(get_public_ip || echo "未知")
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$X_CONFIG" 2>/dev/null || echo "未知")
    port=$(jq -r '.inbounds[0].port' "$X_CONFIG" 2>/dev/null || echo "未知")
    domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$X_CONFIG" 2>/dev/null || echo "未知")
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$X_CONFIG" 2>/dev/null || echo "未知")
    public_key=$(cat "$X_PBK" 2>/dev/null || echo "N/A")
    
    local current_protocol=$(jq -r '.outbounds[0].protocol // "freedom"' "$X_CONFIG" 2>/dev/null || echo "freedom")
    [[ "$current_protocol" == "socks" ]] && outbound_mode="Socks5 链式代理" || outbound_mode="直连 (Freedom)"

    echo -e "\n${GREEN}====== 当前配置详情 ======${RESET}"
    echo -e "${YELLOW}IP地址      : ${ip}${RESET}"
    echo -e "${YELLOW}端口        : ${port}${RESET}"
    echo -e "${YELLOW}UUID        : ${uuid}${RESET}"
    echo -e "${YELLOW}SNI/域名    : ${domain}${RESET}"
    echo -e "${YELLOW}PublicKey   : ${public_key}${RESET}"
    echo -e "${YELLOW}ShortID     : ${shortid}${RESET}"
    echo -e "${YELLOW}出口模式    : ${outbound_mode}${RESET}"
    
    if [[ "$ip" == *":"* ]]; then
        echo -e "${YELLOW}检测到当前落地为原生 IPv6，已为您在分享链接中进行标准的方括号标准化封装！${RESET}"
    fi
    
    if [[ -f "$X_LINK" ]]; then
        echo -e "${GREEN}====== 👉 节点分享链接 ======${RESET}"
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
    echo -e "${GREEN}    Xray Vless-Reality 面板     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 Xray Vless-Reality${RESET}"
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
            rm -rf /root/proxynode/Reality
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
