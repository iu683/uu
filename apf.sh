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
    iptables-save > /etc/iptables/rules.v4 || true
    ip6tables-save > /etc/iptables/rules.v6 || true
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
    done
    save_rules
    info "默认规则已初始化，放行 SSH/80/443"
}

# ===============================
# 安装必要工具
# ===============================
install_firewall_tools() {
    apk update
    apk add --no-cache iptables ip6tables bash curl wget vim sudo git || true
    mkdir -p /etc/iptables
    info "防火墙工具安装完成"
}

# ===============================
# IP 规则操作
# ===============================
ip_action() {
    ACTION=$1
    IP=$2
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
}

# ===============================
# 开放指定端口（TCP/UDP）
# ===============================
open_port() {
    read -r -p "请输入要开放的端口号: " PORT
    for proto in iptables ip6tables; do
        $proto -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        $proto -I INPUT -p udp --dport "$PORT" -j ACCEPT
    done
    save_rules
    info "端口 $PORT 已开放 (TCP/UDP)"
}

# ===============================
# 禁止 PING
# ===============================
disable_ping() {
    for proto in iptables ip6tables; do
        while $proto -C INPUT -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null; do
            $proto -D INPUT -p icmp --icmp-type echo-request -j ACCEPT
        done
        while $proto -C OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT 2>/dev/null; do
            $proto -D OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT
        done
    done
    save_rules
    info "已禁止 PING (ICMP)"
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
    info "已清空防火墙规则，所有流量放行"
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
        echo -e "${GREEN}4) 删除 IP 规则${RESET}"
        echo -e "${GREEN}5) 开放指定端口 (TCP/UDP)${RESET}"
        echo -e "${GREEN}6) 禁止 PING${RESET}"
        echo -e "${GREEN}7) 清空防火墙（全放行）${RESET}"
        echo -e "${GREEN}8) 显示当前规则${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        echo -e "----------------------------"
        read -r -p "请选择操作: " CHOICE

        case $CHOICE in
            1) init_rules; read -r -p "按回车返回菜单..." ;;
            2) read -r -p "请输入要放行的 IP: " IP; ip_action accept "$IP"; read -r -p "按回车返回菜单..." ;;
            3) read -r -p "请输入要封禁的 IP: " IP; ip_action drop "$IP"; read -r -p "按回车返回菜单..." ;;
            4) read -r -p "请输入要删除的 IP: " IP; ip_action delete "$IP"; read -r -p "按回车返回菜单..." ;;
            5) open_port; read -r -p "按回车返回菜单..." ;;
            6) disable_ping; read -r -p "按回车返回菜单..." ;;
            7) clear_firewall; read -r -p "按回车返回菜单..." ;;
            8) iptables -L -n --line-numbers; ip6tables -L -n --line-numbers; read -r -p "按回车返回菜单..." ;;
            0) break ;;
            *) warn "无效选择"; read -r -p "按回车返回菜单..." ;;
        esac
    done
}

# ===============================
# 脚本入口
# ===============================
install_firewall_tools
menu
