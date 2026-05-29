#!/bin/bash

# =========================================================
# Xray VLESS-Reality 管理脚本
# =========================================================

set -Eeuo pipefail

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ================== 路径与日志 ==================
readonly X_DIR="/etc/xray"
readonly X_CONFIG="${X_DIR}/config.json"
readonly X_BIN="/usr/local/bin/xray"
readonly X_PBK="${X_DIR}/public.key"
readonly X_LINK="/root/xray_vless_reality.txt"
readonly X_LOG="/var/log/xray.log"

# ================== 核心工具 ==================
info() { echo -e "${GREEN}[信息] $*${RESET}"; }
warn() { echo -e "${GREEN}[警告] $*${RESET}"; }
error() { echo -e "${GREEN}[错误] $*${RESET}"; }
pause() { echo; echo -ne "${GREEN}按任意键返回菜单...${RESET}"; read -n 1 -s; echo; }

# 状态获取
get_xray_status() {
    if rc-service xray status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}● 运行中${RESET}"
    else echo -e "${RED}● 未运行${RESET}"; fi
}

# 版本获取
get_xray_version() {
    [[ -x "$X_BIN" ]] && "$X_BIN" version 2>/dev/null | head -n 1 | awk '{print $2}' || echo "未安装"
}

# 公网IP获取
get_public_ip() {
    curl -4fsSL --max-time 5 https://api.ipify.org || echo "未知IP"
}
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

# ================== Socks5 出口配置 ==================
config_socks5() {
    if [[ ! -f "$X_CONFIG" ]]; then error "请先安装 Xray"; return; fi
    echo -e "${GREEN}--- Socks5 出口配置 ---${RESET}"
    echo -e "${GREEN}1. 启用 Socks5 出口${RESET}"
    echo -e "${GREEN}2. 还原 Freedom 直连出口${RESET}"
    echo -e "${GREEN}0. 返回${RESET}"
    echo -ne "${GREEN}请选择: ${RESET}"; read s_opt

    case $s_opt in
        1)
            echo -ne "${GREEN}Socks5 服务器地址: ${RESET}"; read s_addr
            echo -ne "${GREEN}Socks5 服务器端口: ${RESET}"; read s_port
            echo -ne "${GREEN}用户名 (无则直接回车): ${RESET}"; read s_user
            echo -ne "${GREEN}密码 (无则直接回车): ${RESET}"; read s_pass
            
            if [[ -n "$s_user" ]]; then
                new_outbound=$(jq -n --arg h "$s_addr" --argjson p "$s_port" --arg u "$s_user" --arg pw "$s_pass" \
                '{"protocol":"socks","settings":{"servers":[{"address":$h,"port":$p,"users":[{"user":$u,"pass":$pw}]}]}}')
            else
                new_outbound=$(jq -n --arg h "$s_addr" --argjson p "$s_port" \
                '{"protocol":"socks","settings":{"servers":[{"address":$h,"port":$p}]}}')
            fi
            ;;
        2)
            new_outbound='{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}'
            ;;
        *) return ;;
    esac

    tmp_cfg=$(mktemp)
    jq --argjson obj "$new_outbound" '.outbounds = [$obj]' "$X_CONFIG" > "$tmp_cfg" && mv "$tmp_cfg" "$X_CONFIG"
    rc-service xray restart
    info "Socks5 出口模式更新成功！"
}

# 4. 修改配置
modify_config() {
    if [[ ! -f "$X_CONFIG" ]]; then error "请先安装 Xray"; return; fi
    
    # 读取当前配置
    local curr_port=$(jq -r '.inbounds[0].port' "$X_CONFIG")
    local curr_domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$X_CONFIG")
    local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$X_CONFIG")
    local pri=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$X_CONFIG")
    local sid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$X_CONFIG")
    local pub=$(cat "$X_PBK")
    local curr_outbound=$(jq -c '.outbounds[0]' "$X_CONFIG")

    read -p "请输入新端口 (回车保持 $curr_port): " n_port
    n_port=${n_port:-$curr_port}
    read -p "请输入新域名 (回车保持 $curr_domain): " n_domain
    n_domain=${n_domain:-$curr_domain}
    
    write_config "$n_port" "$uuid" "$n_domain" "$pri" "$sid" "$curr_outbound"
    rc-service xray restart
    
    # 更新分享链接
    local ip=$(get_public_ip)
    echo "vless://$uuid@$ip:$n_port?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=$n_domain&fp=chrome&pbk=$pub&sid=$sid#Alpine-Reality" > "$X_LINK"
    info "配置已更新！"
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
        
        local uuid=$(uuidgen)
        local keys=$($X_BIN x25519)
        local pri=$(echo "$keys" | grep "Private" | awk '{print $NF}')
        local pub=$(echo "$keys" | grep "Public" | awk '{print $NF}')
        local sid=$(openssl rand -hex 4)
        
        echo "$pub" > "$X_PBK"
        write_config "$port" "$uuid" "$domain" "$pri" "$sid"
        
        cat << EOF > /etc/init.d/xray
#!/sbin/openrc-run
command="/usr/local/bin/xray"
command_args="run -c /etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"
output_log="$X_LOG"
error_log="$X_LOG"
EOF
        chmod +x /etc/init.d/xray
        touch "$X_LOG"
        rc-update add xray default >/dev/null 2>&1
    fi

    rc-service xray restart
    
    local ip=$(get_public_ip)
    local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$X_CONFIG")
    local port=$(jq -r '.inbounds[0].port' "$X_CONFIG")
    local domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$X_CONFIG")
    local pub=$(cat "$X_PBK" 2>/dev/null || echo "N/A")
    local sid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$X_CONFIG")
    
    local link="vless://$uuid@$ip:$port?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=$domain&fp=chrome&pbk=$pub&sid=$sid#Alpine-Reality"
    echo "$link" > "$X_LINK"
    
    info "操作成功！当前节点配置："
    echo -e "${YELLOW}$link${RESET}"
}

# ================== 菜单 ==================
show_menu() {
    clear
    local status=$(get_xray_status)
    local version=$(get_xray_version)
    local port_show="-"
    [[ -f "$X_CONFIG" ]] && port_show=$(jq -r '.inbounds[0].port' "$X_CONFIG" 2>/dev/null || echo "-")

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   Xray Vless+Reality 管理面板      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 Xray Vless+Reality${RESET}"
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
        3) rc-service xray stop 2>/dev/null; rc-update del xray default 2>/dev/null; rm -rf "$X_DIR" "$X_BIN" /etc/init.d/xray "$X_LINK" "$X_LOG"; info "卸载完成"; pause ;;
        4) modify_config; pause ;;
        5) rc-service xray start; pause ;;
        6) rc-service xray stop; pause ;;
        7) rc-service xray restart; pause ;;
        8) [[ -f "$X_LOG" ]] && tail -f "$X_LOG" || error "暂无日志"; pause ;;
        9) [[ -f "$X_LINK" ]] && (echo -e "${GREEN}$(cat "$X_LINK")${RESET}") || error "无配置"; pause ;;
        10) config_socks5; pause ;;
        11) select_best_sni; pause ;;
        0) exit 0 ;;
        *) error "无效选项"; sleep 1 ;;
    esac
done
