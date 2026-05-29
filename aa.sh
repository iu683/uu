#!/bin/bash

# =========================================================
# Hysteria 2 管理脚本 (Alpine Linux - 交互增强版)
# =========================================================

set -Eeuo pipefail

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ================== 路径定义 ==================
readonly HY_DIR="/etc/hysteria"
readonly HY_CONFIG="${HY_DIR}/config.yaml"
readonly HY_BIN="/usr/local/bin/hysteria"
readonly HY_LOG="/var/log/hysteria.log"
readonly HY_NODE_FILE="${HY_DIR}/node.txt"

# ================== 工具函数 ==================
info() { echo -e "${GREEN}[信息] $*${RESET}"; }
error() { echo -e "${RED}[错误] $*${RESET}"; }
pause() { echo; echo -ne "${GREEN}按任意键返回菜单...${RESET}"; read -n 1 -s; echo; }

get_status() {
    if rc-service hysteria status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}● 运行中${RESET}"
    else echo -e "${RED}● 未运行${RESET}"; fi
}

get_version() {
    if [[ -x "$HY_BIN" ]]; then
        local ver=$($HY_BIN version 2>&1 | grep -iE "v[0-9]+\.[0-9]+" | head -n 1 | grep -oE "v[0-9]+\.[0-9]+\.[0-9]+")
        echo "${ver:-未知}"
    else echo "未安装"; fi
}

get_jump_ports() {
    local ports=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "DNAT" | grep -oE "[0-9]+:[0-9]+" | head -n 1)
    [[ -z "$ports" ]] && echo "" || echo "$ports"
}

get_public_ip() {
    curl -4fsSL --max-time 5 https://api.ipify.org || echo "YOUR_SERVER_IP"
}

# ================== UDP 跳跃管理 ==================
manage_udp_jump() {
    local action=$1
    local start=${2:-""}
    local end=${3:-""}
    local target_port=${4:-""}
    local server_ip=$(ip -4 addr show | awk '/inet/ && $2 !~ /^127/ {split($2,a,"/"); print a[1]; exit}')
    
    # 清理旧规则
    while iptables -t nat -L PREROUTING -n | grep -q "to:${server_ip}"; do
        local line_num=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "to:${server_ip}" | head -n 1 | awk '{print $1}')
        [[ -z "$line_num" ]] && break
        iptables -t nat -D PREROUTING "$line_num"
    done

    if [ "$action" == "add" ] && [[ -n "$start" ]] && [[ -n "$end" ]]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        iptables -t nat -I PREROUTING 1 -p udp --dport "${start}:${end}" -j DNAT --to-destination "${server_ip}:${target_port}"
        iptables -I FORWARD 1 -p udp --dport "$target_port" -j ACCEPT 2>/dev/null || true
        iptables-save > /etc/iptables.rules
        echo -e "#!/bin/sh\n[ -f /etc/iptables.rules ] && iptables-restore < /etc/iptables.rules" > /etc/local.d/udp_jump.start
        chmod +x /etc/local.d/udp_jump.start
        rc-update add local default >/dev/null 2>&1
    fi
}

# ================== 核心安装/配置函数 ==================
configure_hy2() {
    local mode=$1 # 1:安装, 2:修改
    local old_port=""
    local old_jump=""
    local old_pass=""

    # 如果是修改模式，先读取现有值
    if [[ -f "$HY_CONFIG" ]]; then
        old_port=$(grep 'listen:' "$HY_CONFIG" | cut -d':' -f3)
        old_pass=$(grep 'password:' "$HY_CONFIG" | awk '{print $2}')
        old_jump=$(get_jump_ports)
    fi

    # 1. 端口输入
    local prompt_port="请输入主监听端口"
    [[ -n "$old_port" ]] && prompt_port="请输入主监听端口 (当前: $old_port)"
    read -rp "$(echo -e ${GREEN}"$prompt_port: "${RESET})" main_port
    main_port=${main_port:-${old_port:-$((RANDOM % 45535 + 20000))}}

    # 2. 密码处理 (修改模式保留旧密码，安装模式生成新密码)
    local pass=${old_pass:-$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)}

    # 3. 端口跳跃输入
    local old_start=""
    local old_end=""
    [[ -n "$old_jump" ]] && old_start=$(echo $old_jump | cut -d':' -f1) && old_end=$(echo $old_jump | cut -d':' -f2)

    local prompt_start="设置跳跃起始端口"
    [[ -n "$old_start" ]] && prompt_start="设置跳跃起始端口 (当前: $old_start)"
    read -rp "$(echo -e ${GREEN}"$prompt_start (留空跳过): "${RESET})" firstport
    firstport=${firstport:-$old_start}

    if [[ -n "$firstport" ]]; then
        local prompt_end="设置跳跃末尾端口"
        [[ -n "$old_end" ]] && prompt_end="设置跳跃末尾端口 (当前: $old_end)"
        read -rp "$(echo -e ${GREEN}"$prompt_end: "${RESET})" endport
        endport=${endport:-$old_end}
        
        if [[ "$endport" -gt "$firstport" ]]; then
            manage_udp_jump "add" "$firstport" "$endport" "$main_port"
        else
            error "末尾端口无效，未设置跳跃规则。"
        fi
    else
        manage_udp_jump "remove"
    fi

    # 4. 写入文件
    mkdir -p "$HY_DIR"
    [[ ! -f "${HY_DIR}/server.crt" ]] && openssl req -x509 -nodes -newkey rsa:2048 -keyout "${HY_DIR}/server.key" -out "${HY_DIR}/server.crt" -subj "/CN=www.bing.com" -days 3650 >/dev/null 2>&1
    
    cat <<EOF > "$HY_CONFIG"
listen: :$main_port
tls:
  cert: ${HY_DIR}/server.crt
  key: ${HY_DIR}/server.key
auth:
  type: password
  password: $pass
masquerade:
  type: proxy
  proxy:
    url: https://bing.com/
    rewriteHost: true
EOF

    rc-service hysteria restart
    local ip=$(get_public_ip)
    local link="hysteria2://$pass@$ip:$main_port/?insecure=1&sni=www.bing.com#$(hostname)"
    echo "$link" > "$HY_NODE_FILE"
    echo -e "\n${GREEN}配置完成！节点信息如下:${RESET}"
    echo -e "${YELLOW}${link}${RESET}"
}

# ================== 菜单系统 ==================
while true; do
    status=$(get_status)
    version=$(get_version)
    jump_raw=$(get_jump_ports)
    jump_show=${jump_raw:-"未配置"}
    port_show=$(grep 'listen:' "$HY_CONFIG" 2>/dev/null | cut -d':' -f3 || echo "-")

    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Hysteria 2 管理面板       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}跳跃   :${RESET} ${YELLOW}${jump_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Hysteria 2${RESET}"
    echo -e "${GREEN}2. 更新 Hysteria 2 (仅更新程序)${RESET}"
    echo -e "${GREEN}3. 卸载 Hysteria 2${RESET}"
    echo -e "${GREEN}4. 修改配置 (端口/跳跃)${RESET}"
    echo -e "${GREEN}5. 启动 Hysteria 2${RESET}"
    echo -e "${GREEN}6. 停止 Hysteria 2${RESET}"
    echo -e "${GREEN}7. 重启 Hysteria 2${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"

    read -rp "$(echo -e ${GREEN}"请输入选项: "${RESET})" choice
    case $choice in
        1) 
            apk update && apk add curl ca-certificates openssl openrc iptables jq > /dev/null 2>&1
            local arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
            local ver=$(curl -sSL https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
            curl -fSL "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-$arch" -o "$HY_BIN"
            chmod +x "$HY_BIN"
            configure_hy2 1; pause ;;
        2) 
            local arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
            curl -fSL "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-$arch" -o "${HY_BIN}.new"
            chmod +x "${HY_BIN}.new"
            rc-service hysteria stop 2>/dev/null || true
            mv "${HY_BIN}.new" "$HY_BIN"
            rc-service hysteria start
            info "程序已更新并重启"; pause ;;
        3) 
            rc-service hysteria stop 2>/dev/null || true
            manage_udp_jump "remove"
            rm -rf "$HY_DIR" "$HY_BIN" /etc/init.d/hysteria "$HY_LOG" "$HY_NODE_FILE"
            info "彻底卸载完成"; pause ;;
        4) configure_hy2 2; pause ;;
        5) rc-service hysteria start; pause ;;
        6) rc-service hysteria stop; pause ;;
        7) rc-service hysteria restart; pause ;;
        8) [[ -f "$HY_LOG" ]] && tail -f "$HY_LOG" || error "日志不存在"; pause ;;
        9) [[ -f "$HY_NODE_FILE" ]] && info "节点链接:\n${YELLOW}$(cat "$HY_NODE_FILE")${RESET}" || error "未配置"; pause ;;
        0) exit 0 ;;
        *) error "无效选项"; sleep 1 ;;
    esac
done
