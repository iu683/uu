#!/bin/bash

# =========================================================
# Hysteria 2 管理脚本 
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
warn() { echo -e "${GREEN}[警告] $*${RESET}"; }
error() { echo -e "${GREEN}[错误] $*${RESET}"; }
pause() { echo; echo -ne "${GREEN}按任意键返回菜单...${RESET}"; read -n 1 -s; echo; }

get_status() {
    if rc-service hysteria status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}● 运行中${RESET}"
    else echo -e "${RED}● 未运行${RESET}"; fi
}

get_version() {
    [[ -x "$HY_BIN" ]] && "$HY_BIN" version 2>/dev/null | head -n 1 | awk '{print $3}' || echo "未安装"
}

get_public_ip() {
    curl -4fsSL --max-time 5 https://api.ipify.org || echo "YOUR_SERVER_IP"
}

# ================== 核心功能 ==================

# 端口跳跃规则管理
manage_udp_jump() {
    local action=$1 # add/remove
    local start=${2:-""}
    local end=${3:-""}
    local target_port=${4:-""}
    
    local server_ip=$(ip -4 addr show | awk '/inet/ && $2 !~ /^127/ {split($2,a,"/"); print a[1]; exit}')

    if [ "$action" == "remove" ]; then
        for rule in $(iptables-save | grep "DNAT" | grep "$server_ip" | awk '{print $0}'); do
            del_rule=$(echo "$rule" | sed 's/^-A /-D /')
            eval iptables -t nat $del_rule 2>/dev/null || true
        done
        rm -f /etc/iptables.rules /etc/local.d/udp_jump.start
    elif [ "$action" == "add" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        iptables -t nat -I PREROUTING 1 -p udp --dport "$start:$end" -j DNAT --to-destination "${server_ip}:$target_port"
        iptables -I FORWARD 1 -p udp --dport "$target_port" -j ACCEPT 2>/dev/null || true
        iptables-save > /etc/iptables.rules
        echo -e "#!/bin/sh\n[ -f /etc/iptables.rules ] && iptables-restore < /etc/iptables.rules" > /etc/local.d/udp_jump.start
        chmod +x /etc/local.d/udp_jump.start
        rc-update add local default >/dev/null 2>&1
    fi
}

# 安装/更新
install_hy2() {
    local type=$1 # 1:install, 2:update
    info "正在安装依赖与内核..."
    apk update && apk add curl ca-certificates openssl openrc iptables jq > /dev/null 2>&1

    local arch=$(uname -m)
    case $arch in
        x86_64) local bin_arch="amd64" ;;
        aarch64) local bin_arch="arm64" ;;
        *) error "不支持的架构: $arch"; return 1 ;;
    esac

    local ver=$(curl -sSL https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
    info "正在下载 Hysteria 2 $ver..."
    curl -fSL "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-$bin_arch" -o "${HY_BIN}.new"
    chmod +x "${HY_BIN}.new"
    rc-service hysteria stop 2>/dev/null || true
    mv "${HY_BIN}.new" "$HY_BIN"

    if [ "$type" == "1" ] || [[ ! -f "$HY_CONFIG" ]]; then
        mkdir -p "$HY_DIR"
        echo -ne "${GREEN}请输入监听端口 (回车随机): ${RESET}"; read port; [[ -z "$port" ]] && port=$((RANDOM % 45535 + 20000))
        local pass=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
        openssl req -x509 -nodes -newkey rsa:2048 -keyout "${HY_DIR}/server.key" -out "${HY_DIR}/server.crt" -subj "/CN=www.bing.com" -days 3650 >/dev/null 2>&1
        
        cat <<EOF > "$HY_CONFIG"
listen: :$port
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
    fi

    # 写入服务控制
    cat <<EOF > /etc/init.d/hysteria
#!/sbin/openrc-run
name="hysteria2"
command="$HY_BIN"
command_args="server -c $HY_CONFIG"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="$HY_LOG"
error_log="$HY_LOG"
depend() { need net; }
EOF
    chmod +x /etc/init.d/hysteria
    rc-update add hysteria default >/dev/null 2>&1
    rc-service hysteria restart

    # 生成节点信息
    local ip=$(get_public_ip)
    local pass=$(grep 'password:' "$HY_CONFIG" | awk '{print $2}')
    local port=$(grep 'listen:' "$HY_CONFIG" | cut -d':' -f3)
    echo "hysteria2://$pass@$ip:$port/?insecure=1&sni=www.bing.com#$(hostname)" > "$HY_NODE_FILE"
    info "Hysteria 2 操作成功！"
}

# 修改配置
modify_config() {
    if [[ ! -f "$HY_CONFIG" ]]; then error "未检测到配置，请先安装"; return; fi
    local curr_port=$(grep 'listen:' "$HY_CONFIG" | cut -d':' -f3)
    local curr_pass=$(grep 'password:' "$HY_CONFIG" | awk '{print $2}')
    
    echo -ne "${GREEN}新端口 (回车保持 $curr_port): ${RESET}"; read n_port; n_port=${n_port:-$curr_port}
    echo -ne "${GREEN}新密码 (回车保持 $curr_pass): ${RESET}"; read n_pass; n_pass=${n_pass:-$curr_pass}
    
    sed -i "s/listen: :.*/listen: :$n_port/" "$HY_CONFIG"
    sed -i "s/password: .*/password: $n_pass/" "$HY_CONFIG"
    
    rc-service hysteria restart
    local ip=$(get_public_ip)
    echo "hysteria2://$n_pass@$ip:$n_port/?insecure=1&sni=www.bing.com#$(hostname)" > "$HY_NODE_FILE"
    info "配置已更新并重启服务！"
}

# ================== 菜单系统 ==================
while true; do
    status=$(get_status)
    version=$(get_version)
    port_show="-"
    [[ -f "$HY_CONFIG" ]] && port_show=$(grep 'listen:' "$HY_CONFIG" | cut -d':' -f3)

    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Hysteria 2 管理面板       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Hysteria 2${RESET}"
    echo -e "${GREEN}2. 更新 Hysteria 2${RESET}"
    echo -e "${GREEN}3. 卸载 Hysteria 2${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Hysteria 2${RESET}"
    echo -e "${GREEN}6. 停止 Hysteria 2${RESET}"
    echo -e "${GREEN}7. 重启 Hysteria 2${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"

    echo -ne "${GREEN}请输入选项: ${RESET}"; read choice
    case $choice in
        1) install_hy2 1; pause ;;
        2) install_hy2 2; pause ;;
        3) 
            rc-service hysteria stop 2>/dev/null || true
            rc-update del hysteria default 2>/dev/null || true
            manage_udp_jump "remove"
            rm -rf "$HY_DIR" "$HY_BIN" /etc/init.d/hysteria "$HY_LOG"
            info "已彻底卸载"; pause ;;
        4) modify_config; pause ;;
        5) rc-service hysteria start; pause ;;
        6) rc-service hysteria stop; pause ;;
        7) rc-service hysteria restart; pause ;;
        8) [[ -f "$HY_LOG" ]] && tail -f "$HY_LOG" || error "日志不存在"; pause ;;
        9) [[ -f "$HY_NODE_FILE" ]] && info "节点链接: ${YELLOW}$(cat "$HY_NODE_FILE")${RESET}" || error "无配置信息"; pause ;;
        0) exit 0 ;;
        *) error "无效选项"; sleep 1 ;;
    esac
done
