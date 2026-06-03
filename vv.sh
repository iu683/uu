#!/bin/sh
# 上面改成 Alpine 默认的 /bin/sh，同时内部语法保持兼容
set -e

# ===============================
# 防火墙管理脚本（Alpine Linux 双栈 IPv4/IPv6）
# ===============================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ===============================
# 动态信息获取函数
# ===============================

# 1. 获取 SSH 端口
get_ssh_port() {
    local port
    if [ -f /etc/ssh/sshd_config ]; then
        port=$(grep -E '^ *Port ' /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
    fi
    # 如果没匹配到，或者 Alpine 默认使用 Dropbear
    [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]] && port=22
    echo "$port"
}

# 2. 获取防火墙运行状态 (基于 OpenRC)
get_firewall_status() {
    local status4 status6
    status4=$(rc-service iptables status 2>/dev/null | grep -E "started|status:.*started" || true)
    status6=$(rc-service ip6tables status 2>/dev/null | grep -E "started|status:.*started" || true)

    if [ -n "$status4" ] || [ -n "$status6" ]; then
        # 检查是否开机自启
        if rc-status default | grep -q "iptables" 2>/dev/null; then
            echo -e "${GREEN}● 已开启 (开机自启)${RESET}"
        else
            echo -e "${YELLOW}● 运行中 (未设自启)${RESET}"
        fi
    else
        # 检查是否至少有规则在运行
        if iptables -P INPUT 2>/dev/null | grep -q "DROP"; then
            echo -e "${YELLOW}● 运行中 (服务未接管)${RESET}"
        else
            echo -e "${RED}○ 已关闭 (全放行)${RESET}"
        fi
    fi
}

# 3. 获取当前实际使用的防火墙后端内核
get_firewall_type() {
    if command -v iptables &>/dev/null; then
        # 针对 Alpine 区分是 nftables 后端还是传统 legacy 后端
        if iptables --version | grep -qi "nftables"; then
            echo "iptables (nftables 后端)"
        else
            echo "iptables (legacy 后端)"
        fi
    else
        echo "未安装"
    fi
}

# 4. 统计当前封禁的独立 IP 数量 (DROP/REJECT)
get_banned_ip_count() {
    local count4 count6 total
    count4=$(iptables -L INPUT -n 2>/dev/null | grep -E "DROP|REJECT" | grep -v "tcp dport" | awk '{print $4}' | grep -v "0.0.0.0" | sort -u | wc -l)
    count6=$(ip6tables -L INPUT -n 2>/dev/null | grep -E "DROP|REJECT" | grep -v "tcp dport" | awk '{print $4}' | grep -v "::" | sort -u | wc -l)
    total=$((count4 + count6))
    echo "$total"
}

# ===============================
# 防火墙核心逻辑函数 (Alpine OpenRC 适配)
# ===============================

save_rules() {
    # Alpine 下保存规则的标准命令
    /etc/init.d/iptables save >/dev/null 2>&1 || true
    /etc/init.d/ip6tables save >/dev/null 2>&1 || true
}

save_and_enable_autoload() {
    save_rules
    rc-update add iptables default >/dev/null 2>&1 || true
    rc-update add ip6tables default >/dev/null 2>&1 || true
    rc-service iptables start >/dev/null 2>&1 || true
    rc-service ip6tables start >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ 规则已保存，并已通过 OpenRC 设置为开机自动加载${RESET}"
    read -p "按回车继续..."
}

init_rules() {
    local ssh_port
    ssh_port=$(get_ssh_port)
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
        $proto -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
        $proto -A INPUT -p tcp --dport 80 -j ACCEPT
        $proto -A INPUT -p tcp --dport 443 -j ACCEPT
    done
    save_rules
    # 确保服务开启
    rc-service iptables start >/dev/null 2>&1 || true
    rc-service ip6tables start >/dev/null 2>&1 || true
}

check_installed() {
    # 检查 Alpine 是否安装了 iptables 核心及 OpenRC 脚本
    [ -f /etc/init.d/iptables ] && [ -f /etc/init.d/ip6tables ]
}

install_firewall() {
    echo -e "${YELLOW}正在为 Alpine Linux 安装防火墙组件...${RESET}"
    apk update
    # 清理可能存在的冲突组件并安装核心包
    apk del ufw 2>/dev/null || true
    apk add iptables ip6tables curl
    
    # 初始化默认规则
    init_rules
    
    # 设置开机自启
    rc-update add iptables default >/dev/null 2>&1 || true
    rc-update add ip6tables default >/dev/null 2>&1 || true
    
    echo -e "${GREEN}✅ 防火墙安装完成，默认放行 SSH/80/443${RESET}"
    echo -e "${GREEN}✅ 已通过 OpenRC 设置开机自动加载规则${RESET}"
    read -p "按回车继续..."
}

clear_firewall() {
    echo -e "${YELLOW}正在清空防火墙规则并放行所有流量...${RESET}"
    for proto in iptables ip6tables; do
        $proto -F
        $proto -X
        $proto -P INPUT ACCEPT
        $proto -P FORWARD ACCEPT
        $proto -P OUTPUT ACCEPT
    done
    save_rules
    rc-update del iptables default >/dev/null 2>&1 || true
    rc-update del ip6tables default >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ 防火墙规则已清空，所有流量已放行，开机自启已取消${RESET}"
    read -p "按回车继续..."
}

restore_default_rules() {
    echo -e "${YELLOW}正在恢复默认防火墙规则 (仅放行 SSH/80/443)...${RESET}"
    local ssh_port
    ssh_port=$(get_ssh_port)
    echo -e "${GREEN}检测到 SSH 端口: $ssh_port${RESET}"
    init_rules
    echo -e "${GREEN}✅ 默认规则已恢复${RESET}"
    read -p "按回车继续..."
}

open_all_ports() {
    echo -e "${YELLOW}正在放行所有端口（IPv4/IPv6）...${RESET}"
    for proto in iptables ip6tables; do
        $proto -F
        $proto -X
        $proto -P INPUT ACCEPT
        $proto -P FORWARD ACCEPT
        $proto -P OUTPUT ACCEPT
    done
    save_rules
    echo -e "${GREEN}✅ 所有端口已放行（全开放）${RESET}"
    read -p "按回车继续..."
}

ip_action() {
    local action=$1 ip=$2 proto
    if [[ $ip =~ : ]]; then
        proto="ip6tables"
    else
        proto="iptables"
    fi

    case $action in
        accept) $proto -I INPUT -s "$ip" -j ACCEPT ;;
        drop)   $proto -I INPUT -s "$ip" -j DROP ;;
        delete)
            while $proto -C INPUT -s "$ip" -j ACCEPT 2>/dev/null; do
                $proto -D INPUT -s "$ip" -j ACCEPT
            done
            while $proto -C INPUT -s "$ip" -j DROP 2>/dev/null; do
                $proto -D INPUT -s "$ip" -j DROP
            done
            ;;
    esac
}

ping_action() {
    local action=$1
    for proto in iptables ip6tables; do
        case $action in
            allow)
                while $proto -C INPUT -p icmp -j DROP 2>/dev/null; do $proto -D INPUT -p icmp -j DROP; done
                while $proto -C OUTPUT -p icmp -j DROP 2>/dev/null; do $proto -D OUTPUT -p icmp -j DROP; done
                if [ "$proto" = "iptables" ]; then
                    $proto -I INPUT -p icmp --icmp-type echo-request -j ACCEPT
                    $proto -I OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT
                else
                    $proto -I INPUT -p icmpv6 --icmpv6-type echo-request -j ACCEPT
                    $proto -I OUTPUT -p icmpv6 --icmpv6-type echo-reply -j ACCEPT
                fi
                ;;
            deny)
                if [ "$proto" = "iptables" ]; then
                    while $proto -C INPUT -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null; do $proto -D INPUT -p icmp --icmp-type echo-request -j ACCEPT; done
                    while $proto -C OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT 2>/dev/null; do $proto -D OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT; done
                    $proto -I INPUT -p icmp --icmp-type echo-request -j DROP
                    $proto -I OUTPUT -p icmp --icmp-type echo-reply -j DROP
                else
                    while $proto -C INPUT -p icmpv6 --icmpv6-type echo-request -j ACCEPT 2>/dev/null; do $proto -D INPUT -p icmpv6 --icmpv6-type echo-request -j ACCEPT; done
                    while $proto -C OUTPUT -p icmpv6 --icmpv6-type echo-reply -j ACCEPT 2>/dev/null; do $proto -D OUTPUT -p icmpv6 --icmpv6-type echo-reply -j ACCEPT; done
                    $proto -I INPUT -p icmpv6 --icmpv6-type echo-request -j DROP
                    $proto -I OUTPUT -p icmpv6 --icmpv6-type echo-reply -j DROP
                fi
                ;;
        esac
    done
}

# ===============================
# 全新风格管理菜单
# ===============================
menu() {
    while true; do
        STATUS=$(get_firewall_status)
        FIREWALL_TYPE=$(get_firewall_type)
        PORT_SHOW=$(get_ssh_port)
        SITE_COUNT=$(get_banned_ip_count)

        clear
        echo -e "${GREEN}===============================${RESET}"
        echo -e "${GREEN}   ◈   双栈防火墙管理面板  ◈   ${RESET}"
        echo -e "${GREEN}===============================${RESET}"
        echo -e "${GREEN} 状态  : ${STATUS}"
        echo -e "${GREEN} 内核  : ${YELLOW}${FIREWALL_TYPE}${RESET}"
        echo -e "${GREEN} 端口  : ${YELLOW}${PORT_SHOW}${RESET}"
        echo -e "${GREEN} 规则  : ${YELLOW}${SITE_COUNT} 个 IP${RESET}"
        echo -e "${GREEN}===============================${RESET}"
        echo -e "${GREEN}  1. 开放指定端口 (TCP/UDP)${RESET}"
        echo -e "${GREEN}  2. 关闭指定端口 (TCP/UDP)${RESET}"
        echo -e "${GREEN}  3. 开放所有端口 (全放行)${RESET}"
        echo -e "${GREEN}  4. 恢复默认安全规则 (放行SSH/80/443)${RESET}"
        echo -e "${GREEN}  5. 添加 IP 白名单 (放行)${RESET}"
        echo -e "${GREEN}  6. 添加 IP 黑名单 (封禁)${RESET}"
        echo -e "${GREEN}  7. 删除指定 IP 规则${RESET}"
        echo -e "${GREEN}  8. 允许 PING (ICMP)${RESET}"
        echo -e "${GREEN}  9. 禁用 PING (ICMP)${RESET}"
        echo -e "${GREEN} 10. 查看当前防火墙详细规则${RESET}"
        echo -e "${GREEN} 11. 保存规则并设置开机自启${RESET}"
        echo -e "${GREEN}  0. 退出${RESET}"
        echo -e "${GREEN}===============================${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        read -r choice

        case $choice in
            1)
                read -p "请输入要开放的端口号: " PORT
                if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                    echo -e "${RED}❌ 错误：请输入 1-65535 之间的有效端口号${RESET}"
                    read -p "按回车返回菜单..."
                    continue
                fi
                for proto in iptables ip6tables; do
                    while $proto -C INPUT -p tcp --dport "$PORT" -j DROP 2>/dev/null; do $proto -D INPUT -p tcp --dport "$PORT" -j DROP; done
                    while $proto -C INPUT -p udp --dport "$PORT" -j DROP 2>/dev/null; do $proto -D INPUT -p udp --dport "$PORT" -j DROP; done
                    $proto -I INPUT -p tcp --dport "$PORT" -j ACCEPT
                    $proto -I INPUT -p udp --dport "$PORT" -j ACCEPT
                done
                save_rules
                echo -e "${GREEN}✅ 已开放端口 $PORT${RESET}"
                read -p "按回车继续..."
                ;;
            2)
                read -p "请输入要关闭的端口号: " PORT
                if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                    echo -e "${RED}❌ 错误：请输入 1-65535 之间的有效端口号${RESET}"
                    read -p "按回车返回菜单..."
                    continue
                fi
                for proto in iptables ip6tables; do
                    while $proto -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; do $proto -D INPUT -p tcp --dport "$PORT" -j ACCEPT; done
                    while $proto -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null; do $proto -D INPUT -p udp --dport "$PORT" -j ACCEPT; done
                    $proto -I INPUT -p tcp --dport "$PORT" -j DROP
                    $proto -I INPUT -p udp --dport "$PORT" -j DROP
                done
                save_rules
                echo -e "${GREEN}✅ 已关闭端口 $PORT${RESET}"
                read -p "按回车继续..."
                ;;
            3) open_all_ports ;;
            4) restore_default_rules ;;
            5)
                read -p "请输入要放行的IP: " IP
                ip_action accept "$IP"
                save_rules
                echo -e "${GREEN}✅ IP $IP 已放行${RESET}"
                read -p "按回车继续..."
                ;;
            6)
                read -p "请输入要封禁的IP: " IP
                ip_action drop "$IP"
                save_rules
                echo -e "${GREEN}✅ IP $IP 已封禁${RESET}"
                read -p "按回车继续..."
                ;;
            7)
                read -p "请输入要删除的IP: " IP
                ip_action delete "$IP"
                save_rules
                echo -e "${GREEN}✅ IP $IP 规则已删除${RESET}"
                read -p "按回车继续..."
                ;;
            8)
                ping_action allow
                save_rules
                echo -e "${GREEN}✅ 已允许 PING（ICMP）${RESET}"
                read -p "按回车继续..."
                ;;
            9)
                ping_action deny
                save_rules
                echo -e "${GREEN}✅ 已禁用 PING（ICMP）${RESET}"
                read -p "按回车继续..."
                ;;
            10)
                clear
                echo -e "${YELLOW}当前防火墙状态:${RESET}"
                echo "--- iptables IPv4 ---"
                iptables -L -n -v --line-numbers
                echo -e "\n--- ip6tables IPv6 ---"
                ip6tables -L -n -v --line-numbers
                read -r -p "按回车返回菜单..." || true
                ;;
            11) save_and_enable_autoload ;;
            0) clear; break ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

# ===============================
# 脚本入口
# ===============================
# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
   echo -e "${RED}❌ 错误: 请使用 root 权限运行此脚本！${RESET}"
   exit 1
fi

if ! check_installed; then
    install_firewall
fi

menu
