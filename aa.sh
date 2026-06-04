#!/bin/sh
# 适配 Alpine Linux 默认 /bin/sh，完美兼容 Docker 环境
set -e

# ===============================
# 防火墙管理脚本（Alpine Linux 双栈 IPv4/IPv6 & Docker 兼容版）
# ===============================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# ===============================
# 动态信息获取函数
# ===============================

get_ssh_port() {
    local port=""
    if [ -f /etc/ssh/sshd_config ]; then
        port=$(grep -E '^ *Port ' /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
    fi
    echo "$port" | grep -qE '^[0-9]+$' || port=22
    echo "$port"
}

get_firewall_status() {
    local status4 status6
    status4=$(rc-service iptables status 2>/dev/null | grep -E "started|status:.*started" || true)
    status6=$(rc-service ip6tables status 2>/dev/null | grep -E "started|status:.*started" || true)

    if [ -n "$status4" ] || [ -n "$status6" ]; then
        if rc-status default 2>/dev/null | grep -q "iptables"; then
            echo "${YELLOW}● 已开启 (开机自启)${RESET}"
        else
            echo "${YELLOW}● 运行中 (未设自启)${RESET}"
        fi
    else
        if iptables -P INPUT 2>/dev/null | grep -q "DROP"; then
            echo "${YELLOW}● 运行中 (服务未接管)${RESET}"
        else
            echo "${RED}○ 已关闭 (全放行)${RESET}"
        fi
    fi
}

get_firewall_type() {
    if command -v iptables >/dev/null 2>&1; then
        if iptables --version | grep -qi "nftables"; then
            echo "iptables (nftables 后端)"
        else
            echo "iptables (legacy 后端)"
        fi
    else
        echo "未安装"
    fi
}

get_banned_ip_count() {
    local count4 count6 total
    count4=$(iptables -L INPUT -n 2>/dev/null | grep -E "DROP|REJECT" | grep -v "tcp dport" | awk '{print $4}' | grep -v "0.0.0.0" | sort -u | wc -l)
    count6=$(ip6tables -L INPUT -n 2>/dev/null | grep -E "DROP|REJECT" | grep -v "tcp dport" | awk '{print $4}' | grep -v "::" | sort -u | wc -l)
    total=$((count4 + count6))
    echo "$total"
}

# ===============================
# 防火墙核心逻辑函数 (Docker 安全适配)
# ===============================

save_rules() {
    /etc/init.d/iptables save >/dev/null 2>&1 || true
    /etc/init.d/ip6tables save >/dev/null 2>&1 || true
}

save_and_enable_autoload() {
    save_rules
    rc-update add iptables default >/dev/null 2>&1 || true
    rc-update add ip6tables default >/dev/null 2>&1 || true
    echo "${GREEN}✅ 规则已保存，并已通过 OpenRC 设置为开机自动加载${RESET}"
    echo "按回车继续..." && read -r dummy
}

init_rules() {
    local ssh_port proto
    ssh_port=$(get_ssh_port)
    
    for proto in iptables ip6tables; do
        $proto -F INPUT
        
        if [ "$proto" = "ip6tables" ] || ! $proto -L FORWARD -n 2>/dev/null | grep -q "DOCKER"; then
            $proto -P FORWARD DROP
        fi
        
        $proto -P INPUT DROP
        $proto -P OUTPUT ACCEPT
        
        $proto -A INPUT -i lo -j ACCEPT
        $proto -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        
        $proto -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
        $proto -A INPUT -p tcp --dport 80 -j ACCEPT
        $proto -A INPUT -p tcp --dport 443 -j ACCEPT
    done
    
    if iptables -L FORWARD -n 2>/dev/null | grep -q "DOCKER"; then
        iptables -N DOCKER-USER 2>/dev/null || true
        if ! iptables -S DOCKER-USER 2>/dev/null | grep -q "RETURN"; then
            iptables -A DOCKER-USER -j RETURN
        fi
    fi
    
    save_rules
}

check_installed() {
    [ -f /etc/init.d/iptables ] && [ -f /etc/init.d/ip6tables ]
}

install_firewall() {
    echo "${YELLOW}正在为 Alpine Linux 安装防火墙组件...${RESET}"
    apk update
    apk del ufw >/dev/null 2>&1 || true
    apk add iptables ip6tables curl
    init_rules
    rc-update add iptables default >/dev/null 2>&1 || true
    rc-update add ip6tables default >/dev/null 2>&1 || true
    echo "${GREEN}✅ 防火墙安装完成，默认放行 SSH/80/443${RESET}"
    echo "按回车继续..." && read -r dummy
}

open_all_ports() {
    echo "${YELLOW}正在放行宿主机所有端口...${RESET}"
    iptables -P INPUT ACCEPT
    iptables -F INPUT
    ip6tables -P INPUT ACCEPT
    ip6tables -F INPUT
    save_rules
    echo "${GREEN}✅ 所有端口已放行（Docker 规则完好无损）${RESET}"
    echo "按回车继续..." && read -r dummy
}

restore_default_rules() {
    echo "${YELLOW}正在恢复默认安全规则 (仅放行 SSH/80/443)...${RESET}"
    init_rules
    echo "${GREEN}✅ 默认规则已恢复，Docker 未受影响${RESET}"
    echo "按回车继续..." && read -r dummy
}

ip_action() {
    local action="$1" ip="$2" proto has_docker
    
    if echo "$ip" | grep -q ":"; then
        proto="ip6tables"
        has_docker=false
    else
        proto="iptables"
        if iptables -L FORWARD -n 2>/dev/null | grep -q "DOCKER"; then
            has_docker=true
        else
            has_docker=false
        fi
    fi

    case $action in
        accept) 
            $proto -I INPUT -s "$ip" -j ACCEPT 
            if [ "$has_docker" = true ]; then
                iptables -I DOCKER-USER -s "$ip" -j ACCEPT
            fi
            ;;
        drop)   
            $proto -I INPUT -s "$ip" -j DROP 
            if [ "$has_docker" = true ]; then
                iptables -I DOCKER-USER -s "$ip" -j DROP
            fi
            ;;
        delete)
            while $proto -C INPUT -s "$ip" -j ACCEPT 2>/dev/null; do $proto -D INPUT -s "$ip" -j ACCEPT; done
            while $proto -C INPUT -s "$ip" -j DROP 2>/dev/null; do $proto -D INPUT -s "$ip" -j DROP; done
            if [ "$has_docker" = true ]; then
                while iptables -C DOCKER-USER -s "$ip" -j ACCEPT 2>/dev/null; do iptables -D DOCKER-USER -s "$ip" -j ACCEPT; done
                while iptables -C DOCKER-USER -s "$ip" -j DROP 2>/dev/null; do iptables -D DOCKER-USER -s "$ip" -j DROP; done
            fi
            ;;
    esac
}

ping_action() {
    local action="$1" proto
    for proto in iptables ip6tables; do
        case $action in
            allow)
                while $proto -C INPUT -p icmp -j DROP 2>/dev/null; do $proto -D INPUT -p icmp -j DROP; done
                if [ "$proto" = "iptables" ]; then
                    $proto -I INPUT -p icmp --icmp-type echo-request -j ACCEPT
                else
                    while $proto -C INPUT -p icmpv6 -j DROP 2>/dev/null; do $proto -D INPUT -p icmpv6 -j DROP; done
                    $proto -I INPUT -p icmpv6 --icmpv6-type echo-request -j ACCEPT
                fi
                ;;
            deny)
                if [ "$proto" = "iptables" ]; then
                    while $proto -C INPUT -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null; do $proto -D INPUT -p icmp --icmp-type echo-request -j ACCEPT; done
                    $proto -I INPUT -p icmp --icmp-type echo-request -j DROP
                else
                    while $proto -C INPUT -p icmpv6 --icmpv6-type echo-request -j ACCEPT 2>/dev/null; do $proto -D INPUT -p icmpv6 --icmpv6-type echo-request -j ACCEPT; done
                    $proto -I INPUT -p icmpv6 --icmpv6-type echo-request -j DROP
                fi
                ;;
        esac
    done
}

uninstall_firewall() {
    echo "${RED}⚠️ 警告：正在放行所有宿主机流量，并卸载组件...${RESET}"
    printf "确认要卸载吗？(y/n): " && read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "${YELLOW}已取消卸载。${RESET}"
        echo "按回车继续..." && read -r dummy
        return
    fi

    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -F INPUT 2>/dev/null || true
    iptables -F DOCKER-USER 2>/dev/null || true
    
    ip6tables -P INPUT ACCEPT 2>/dev/null || true
    ip6tables -F INPUT 2>/dev/null || true

    rc-service iptables stop >/dev/null 2>&1 || true
    rc-service ip6tables stop >/dev/null 2>&1 || true
    rc-update del iptables default >/dev/null 2>&1 || true
    rc-update del ip6tables default >/dev/null 2>&1 || true
    
    apk del iptables ip6tables >/dev/null 2>&1 || true

    echo "${GREEN}✅ 防火墙宿主机策略已完全清空，Docker 网络未被破坏！${RESET}"
    echo "按回车退出..." && read -r dummy
    exit 0
}

view_visual_rules() {
    clear
    local ports_tcp ports_udp ping_status_v4 ping_status_v6
    local policy_v4 policy_v6 whitelist whitelist6 blacklist blacklist6 ip

    policy_v4=$(iptables -L INPUT -n 2>/dev/null | head -n 1 | awk '{print $4}' | tr -d ')')
    policy_v6=$(ip6tables -L INPUT -n 2>/dev/null | head -n 1 | awk '{print $4}' | tr -d ')')
    [ -z "$policy_v4" ] && policy_v4="UNKNOWN"
    [ -z "$policy_v6" ] && policy_v6="UNKNOWN"

    ports_tcp=$( (iptables -S INPUT 2>/dev/null; ip6tables -S INPUT 2>/dev/null) | grep " -j ACCEPT" | grep "dport " | grep "tcp" | awk '{for(i=1;i<=NF;i++) if($i=="--dport") print $(i+1)}' | sort -nu | tr '\n' ' ')
    ports_udp=$( (iptables -S INPUT 2>/dev/null; ip6tables -S INPUT 2>/dev/null) | grep " -j ACCEPT" | grep "dport " | grep "udp" | awk '{for(i=1;i<=NF;i++) if($i=="--dport") print $(i+1)}' | sort -nu | tr '\n' ' ')
    [ -z "$ports_tcp" ] && ports_tcp="无"
    [ -z "$ports_udp" ] && ports_udp="无"

    if iptables -S INPUT 2>/dev/null | grep "icmp" | grep -q "DROP"; then ping_status_v4="${RED}禁打(DROP)${RESET}"; else ping_status_v4="${GREEN}允许(ACCEPT)${RESET}"; fi
    if ip6tables -S INPUT 2>/dev/null | grep "icmpv6" | grep -q "DROP"; then ping_status_v6="${RED}禁打(DROP)${RESET}"; else ping_status_v6="${GREEN}允许(ACCEPT)${RESET}"; fi

    echo "${CYAN}==================================================${RESET}"
    echo "        📊 核心网络数据及规则总览看板 (含 Docker 级机制)  "
    echo "${CYAN}==================================================${RESET}"
    echo " 🛡️  ${CYAN}宿主机默认入站策略 (Default Policy):${RESET}"
    echo "    - IPv4 INPUT 链 : $policy_v4"
    echo "    - IPv6 INPUT 链 : $policy_v6"
    echo " 🌐 ${CYAN}ICMP 响应状态 (PING):${RESET}"
    echo "    - IPv4 Ping 回应: $ping_status_v4"
    echo "    - IPv6 Ping 回应: $ping_status_v6"
    echo "${CYAN}--------------------------------------------------${RESET}"

    echo " 🔓 ${GREEN}当前对宿主机公网开放的端口列表：${RESET}"
    echo "    +----------+--------------------------------------+"
    echo "    | ${YELLOW}协议类型${RESET} | ${YELLOW}开放的端口号${RESET}                      |"
    echo "    +----------+--------------------------------------+"
    printf "    |  %-6s  | %-36s |\n" "TCP" "$ports_tcp"
    printf "    |  %-6s  | %-36s |\n" "UDP" "$ports_udp"
    echo "    +----------+--------------------------------------+"
    echo "${CYAN}--------------------------------------------------${RESET}"

    echo " ⚪ ${BLUE}IP 白名单规则 (放行特定源 IP)：${RESET}"
    whitelist=$(iptables -S INPUT 2>/dev/null | grep " -j ACCEPT" | grep " -s " | grep -vE "dport|sport|lo|state" | awk '{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}' || true)
    whitelist6=$(ip6tables -S INPUT 2>/dev/null | grep " -j ACCEPT" | grep " -s " | grep -vE "dport|sport|lo|state" | awk '{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}' || true)
    
    if [ -n "$whitelist" ] || [ -n "$whitelist6" ]; then
        for ip in $whitelist; do echo "    ⚡ [IPv4] -> $ip"; done
        for ip in $whitelist6; do echo "    ⚡ [IPv6] -> $ip"; done
    else
        echo "    (当前无特定 IP 白名单规则)"
    fi

    echo "\n ⚫ ${RED}IP 黑名单规则 (已同步阻断宿主机与 Docker)：${RESET}"
    blacklist=$(iptables -S INPUT 2>/dev/null | grep " -j DROP" | grep " -s " | grep -vE "dport|sport" | awk '{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}' || true)
    blacklist6=$(ip6tables -S INPUT 2>/dev/null | grep " -j DROP" | grep " -s " | grep -vE "dport|sport" | awk '{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}' || true)
    
    if [ -n "$blacklist" ] || [ -n "$blacklist6" ]; then
        for ip in $blacklist; do echo "    ❌ [IPv4] -> $ip"; done
        for ip in $blacklist6; do echo "    ❌ [IPv6] -> $ip"; done
    else
        echo "    (当前无特定 IP 黑名单规则)"
    fi

    echo "${CYAN}==================================================${RESET}"
    echo "按回车返回主菜单..." && read -r dummy
}

# ===============================
# 管理菜单
# ===============================
menu() {
    while true; do
        STATUS=$(get_firewall_status)
        FIREWALL_TYPE=$(get_firewall_type)
        PORT_SHOW=$(get_ssh_port)
        SITE_COUNT=$(get_banned_ip_count)

        clear
        echo "${GREEN}===============================================${RESET}"
        echo "    ◈   双栈安全防火墙管理面板 (Docker增强)   ◈  "
        echo "${GREEN}===============================================${RESET}"
        echo " 状态  : ${STATUS}"
        echo " 内核  : ${YELLOW}${FIREWALL_TYPE}${RESET}"
        echo " 端口  : ${YELLOW}${PORT_SHOW}${RESET}"
        echo " 规则  : ${YELLOW}${SITE_COUNT} 个 IP${RESET}"
        echo "${GREEN}===============================================${RESET}"
        echo "  1. 开放指定端口 (TCP/UDP)"
        echo "  2. 关闭指定端口 (TCP/UDP)"
        echo "  3. 开放所有端口 (全放行)"
        echo "  4. 恢复默认安全规则 (放行SSH/80/443)"
        echo "  5. 添加 IP 白名单 (放行宿主机及Docker)"
        echo "  6. 添加 IP 黑名单 (封禁宿主机及Docker)"
        echo "  7. 删除指定 IP 规则"
        echo "  8. 允许 PING (ICMP)"
        echo "  9. 禁用 PING (ICMP)"
        echo " 10. 查看当前看板级可视化规则"
        echo " 11. 保存规则并设置开机自启"
        echo " 12. 卸载防火墙"
        echo "  0. 退出"
        echo "${GREEN}===============================================${RESET}"
        printf " 请选择: "
        read -r choice

        case "$choice" in
            1)
                printf "请输入要开放的端口号: " && read -r PORT
                if ! echo "$PORT" | grep -qE '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                    echo "${RED}❌ 错误：请输入 1-65535 之间的有效端口号${RESET}"
                    echo "按回车返回菜单..." && read -r dummy
                    continue
                fi
                local proto
                for proto in iptables ip6tables; do
                    while $proto -C INPUT -p tcp --dport "$PORT" -j DROP 2>/dev/null; do $proto -D INPUT -p tcp --dport "$PORT" -j DROP; done
                    while $proto -C INPUT -p udp --dport "$PORT" -j DROP 2>/dev/null; do $proto -D INPUT -p udp --dport "$PORT" -j DROP; done
                    $proto -I INPUT -p tcp --dport "$PORT" -j ACCEPT
                    $proto -I INPUT -p udp --dport "$PORT" -j ACCEPT
                done
                save_rules
                echo "${GREEN}✅ 已开放端口 $PORT${RESET}"
                echo "按回车继续..." && read -r dummy
                ;;
            2)
                printf "请输入要关闭的端口号: " && read -r PORT
                if ! echo "$PORT" | grep -qE '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                    echo "${RED}❌ 错误：请输入 1-65535 之间的有效端口号${RESET}"
                    echo "按回车返回菜单..." && read -r dummy
                    continue
                fi
                for proto in iptables ip6tables; do
                    while $proto -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; do $proto -D INPUT -p tcp --dport "$PORT" -j ACCEPT; done
                    while $proto -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null; do $proto -D INPUT -p udp --dport "$PORT" -j ACCEPT; done
                    $proto -I INPUT -p tcp --dport "$PORT" -j DROP
                    $proto -I INPUT -p udp --dport "$PORT" -j DROP
                done
                save_rules
                echo "${GREEN}✅ 已关闭端口 $PORT${RESET}"
                echo "按回车继续..." && read -r dummy
                ;;
            3) open_all_ports ;;
            4) restore_default_rules ;;
            5)
                printf "请输入要放行的IP: " && read -r IP
                ip_action accept "$IP"
                save_rules
                echo "${GREEN}✅ IP $IP 已放行${RESET}"
                echo "按回车继续..." && read -r dummy
                ;;
            6)
                printf "请输入要封禁的IP: " && read -r IP
                ip_action drop "$IP"
                save_rules
                echo "${GREEN}✅ IP $IP 已封禁${RESET}"
                echo "按回车继续..." && read -r dummy
                ;;
            7)
                printf "请输入要删除的IP: " && read -r IP
                ip_action delete "$IP"
                save_rules
                echo "${GREEN}✅ IP $IP 规则已删除${RESET}"
                echo "按回车继续..." && read -r dummy
                ;;
            8)
                ping_action allow
                save_rules
                echo "${GREEN}✅ 已允许 PING（ICMP）${RESET}"
                echo "按回车继续..." && read -r dummy
                ;;
            9)
                ping_action deny
                save_rules
                echo "${GREEN}✅ 已禁用 PING（ICMP）${RESET}"
                echo "按回车继续..." && read -r dummy
                ;;
            10) view_visual_rules ;;
            11) save_and_enable_autoload ;;
            12) uninstall_firewall ;;
            0) clear; break ;;
            *) echo "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

# ===============================
# 脚本入口
# ===============================
if [ "$(id -u)" -ne 0 ]; then
   echo "${RED}❌ 错误: 请使用 root 权限运行此脚本！${RESET}"
   exit 1
fi

if ! check_installed; then
    install_firewall
fi

menu
