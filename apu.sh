#!/bin/sh
set -e

# ===============================
# Alpine Linux 防火墙管理脚本 (IPv4/IPv6)
# ===============================

GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

info() { echo -e "${GREEN}[INFO] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
error() { echo -e "${RED}[ERROR] $1${RESET}"; }

RULE_DIR="/etc/iptables"

# ===============================
# 获取 SSH 端口
# ===============================
get_ssh_port() {
    PORT=$(grep -E '^ *Port ' /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
    [ -z "$PORT" ] && PORT=22
    echo "$PORT"
}

# ===============================
# 保存规则
# ===============================
save_rules() {
    mkdir -p "$RULE_DIR"
    iptables-save > "$RULE_DIR/rules.v4" || true
    ip6tables-save > "$RULE_DIR/rules.v6" || true
}

# ===============================
# 恢复规则
# ===============================
restore_rules() {
    if [ -f "$RULE_DIR/rules.v4" ]; then
        iptables-restore < "$RULE_DIR/rules.v4" || true
    fi
    if [ -f "$RULE_DIR/rules.v6" ]; then
        ip6tables-restore < "$RULE_DIR/rules.v6" || true
    fi
    info "✅ 防火墙规则已恢复"
}

# ===============================
# 初始化防火墙规则
# ===============================
init_rules() {
    SSH_PORT=$(get_ssh_port)
    for proto in iptables ip6tables; do
        $proto -F
        $proto -X
        $proto -t nat -F 2>/dev/null || true
        $proto -t nat -X 2>/dev/null || true
        $proto -t mangle -F 2>/dev/null || true
        $proto -t mangle -X 2>/dev/null || true
        $proto -P INPUT DROP
        $proto -P FORWARD DROP
        $proto -P OUTPUT ACCEPT
        $proto -A INPUT -i lo -j ACCEPT
        $proto -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        $proto -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
        $proto -A INPUT -p tcp --dport 80 -j ACCEPT
        $proto -A INPUT -p tcp --dport 443 -j ACCEPT
        [ "$proto" = "ip6tables" ] && $proto -A INPUT -p icmpv6 -j ACCEPT
    done
    save_rules
    info "✅ 默认规则已初始化，放行 SSH/80/443"
    read -r -p "按回车返回菜单..."
}

# ===============================
# 安装必要工具（只在缺少时安装）
# ===============================
install_firewall_tools() {
    FIRST_INSTALL=0
    NEED_INSTALL=0
    for cmd in iptables ip6tables bash curl wget vim sudo git; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            NEED_INSTALL=1
            break
        fi
    done

    if [ "$NEED_INSTALL" -eq 1 ]; then
        FIRST_INSTALL=1
        info "检测到部分工具未安装，正在安装..."
        apk update
        apk add --no-cache iptables ip6tables bash curl wget vim sudo git || true
        mkdir -p "$RULE_DIR"
        info "✅ 防火墙工具安装完成"
    fi

    # 第一次运行恢复规则
    if [ -f "$RULE_DIR/rules.v4" ] || [ -f "$RULE_DIR/rules.v6" ]; then
        restore_rules
    fi

    echo "$FIRST_INSTALL"
}

# ===============================
# IP 规则操作
# ===============================
ip_action() {
    ACTION=$1
    IP=$2
    if ! echo "$IP" | grep -E -q '^[0-9a-fA-F:.]+$'; then
        warn "输入不是有效 IP"
        return
    fi
    for proto in iptables ip6tables; do
        case $ACTION in
            accept) $proto -I INPUT -s "$IP" -j ACCEPT ;;
            drop)   $proto -I INPUT -s "$IP" -j DROP ;;
            delete)
                while $proto -C INPUT -s "$IP" -j ACCEPT 2>/dev/null; do
                    $proto -D INPUT -s "$IP" -j ACCEPT
                done
                while $proto -C INPUT -s "$IP" -j DROP 2>/dev/null; do
                    $proto -D INPUT -s "$IP" -j DROP
                done
                ;;
        esac
    done
    save_rules
    info "✅ 操作完成: $ACTION $IP"
    read -r -p "按回车返回菜单..."
}

# ===============================
# 开放指定端口（TCP/UDP）
# ===============================
open_port() {
    read -r -p "请输入要开放的端口号: " PORT
    if ! echo "$PORT" | grep -E -q '^[0-9]+$'; then
        warn "无效端口"
        return
    fi
    for proto in iptables ip6tables; do
        $proto -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        $proto -I INPUT -p udp --dport "$PORT" -j ACCEPT
    done
    save_rules
    info "✅ 端口 $PORT 已开放 (TCP/UDP)"
    read -r -p "按回车返回菜单..."
}

# ===============================
# 关闭指定端口（TCP/UDP）
# ===============================
close_port() {
    read -r -p "请输入要关闭的端口号: " PORT
    if ! echo "$PORT" | grep -E -q '^[0-9]+$'; then
        warn "无效端口"
        return
    fi
    for proto in iptables ip6tables; do
        while $proto -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; do
            $proto -D INPUT -p tcp --dport "$PORT" -j ACCEPT
        done
        while $proto -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null; do
            $proto -D INPUT -p udp --dport "$PORT" -j ACCEPT
        done
    done
    save_rules
    info "✅ 端口 $PORT 已关闭 (TCP/UDP)"
    read -r -p "按回车返回菜单..."
}

# ===============================
# 禁止 PING
# ===============================
disable_ping() {
    for proto in iptables ip6tables; do
        if [ "$proto" = "iptables" ]; then
            while $proto -C INPUT -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null; do
                $proto -D INPUT -p icmp --icmp-type echo-request -j ACCEPT
            done
            while $proto -C OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT 2>/dev/null; do
                $proto -D OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT
            done
        else
            while $proto -C INPUT -p icmpv6 --icmpv6-type echo-request -j ACCEPT 2>/dev/null; do
                $proto -D INPUT -p icmpv6 --icmpv6-type echo-request -j ACCEPT
            done
            while $proto -C OUTPUT -p icmpv6 --icmpv6-type echo-reply -j ACCEPT 2>/dev/null; do
                $proto -D OUTPUT -p icmpv6 --icmpv6-type echo-reply -j ACCEPT
            done
        fi
    done
    save_rules
    info "✅ 已禁止 PING (ICMP)"
    read -r -p "按回车返回菜单..."
}

# ===============================
# 允许 PING
# ===============================
enable_ping() {
    for proto in iptables ip6tables; do
        if [ "$proto" = "iptables" ]; then
            $proto -I INPUT -p icmp --icmp-type echo-request -j ACCEPT
            $proto -I OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT
        else
            $proto -I INPUT -p icmpv6 --icmpv6-type echo-request -j ACCEPT
            $proto -I OUTPUT -p icmpv6 --icmpv6-type echo-reply -j ACCEPT
        fi
    done
    save_rules
    info "✅ 已允许 PING (ICMP)"
    read -r -p "按回车返回菜单..."
}

# ===============================
# 清空防火墙
# ===============================
clear_firewall() {
    for proto in iptables ip6tables; do
        $proto -F
        $proto -X
        $proto -P INPUT ACCEPT
        $proto -P FORWARD ACCEPT
        $proto -P OUTPUT ACCEPT
    done
    save_rules
    info "✅ 已清空防火墙规则，所有流量放行"
    read -r -p "按回车返回菜单..."
}

# ===============================
# 显示规则
# ===============================
show_rules() {
    echo "===== IPv4 ====="
    iptables -L -n --line-numbers
    echo "===== IPv6 ====="
    ip6tables -L -n --line-numbers
    read -r -p "按回车返回菜单..."
}

# ===============================
# 开机自启恢复规则
# ===============================
enable_autostart() {
    info "正在设置开机自动恢复防火墙规则..."
    mkdir -p /etc/local.d
    cat << 'EOF' > /etc/local.d/iptables.start
#!/bin/sh
if [ -f /etc/iptables/rules.v4 ]; then
    iptables-restore < /etc/iptables/rules.v4 || true
fi
if [ -f /etc/iptables/rules.v6 ]; then
    ip6tables-restore < /etc/iptables/rules.v6 || true
fi
EOF
    chmod +x /etc/local.d/iptables.start
    rc-update add local default
    info "✅ 已设置开机自动恢复防火墙规则"
    read -r -p "按回车返回菜单..."
}

# ===============================
# 菜单
# ===============================
menu() {
    while true; do
        clear
        echo -e "${GREEN}============================${RESET}"
        echo -e "${GREEN} 🔥 Alpine 防火墙管理脚本 ${RESET}"
        echo -e "${GREEN}============================${RESET}"
        echo -e "${GREEN}1) 初始化默认规则 (放行 SSH/80/443)${RESET}"
        echo -e "${GREEN}2) 开放指定 IP${RESET}"
        echo -e "${GREEN}3) 封禁指定 IP${RESET}"
        echo -e "${GREEN}4) 删除指定 IP 规则${RESET}"
        echo -e "${GREEN}5) 开放指定端口 (TCP/UDP)${RESET}"
        echo -e "${GREEN}6) 关闭指定端口 (TCP/UDP)${RESET}"
        echo -e "${GREEN}7) 禁止 PING${RESET}"
        echo -e "${GREEN}8) 允许 PING${RESET}"
        echo -e "${GREEN}9) 清空防火墙规则${RESET}"
        echo -e "${GREEN}10) 显示当前规则${RESET}"
        echo -e "${GREEN}11) 设置开机自动恢复防火墙规则${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        echo -e "============================"
        read -r -p "请选择操作 (0-11): " choice

        case $choice in
            1) init_rules ;;
            2) read -r -p "请输入要放行的 IP: " IP; ip_action accept "$IP" ;;
            3) read -r -p "请输入要封禁的 IP: " IP; ip_action drop "$IP" ;;
            4) read -r -p "请输入要删除的 IP: " IP; ip_action delete "$IP" ;;
            5) open_port ;;
            6) close_port ;;
            7) disable_ping ;;
            8) enable_ping ;;
            9) clear_firewall ;;
            10) show_rules ;;
            11) enable_autostart ;;
            0) break ;;
            *) warn "无效输入，请重新选择"; read -r -p "按回车返回菜单..." ;;
        esac
    done
}

# ===============================
# 脚本入口
# ===============================
FIRST_RUN=$(install_firewall_tools)
if [ "$FIRST_RUN" -eq 1 ]; then
    info "✅ 首次安装完成，防火墙工具已就绪"
    read -r -p "按回车继续..."
fi

menu
