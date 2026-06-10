#!/bin/bash

# =========================================================
# Xray VLESS-HTTPUpgrade 管理脚本(Alpine Linux) 
# =========================================================

set -Eeuo pipefail

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ================== GITHUB 代理加速池 ==================
readonly GITHUB_PROXY=(
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
    '' # 留空代表直连，作为兜底保底
)

# ================== 🚀 服务自定义重命名 ==================
readonly SERV_NAME="xray-httpupgrade"

# ================== 📂 自定义分享链接存放路径 ==================
readonly X_LINK_DIR="/root/proxynode/vlesshttpupgrade"

# ================== 路径与日志 (自动联动) ==================
readonly X_DIR="/etc/${SERV_NAME}"
readonly X_CONFIG="${X_DIR}/config.json"
readonly X_BIN="/usr/local/bin/${SERV_NAME}"
readonly X_LINK="${X_LINK_DIR}/${SERV_NAME}_vless.txt"
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
    # 修复：默认改为 auto 自动识别，纯 v6 机器也能正常获取 v6 IP
    local mode=${1:-"auto"} 
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
        # auto 模式：双栈环境优先获取 IPv4，纯 v6 环境自动 fallback 到 v6
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        # 如果获取 v4 失败，说明可能是纯 v6 机器，尝试获取 v6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    # 兜底处理：所有接口都失败时，直接输出 127.0.0.1，不报错
    echo "127.0.0.1" && return 0
}

HOSTNAME=$(hostname -s | sed 's/ /_/g')

# ================== 配置写入 ==================
write_config() {
    local port=$1 uuid=$2 path=$3 host_name=$4
    local outbound=${5:-'{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}'}
    mkdir -p "$X_DIR" && chmod 755 "$X_DIR"
    
    # 修复：显式加入 "listen": "::"，完美确保同时监听 IPv4 和 IPv6 端口
    cat > "$X_CONFIG" <<EOF
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "listen": "::",
        "port": $port,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$uuid"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "httpupgrade",
            "security": "none",
            "httpupgradeSettings": {
                "path": "$path",
                "host": "$host_name"
            }
        },
        "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }],
    "outbounds": [$outbound]
}
EOF
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
    local curr_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$X_CONFIG")
    local curr_path=$(jq -r '.inbounds[0].streamSettings.httpupgradeSettings.path // "/"' "$X_CONFIG")
    local curr_host=$(jq -r '.inbounds[0].streamSettings.httpupgradeSettings.host // ""' "$X_CONFIG")
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

    # 3. 修改 Path
    read -p "请输入新 HTTPUpgrade Path (回车保持 $curr_path): " n_path
    n_path=${n_path:-$curr_path}
    [[ "$n_path" != /* ]] && n_path="/${n_path}"

    # 4. 修改 Host
    read -p "请输入新伪装 Host/域名 (如果没有直接回车，保持 '$curr_host'): " n_host
    n_host=${n_host:-$curr_host}

    write_config "$n_port" "$n_uuid" "$n_path" "$n_host" "$curr_outbound"
    rc-service "$SERV_NAME" restart
    
    # 重新生成链接
    local ip=$(get_public_ip)
    local host_addr=$ip
    if [[ -n "$n_host" ]]; then
        host_addr=$n_host
    elif [[ "$host_addr" == *":"* ]]; then
        # 修复：如果是 IPv6 地址，URL 中必须加方括号 []
        host_addr="[$host_addr]"
    fi
    
    mkdir -p "$X_LINK_DIR"
    echo "vless://$n_uuid@$host_addr:$n_port?encryption=none&type=httpupgrade&security=none&host=$(echo "$n_host" | jq -sRr @uri)&path=$(echo "$n_path" | jq -sRr @uri)#$HOSTNAME-${SERV_NAME}" > "$X_LINK"
    info "配置已更新并成功重启服务！"
}

# ================== 安装与管理 ==================
install_xray() {
    info "正在安装依赖与内核..."
    apk add curl unzip jq uuidgen gcompat libc6-compat bc > /dev/null 2>&1
    mkdir -p "$X_DIR" && sync
    
    local arch=$(uname -m | sed 's/x86_64/64/;s/aarch64/arm64-v8a/')
    local ver=""

    info "正在检索 Xray-core 官方最新发布版本..."
    for proxy in "${GITHUB_PROXY[@]}"; do
        local api_url="${proxy}https://api.github.com/repos/XTLS/Xray-core/releases/latest"
        ver=$(wget -qO- --timeout=5 --tries=1 --no-check-certificate "$api_url" | jq -r .tag_name 2>/dev/null || echo "")
        if [[ -n "$ver" && "$ver" != "null" ]]; then
            break
        fi
    done

    if [[ -z "$ver" || "$ver" == "null" ]]; then
        ver="v26.3.27"
        warn "通过 API 获取版本号超时，已激活保底机制，将为您安装高稳定版本: $ver"
    fi

    info "下载 Xray $ver ($arch)..."
    
    local download_success=false
    for proxy in "${GITHUB_PROXY[@]}"; do
        local dl_url="${proxy}https://github.com/XTLS/Xray-core/releases/download/$ver/Xray-linux-$arch.zip"
        
        if wget --no-check-certificate --timeout=15 --tries=1 -q -O /tmp/xray.zip "$dl_url" 2>/dev/null; then
            if [ -s /tmp/xray.zip ]; then
                download_success=true
                break
            fi
        fi
        warn "当前下载节点响应失败，正在为您自动切换下一个 GitHub 代理..."
    done

    if [ "$download_success" = false ]; then
        error "严重错误：所有代理节点及直连模式均下载失败，请检查 VPS 的 DNS 设置！"
        return 1
    fi

    # 解压与部署
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

        # 2. 自定义 HTTPUpgrade Path
        local path
        echo -ne "${GREEN}请输入自定义 httpupgrade Path (回车默认随机生成): ${RESET}"; read path
        if [[ -z "$path" ]]; then
            path="/$(openssl rand -hex 4)"
            info "👉 采用随机 Path: $path"
        else
            [[ "$path" != /* ]] && path="/${path}"
        fi
        
        # 3. 配置伪装 Host
        echo -ne "${GREEN}请输入可选的伪装 Host 域名 (没有直接回车): ${RESET}"; read host_name
        
        write_config "$port" "$uuid" "$path" "$host_name"
        
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
    local ip=$(get_public_ip)
    local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$X_CONFIG")
    local port=$(jq -r '.inbounds[0].port' "$X_CONFIG")
    local path=$(jq -r '.inbounds[0].streamSettings.httpupgradeSettings.path // "/"' "$X_CONFIG")
    local host_name=$(jq -r '.inbounds[0].streamSettings.httpupgradeSettings.host // ""' "$X_CONFIG")
    
    local host_addr=$ip
    if [[ -n "$host_name" ]]; then
        host_addr=$host_name
    elif [[ "$host_addr" == *":"* ]]; then
        # 修复：纯 IPv6 链接拼接，为 IP 加上 []
        host_addr="[$host_addr]"
    fi
    
    local link="vless://$uuid@$host_addr:$port?encryption=none&type=httpupgrade&security=none&host=$(echo "$host_name" | jq -sRr @uri)&path=$(echo "$path" | jq -sRr @uri)#$HOSTNAME-vless-httpupgrade"
    
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

    local ip uuid port host_name path outbound_mode
    ip=$(get_public_ip)
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$X_CONFIG" 2>/dev/null || echo "未知")
    port=$(jq -r '.inbounds[0].port' "$X_CONFIG" 2>/dev/null || echo "未知")
    path=$(jq -r '.inbounds[0].streamSettings.httpupgradeSettings.path // "/"' "$X_CONFIG" 2>/dev/null || echo "/")
    host_name=$(jq -r '.inbounds[0].streamSettings.httpupgradeSettings.host // "无"' "$X_CONFIG" 2>/dev/null || echo "无")
    
    local current_protocol=$(jq -r '.outbounds[0].protocol // "freedom"' "$X_CONFIG" 2>/dev/null || echo "freedom")
    [[ "$current_protocol" == "socks" ]] && outbound_mode="Socks5 链式代理" || outbound_mode="直连 (Freedom)"

    echo -e "\n${GREEN}====== 当前配置详情 ======${RESET}"
    echo -e "${YELLOW}安全传输    : none ${RESET}"
    echo -e "${YELLOW}IP地址      : ${ip}${RESET}"
    echo -e "${YELLOW}端口        : ${port}${RESET}"
    echo -e "${YELLOW}UUID        : ${uuid}${RESET}"
    echo -e "${YELLOW}Host 伪装   : ${host_name}${RESET}"
    echo -e "${YELLOW}HTTPUpgrade Path : ${path}${RESET}"
    echo -e "${YELLOW}出口模式    : ${outbound_mode}${RESET}"
    echo -e "${YELLOW}分享存放路径: ${X_LINK}${RESET}"
    
    if [[ -f "$X_LINK" ]]; then
        echo -e "${GREEN}====== 👉 v2rayN 分享链接 ======${RESET}"
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
    echo -e "${GREEN}  Xray Vless-httpupgrade 面板   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 Xray Vless-httpupgrade${RESET}"
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
            rm -rf "$X_DIR" "$X_BIN" "$INIT_FILE" "$X_LINK" "$X_LOG" "$X_LINK_DIR"
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
