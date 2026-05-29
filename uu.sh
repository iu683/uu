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
error() { echo -e "${RED}[错误] $*${RESET}"; }
pause() { echo; echo -ne "${GREEN}按任意键返回菜单...${RESET}"; read -n 1 -s; echo; }

get_status() {
    if rc-service hysteria status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}● 运行中${RESET}"
    else echo -e "${RED}● 未运行${RESET}"; fi
}

get_version() {
    if [[ -x "$HY_BIN" ]]; then
        # 兼容 Hysteria 2 的版本输出格式
        "$HY_BIN" version 2>/dev/null | head -n 1 | awk '{print $3}' || echo "未知"
    else echo "未安装"; fi
}

get_jump_ports() {
    local ports=$(iptables-save -t nat | grep "PREROUTING" | grep "DNAT" | grep -oE "[0-9]+:[0-9]+" | head -n 1)
    [[ -z "$ports" ]] && echo -e "${YELLOW}未配置${RESET}" || echo -e "${YELLOW}${ports}${RESET}"
}

get_public_ip() {
    curl -4fsSL --max-time 5 https://api.ipify.org || echo "YOUR_SERVER_IP"
}

# ================== UDP 跳跃逻辑 ==================
manage_udp_jump() {
    local action=$1
    local start=${2:-""}
    local end=${3:-""}
    local target_port=${4:-""}
    local server_ip=$(ip -4 addr show | awk '/inet/ && $2 !~ /^127/ {split($2,a,"/"); print a[1]; exit}')

    # 清理旧规则
    for rule in $(iptables-save | grep "DNAT" | grep "$server_ip" | awk '{print $0}'); do
        del_rule=$(echo "$rule" | sed 's/^-A /-D /')
        eval iptables -t nat $del_rule 2>/dev/null || true
    done

    if [ "$action" == "add" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        iptables -t nat -I PREROUTING 1 -p udp --dport "${start}:${end}" -j DNAT --to-destination "${server_ip}:${target_port}"
        iptables -I FORWARD 1 -p udp --dport "$target_port" -j ACCEPT 2>/dev/null || true
        iptables-save > /etc/iptables.rules
        echo -e "#!/bin/sh\n[ -f /etc/iptables.rules ] && iptables-restore < /etc/iptables.rules" > /etc/local.d/udp_jump.start
        chmod +x /etc/local.d/udp_jump.start
        rc-update add local default >/dev/null 2>&1
    fi
}

# ================== 安装/更新/配置逻辑 ==================
install_hy2() {
    local mode=$1 # 1:安装, 2:更新, 3:修改配置
    apk update && apk add curl ca-certificates openssl openrc iptables jq > /dev/null 2>&1
    local arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    local ver=$(curl -sSL https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
    
    info "正在下载 Hysteria 2 $ver..."
    curl -fSL "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-$arch" -o "${HY_BIN}.new"
    chmod +x "${HY_BIN}.new"
    rc-service hysteria stop 2>/dev/null || true
    mv "${HY_BIN}.new" "$HY_BIN"

    # 如果是更新且配置已存在，则直接跳到服务重启
    if [ "$mode" == "2" ] && [[ -f "$HY_CONFIG" ]]; then
        info "程序更新完成，保持原配置启动..."
    else
        # 安装或修改配置模式
        mkdir -p "$HY_DIR"
        read -rp "$(echo -e ${GREEN}"请输入主监听端口 (默认随机): "${RESET})" main_port
        main_port=${main_port:-$((RANDOM % 45535 + 20000))}
        local pass=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
        
        # 证书生成
        openssl req -x509 -nodes -newkey rsa:2048 -keyout "${HY_DIR}/server.key" -out "${HY_DIR}/server.crt" -subj "/CN=www.bing.com" -days 3650 >/dev/null 2>&1
        
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
        # 端口跳跃设置
        echo -e "${YELLOW}是否配置 UDP 端口跳跃? (直接回车跳过)${RESET}"
        read -rp "$(echo -e ${GREEN}"设置起始端口 (建议10000-65535): "${RESET})" firstport
        if [[ -n "$firstport" ]]; then
            read -rp "$(echo -e ${GREEN}"设置末尾端口 (必须大于起始端口): "${RESET})" endport
            if [[ "$endport" -gt "$firstport" ]]; then
                manage_udp_jump "add" "$firstport" "$endport" "$main_port"
            else
                error "末尾端口错误，跳过跳跃设置。"
            fi
        fi
    fi

    # 写入 OpenRC 服务文件
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

    # 生成并显示节点信息
    local ip=$(get_public_ip)
    local p=$(grep 'listen:' "$HY_CONFIG" | cut -d':' -f3)
    local pw=$(grep 'password:' "$HY_CONFIG" | awk '{print $2}')
    local link="hysteria2://$pw@$ip:$p/?insecure=1&sni=www.bing.com#$(hostname)"
    echo "$link" > "$HY_NODE_FILE"

    echo -e "\n${GREEN}================ Hysteria 2 节点信息 ==================${RESET}"
    echo -e "${YELLOW}${link}${RESET}"
    echo -e "${GREEN}======================================================${RESET}"
}

# ================== 菜单循环 ==================
while true; do
    status=$(get_status)
    version=$(get_version)
    jump_show=$(get_jump_ports)
    port_show="-"
    [[ -f "$HY_CONFIG" ]] && port_show=$(grep 'listen:' "$HY_CONFIG" | cut -d':' -f3)

    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Hysteria 2 管理面板       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}跳跃   :${RESET} $jump_show"
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

    read -rp "$(echo -e ${GREEN}"请输入选项: "${RESET})" choice
    case $choice in
        1) install_hy2 1; pause ;;
        2) install_hy2 2; pause ;;
        3) rc-service hysteria stop 2>/dev/null || true; manage_udp_jump "remove"; rm -rf "$HY_DIR" "$HY_BIN" /etc/init.d/hysteria "$HY_LOG" "$HY_NODE_FILE"; info "卸载完成"; pause ;;
        4) install_hy2 3; pause ;;
        5) rc-service hysteria start; pause ;;
        6) rc-service hysteria stop; pause ;;
        7) rc-service hysteria restart; pause ;;
        8) [[ -f "$HY_LOG" ]] && tail -f "$HY_LOG" || error "无日志"; pause ;;
        9) [[ -f "$HY_NODE_FILE" ]] && info "节点链接:\n${YELLOW}$(cat "$HY_NODE_FILE")${RESET}" || error "无配置"; pause ;;
        0) exit 0 ;;
        *) error "无效选项"; sleep 1 ;;
    esac
done
