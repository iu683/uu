#!/bin/bash

# =========================================================
# Xray VLESS-Reality 管理脚本 (Alpine Linux 终极修复版)
# =========================================================

set -Eeuo pipefail

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ================== 基础路径 ==================
readonly X_DIR="/etc/xray"
readonly X_CONFIG="${X_DIR}/config.json"
readonly X_BIN="/usr/local/bin/xray"
readonly X_PBK="${X_DIR}/public.key"
readonly X_LINK="/root/xray_vless_reality.txt"
readonly X_LOG="/var/log/xray.log"

# ================== 核心工具 ==================
info() { echo -e "${GREEN}[信息] $*${RESET}"; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}"; }
error() { echo -e "${RED}[错误] $*${RESET}"; }
pause() { echo; read -p "按任意键返回菜单..." -n 1 -s; echo; }

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
    local ip

    for cmd in \
        "curl -4fsSL --max-time 5" \
        "wget -4qO- --timeout=5"; do

        for url in \
            "https://api.ipify.org" \
            "https://ip.sb" \
            "https://checkip.amazonaws.com"; do

            ip=$($cmd "$url" 2>/dev/null || true)

            if [[ -n "${ip:-}" ]]; then
                echo "$ip"
                return 0
            fi
        done
    done

    for cmd in \
        "curl -6fsSL --max-time 5" \
        "wget -6qO- --timeout=5"; do

        for url in \
            "https://api.ipify.org" \
            "https://ipv6.ip.sb"; do

            ip=$($cmd "$url" 2>/dev/null || true)

            if [[ -n "${ip:-}" ]]; then
                echo "$ip"
                return 0
            fi
        done
    done

    return 1
}
# ================== 核心配置逻辑 ==================
write_config() {
    local port=$1 uuid=$2 domain=$3 pri=$4 sid=$5
    local outbound=${6:-'{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}'}
    
    mkdir -p "$X_DIR" && chmod 755 "$X_DIR"
    
    cat > "$X_CONFIG" <<EOF
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "port": $port,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
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

# ================== 功能实现 ==================

# 1. 安装功能
install_xray() {
    info "正在安装依赖 (Alpine 专用)..."
    apk update && apk add curl unzip openssl jq uuidgen gcompat libc6-compat bc > /dev/null 2>&1
    
    # 强制创建并同步目录
    mkdir -p "$X_DIR" && chmod 755 "$X_DIR" && sync
    
    local arch=$(uname -m | sed 's/x86_64/64/;s/aarch64/arm64-v8a/')
    local ver=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
    
    info "下载 Xray $ver ($arch)..."
    curl -L -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/$ver/Xray-linux-$arch.zip"
    unzip -o /tmp/xray.zip -d /tmp/xray_tmp > /dev/null
    mv -f /tmp/xray_tmp/xray "$X_BIN" && chmod +x "$X_BIN"
    rm -rf /tmp/xray*
    
    read -p "请输入端口 (回车随机): " port; [[ -z "$port" ]] && port=$((RANDOM % 45535 + 10000))
    read -p "请输入域名 (回车使用 www.amazon.com): " domain; [[ -z "$domain" ]] && domain="www.amazon.com"
    
    info "生成密钥对..."
    local uuid=$(uuidgen)
    local keys=$($X_BIN x25519)
    local pri=$(echo "$keys" | grep "Private" | awk '{print $NF}')
    local pub=$(echo "$keys" | grep "Public" | awk '{print $NF}')
    local sid=$(openssl rand -hex 4)
    
    # 写入公钥
    echo "$pub" > "$X_PBK"
    write_config "$port" "$uuid" "$domain" "$pri" "$sid"
    
    # 注册 OpenRC 服务并配置日志
    cat << EOF > /etc/init.d/xray
#!/sbin/openrc-run
description="Xray Reality Service"
command="/usr/local/bin/xray"
command_args="run -c /etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"
output_log="$X_LOG"
error_log="$X_LOG"
depend() { need net; }
EOF
    chmod +x /etc/init.d/xray
    touch "$X_LOG"
    rc-update add xray default >/dev/null 2>&1
    rc-service xray restart
    
    # 生成分享链接
    local ip=$(get_public_ip)
    echo "vless://$uuid@$ip:$port?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=$domain&fp=chrome&pbk=$pub&sid=$sid#Alpine-Reality" > "$X_LINK"
    info "安装完成！"
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

# 10. Socks5 出口
config_socks() {
    if [[ ! -f "$X_CONFIG" ]]; then error "请先安装 Xray"; return; fi
    echo -e "1. 开启 Socks5 出口代理\n2. 恢复 Freedom 直连出口"
    read -p "选择操作: " s_opt
    case $s_opt in
        1)
            read -p "Socks5 地址: " s_host
            read -p "Socks5 端口: " s_port
            read -p "用户名 (无则回车): " s_user
            read -p "密码 (无则回车): " s_pass
            if [[ -n "$s_user" ]]; then
                outbound=$(jq -n --arg h "$s_host" --argjson p "$s_port" --arg u "$s_user" --arg pw "$s_pass" \
                '{"protocol":"socks","settings":{"servers":[{"address":$h,"port":$p,"users":[{"user":$u,"pass":$pw}]}]}}')
            else
                outbound=$(jq -n --arg h "$s_host" --argjson p "$s_port" \
                '{"protocol":"socks","settings":{"servers":[{"address":$h,"port":$p}]}}')
            fi
            ;;
        2) outbound='{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}' ;;
        *) return ;;
    esac
    
    tmp=$(mktemp)
    jq --argjson obj "$outbound" '.outbounds = [$obj]' "$X_CONFIG" > "$tmp" && mv "$tmp" "$X_CONFIG"
    rc-service xray restart
    info "出口配置已切换！"
}

# 11. SNI 域名优选
sni_select() {
    info "正在测试常见域名延迟..."
    local domains=("www.amazon.com" "www.apple.com" "www.microsoft.com" "www.cloudflare.com" "www.loewe.com")
    for d in "${domains[@]}"; do
        local start=$(date +%s%3N)
        if timeout 2 openssl s_client -connect "${d}:443" -servername "${d}" </dev/null >/dev/null 2>&1; then
            local cost=$(( $(date +%s%3N) - start ))
            echo -e "[SNI] $d -> ${cost}ms"
        fi
    done
}

# ================== 菜单逻辑 ==================
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
    echo -e "${GREEN} 4. 修改配置 (回车保持不变)${RESET}"
    echo -e "${GREEN} 5. 启动 Xray${RESET}"
    echo -e "${GREEN} 6. 停止 Xray${RESET}"
    echo -e "${GREEN} 7. 重启 Xray${RESET}"
    echo -e "${GREEN} 8. 查看实时日志${RESET}"
    echo -e "${GREEN} 9. 查看分享链接${RESET}"
    echo -e "${GREEN}10. 配置 Socks5 出口${RESET}"
    echo -e "${GREEN}11. SNI 域名优选✨${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

while true; do
    show_menu
    read -p "请输入选项: " choice
    case $choice in
        1|2) install_xray; pause ;;
        3) 
            rc-service xray stop 2>/dev/null
            rc-update del xray default 2>/dev/null
            rm -rf "$X_DIR" "$X_BIN" /etc/init.d/xray "$X_LINK" "$X_LOG"
            info "卸载完成"; pause ;;
        4) modify_config; pause ;;
        5) rc-service xray start; pause ;;
        6) rc-service xray stop; pause ;;
        7) rc-service xray restart; pause ;;
        8) 
            if [[ -f "$X_LOG" ]]; then
                echo -e "${YELLOW}查看日志 (Ctrl+C 退出):${RESET}"
                tail -f "$X_LOG"
            else error "日志文件不存在"; pause; fi ;;
        9) 
            if [[ -f "$X_LINK" ]]; then
                echo -e "\n${YELLOW}分享链接:${RESET}"
                cat "$X_LINK"
                echo -e "\n${YELLOW}公钥 (pbk):${RESET} $(cat "$X_PBK" 2>/dev/null)"
            else error "节点未配置"; fi
            pause ;;
        10) config_socks; pause ;;
        11) sni_select; pause ;;
        0) exit 0 ;;
        *) error "无效选项"; sleep 1 ;;
    esac
done
