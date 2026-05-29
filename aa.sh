#!/bin/bash

# =========================================================
# Hysteria 2 管理脚本 (Alpine Linux )
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

# 🛠 修复版本抓取：强制重定向并精简匹配
get_version() {
    if [[ -x "$HY_BIN" ]]; then
        local ver=$($HY_BIN version 2>&1 | grep -iE "v[0-9]+\.[0-9]+" | head -n 1 | grep -oE "v[0-9]+\.[0-9]+\.[0-9]+")
        echo "${ver:-未知}"
    else
        echo "未安装"
    fi
}

# 🛠 修复跳跃显示：直接读取 nat 表最新状态
get_jump_ports() {
    local ports=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "DNAT" | grep -oE "[0-9]+:[0-9]+" | head -n 1)
    [[ -z "$ports" ]] && echo -e "${YELLOW}未配置${RESET}" || echo -e "${YELLOW}${ports}${RESET}"
}

# 公网IP获取
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

# ================== UDP 跳跃管理 (核心修复) ==================
manage_udp_jump() {
    local action=$1
    local start=${2:-""}
    local end=${3:-""}
    local target_port=${4:-""}
    
    # 彻底清理所有旧的 DNAT 规则（根据关键字 Hysteria 端口或目的地址）
    local server_ip=$(ip -4 addr show | awk '/inet/ && $2 !~ /^127/ {split($2,a,"/"); print a[1]; exit}')
    
    # 循环删除直到没有匹配规则
    while iptables -t nat -L PREROUTING -n | grep -q "to:${server_ip}"; do
        local line_num=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "to:${server_ip}" | head -n 1 | awk '{print $1}')
        [[ -z "$line_num" ]] && break
        iptables -t nat -D PREROUTING "$line_num"
    done

    if [ "$action" == "add" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        iptables -t nat -I PREROUTING 1 -p udp --dport "${start}:${end}" -j DNAT --to-destination "${server_ip}:${target_port}"
        # 放行 FORWARD
        iptables -I FORWARD 1 -p udp --dport "$target_port" -j ACCEPT 2>/dev/null || true
        # 保存规则
        iptables-save > /etc/iptables.rules
        echo -e "#!/bin/sh\n[ -f /etc/iptables.rules ] && iptables-restore < /etc/iptables.rules" > /etc/local.d/udp_jump.start
        chmod +x /etc/local.d/udp_jump.start
        rc-update add local default >/dev/null 2>&1
    elif [ "$action" == "remove" ]; then
        rm -f /etc/iptables.rules /etc/local.d/udp_jump.start
    fi
}

# ================== 安装与配置 ==================
install_hy2() {
    local mode=$1 # 1:安装, 2:更新, 3:修改配置
    apk update && apk add curl ca-certificates openssl openrc iptables jq > /dev/null 2>&1
    local arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    
    # 获取版本并安装
    local ver=$(curl -sSL https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
    info "正在处理 Hysteria 2 $ver..."
    curl -fSL "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-$arch" -o "${HY_BIN}.new"
    chmod +x "${HY_BIN}.new"
    rc-service hysteria stop 2>/dev/null || true
    mv "${HY_BIN}.new" "$HY_BIN"

    # 更新模式直接跳过配置
    if [ "$mode" == "2" ] && [[ -f "$HY_CONFIG" ]]; then
        info "程序已更新至最新版。"
    else
        # 安装或修改模式：先清理旧跳跃规则
        manage_udp_jump "remove"
        
        mkdir -p "$HY_DIR"
        read -rp "$(echo -e ${GREEN}"请输入主监听端口 (默认随机): "${RESET})" main_port
        main_port=${main_port:-$((RANDOM % 45535 + 20000))}
        local pass=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
        
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
        echo -e "${YELLOW}是否配置新的 UDP 端口跳跃? (直接回车跳过)${RESET}"
        read -rp "$(echo -e ${GREEN}"设置起始端口(建议10000-65535): "${RESET})" firstport
        if [[ -n "$firstport" ]]; then
            read -rp "$(echo -e ${GREEN}"设置末尾端口(必须大于起始端口): "${RESET})" endport
            if [[ "$endport" -gt "$firstport" ]]; then
                manage_udp_jump "add" "$firstport" "$endport" "$main_port"
            fi
        fi
    fi

    # 写入服务并启动
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

    local ip=$(get_public_ip)
    local p=$(grep 'listen:' "$HY_CONFIG" | cut -d':' -f3)
    local pw=$(grep 'password:' "$HY_CONFIG" | awk '{print $2}')
    local link="hysteria2://$pw@$ip:$p/?insecure=1&sni=www.bing.com#$(hostname)-hy2"
    echo "$link" > "$HY_NODE_FILE"

    echo -e "\n${GREEN}================ Hysteria 2 节点信息 ==================${RESET}"
    echo -e "${GREEN}====== 👉 v2rayN 链接 ======${RESET}"
    echo -e "${YELLOW}${link}${RESET}"
    echo -e "${GREEN}====== 👉 Surge 配置 ======${RESET}"
    echo -e "${YELLOW}$HOSTNAME-hy2 = hysteria2, $ip, $p, password=$pw, skip-cert-verify=true, sni=www.bing.com"
    echo -e "${GREEN}======================================================${RESET}"
}

# ================== 修改配置函数 (独立) ==================
modify_config() {
    if [[ ! -f "$HY_CONFIG" ]]; then
        error "未检测到配置文件，请先安装 Hysteria 2"
        return 1
    fi

    # 1. 读取当前配置
    local current_port=$(grep 'listen:' "$HY_CONFIG" | cut -d':' -f3)
    local current_pass=$(grep 'password:' "$HY_CONFIG" | awk '{print $2}')
    local current_jump=$(get_jump_ports)
    local current_start=""
    local current_end=""
    [[ -n "$current_jump" ]] && current_start=$(echo "$current_jump" | cut -d':' -f1) && current_end=$(echo "$current_jump" | cut -d':' -f2)

    echo -e "${YELLOW}--- 修改 Hysteria 2 配置 (回车保持默认) ---${RESET}"

    # 2. 修改主端口
    read -rp "$(echo -e ${GREEN}"设置主端口 (当前: $current_port): "${RESET})" new_port
    new_port=${new_port:-$current_port}

    # 3. 修改密码
    read -rp "$(echo -e ${GREEN}"设置密码 (当前: $current_pass): "${RESET})" new_pass
    new_pass=${new_pass:-$current_pass}

    # 4. 修改跳跃规则
    echo -e "${YELLOW}提示: 若需取消跳跃，请在起始端口输入 'off'${RESET}"
    read -rp "$(echo -e ${GREEN}"设置跳跃起始端口 (当前: ${current_start:-未设置}): "${RESET})" new_start
    new_start=${new_start:-$current_start}

    if [[ "$new_start" == "off" ]]; then
        manage_udp_jump "remove"
    elif [[ -n "$new_start" ]]; then
        read -rp "$(echo -e ${GREEN}"设置跳跃末尾端口 (当前: ${current_end:-未设置}): "${RESET})" new_end
        new_end=${new_end:-$current_end}
        
        if [[ -n "$new_end" && "$new_end" -gt "$new_start" ]]; then
            manage_udp_jump "add" "$new_start" "$new_end" "$new_port"
        else
            error "末尾端口必须大于起始端口，跳跃设置未变更。"
        fi
    fi

    # 5. 写入配置并重启
    sed -i "s/listen: :.*/listen: :$new_port/" "$HY_CONFIG"
    sed -i "s/password: .*/password: $new_pass/" "$HY_CONFIG"
    
    rc-service hysteria restart
    
    # 更新节点链接文件
    local ip=$(get_public_ip)
    local link="hysteria2://$new_pass@$ip:$new_port/?insecure=1&sni=www.bing.com#$(hostname)-hy2"
    echo "$link" > "$HY_NODE_FILE"
    
    info "配置修改成功并已重启服务！"
}

# ================== 显示详细配置 ==================
show_current_config() {
    if [[ ! -f "$HY_CONFIG" ]]; then
        error "配置文件不存在"
        return
    fi

    local ip port pass jump_ports
    ip=$(get_public_ip || echo "未知")
    port=$(grep 'listen:' "$HY_CONFIG" | cut -d':' -f3)
    pass=$(grep 'password:' "$HY_CONFIG" | awk '{print $2}')
    jump_ports=$(get_jump_ports)

    echo -e "\n${GREEN}====== Hysteria 2 当前配置 ======${RESET}"
    echo -e "${YELLOW}IP 地址      : ${ip}${RESET}"
    echo -e "${YELLOW}主端口       : ${port}${RESET}"
    echo -e "${YELLOW}连接密码     : ${pass}${RESET}"
    echo -e "${YELLOW}UDP 跳跃端口 : ${jump_ports:-未配置}${RESET}"
    
    if [[ -f "$HY_NODE_FILE" ]]; then
        echo -e "${GREEN}====== 👉 v2rayN 链接 ======${RESET}"
        cat "$HY_NODE_FILE"
        echo -e "${GREEN}====== 👉 Surge 配置 ======${RESET}"
        echo -e "${YELLOW}$HOSTNAME-hy2 = hysteria2, $ip, $port, password=$pass, skip-cert-verify=true, sni=www.bing.com"
        echo
    fi
}


# ================== 菜单系统 ==================
while true; do
    status=$(get_status)
    version=$(get_version)
    jump_show=$(get_jump_ports)
    port_show=$(grep 'listen:' "$HY_CONFIG" 2>/dev/null | cut -d':' -f3 || echo "-")

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
        3) 
            rc-service hysteria stop 2>/dev/null || true
            manage_udp_jump "remove"
            rm -rf "$HY_DIR" "$HY_BIN" /etc/init.d/hysteria "$HY_LOG" "$HY_NODE_FILE"
            info "已彻底卸载并清理规则"; pause ;;
        4) modify_config; pause ;;
        5) rc-service hysteria start; pause ;;
        6) rc-service hysteria stop; pause ;;
        7) rc-service hysteria restart; pause ;;
        8) [[ -f "$HY_LOG" ]] && tail -f "$HY_LOG" || error "日志不存在"; pause ;;
        9) show_current_config || error "未配置"; pause ;;
        0) exit 0 ;;
        *) error "无效选项"; sleep 1 ;;
    esac
done
