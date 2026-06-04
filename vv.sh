#!/bin/sh
# 注意：Alpine 默认使用 busybox sh，已移除 bash 特性以确保完美兼容性
set -e

# ===============================
# 防火墙管理脚本（Alpine 双栈 IPv4/IPv6 - Docker 完美兼容版）
# ===============================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
PURPLE="\033[35m"
CYAN="\033[36m"
RESET="\033[0m"

# ===============================
# 动态信息获取函数
# ===============================

get_ssh_port() {
    local port
    if [ -f /etc/ssh/sshd_config ]; then
        port=$(grep -E '^ *Port ' /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
    fi
    # 如果没找到或不是数字，默认 Alpine 的 SSH 端口
    [ -z "$port" ] || ! echo "$port" | grep -qE '^[0-9]+$' && port=22
    echo "$port"
}

get_firewall_status() {
    if rc-service iptables status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}● 运行中 (开机自启)${RESET}"
    else
        if iptables -P INPUT 2>/dev/null | grep -q "DROP"; then
            echo -e "${YELLOW}● 运行中 (未设自启)${RESET}"
        else
            echo -e "${RED}○ 已关闭 (全放行)${RESET}"
        fi
    fi
}

get_firewall_type() {
    if command -v iptables >/dev/null 2>&1; then
        if iptables --version | grep -qi "nftables"; then
            echo "iptables (nftables)"
        else
            echo "iptables (legacy)"
        fi
    else
        echo "未安装"
    fi
}

get_banned_ip_count() {
    local count4=0 count6=0 total=0
    if command -v iptables >/dev/null 2>&1; then
        count4=$(iptables -L INPUT -n 2>/dev/null | grep -E "DROP|REJECT" | grep -vE "dpt:|spt:" | awk '{print $4}' | grep -v "0.0.0.0/0" | sort -u | wc -l)
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        count6=$(ip6tables -L INPUT -n 2>/dev/null | grep -E "DROP|REJECT" | grep -vE "dpt:|spt:" | awk '{print $4}' | grep -v "::/0" | sort -u | wc -l)
    fi
    total=$((count4 + count6))
    echo "$total"
}

# ===============================
# 防火墙核心逻辑函数
# ===============================

save_rules() {
    # Alpine 存储机制：通过 OpenRC 服务调用保存
    rc-service iptables save >/dev/null 2>&1 || true
    rc-service ip6tables save >/dev/null 2>&1 || true
}

save_and_enable_autoload() {
    save_rules
    rc-update add iptables default >/dev/null 2>&1 || true
    rc-update add ip6tables default >/dev/null 2>&1 || true
    rc-service iptables start >/dev/null 2>&1 || true
    rc-service ip6tables start >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ 规则已保存，并设置为开机自动加载 (OpenRC)${RESET}"
    printf "按回车继续..." && read -r _
}

init_rules() {
    local ssh_port
    ssh_port=$(get_ssh_port)
    for proto in iptables ip6tables; do
        # 【Docker 兼容改造 1】：绝对不执行全局清开，只精准清空和管理 INPUT 链
        $proto -F INPUT
        
        # 核心策略：入站拦截，转发和出站保持 ACCEPT（Docker 严重依赖 FORWARD）
        $proto -P INPUT DROP
        $proto -P FORWARD ACCEPT
        $proto -P OUTPUT ACCEPT
        
        # 基础放行规则
        $proto -A INPUT -i lo -j ACCEPT
        $proto -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        $proto -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
        $proto -A INPUT -p tcp --dport 80 -j ACCEPT
        $proto -A INPUT -p tcp --dport 443 -j ACCEPT
    done
    save_rules
    rc-update add iptables default >/dev/null 2>&1 || true
    rc-update add ip6tables default >/dev/null 2>&1 || true
}

check_installed() {
    # 检查 iptables 核心文件与 OpenRC 脚本是否存在
    [ -f /etc/init.d/iptables ] && [ -f /etc/init.d/ip6tables ]
}

install_firewall() {
    echo -e "${YELLOW}正在 Alpine 上安装并初始化防火墙，请稍候...${RESET}"
    apk update
    apk add iptables ip6tables curl
    init_rules
    echo -e "${GREEN}✅ 防火墙安装完成，默认放行 SSH/80/443${RESET}"
    echo -e "${GREEN}✅ 已通过 OpenRC 设置开机自动加载规则${RESET}"
    printf "按回车继续..." && read -r _
}

clear_firewall() {
    echo -e "${YELLOW}正在恢复宿主机默认策略并放行所有流量...${RESET}"
    for proto in iptables ip6tables; do
        $proto -F INPUT
        $proto -P INPUT ACCEPT
        $proto -P FORWARD ACCEPT
        $proto -P OUTPUT ACCEPT
    done
    if iptables -L DOCKER-USER -n >/dev/null 2>&1; then
        iptables -F DOCKER-USER
    fi
    save_rules
    rc-update del iptables default >/dev/null 2>&1 || true
    rc-update del ip6tables default >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ 防火墙入站限制已清空，宿主机流量已全放行（未损坏 Docker 链）${RESET}"
    printf "按回车继续..." && read -r _
}

restore_default_rules() {
    echo -e "${YELLOW}正在恢复默认防火墙规则 (仅放行 SSH/80/443)...${RESET}"
    local ssh_port
    ssh_port=$(get_ssh_port)
    echo -e "${GREEN}检测到 SSH 端口: $ssh_port${RESET}"
    init_rules
    echo -e "${GREEN}✅ 默认规则已恢复${RESET}"
    printf "按回车继续..." && read -r _
}

open_all_ports() {
    echo -e "${YELLOW}正在放行所有宿主机端口（IPv4/IPv6）...${RESET}"
    for proto in iptables ip6tables; do
        $proto -F INPUT
        $proto -P INPUT ACCEPT
        $proto -P FORWARD ACCEPT
    done
    save_rules
    echo -e "${GREEN}✅ 宿主机所有端口已放行（全开放）${RESET}"
    printf "按回车继续..." && read -r _
}

ip_action() {
    local action=$1 ip=$2 proto
    if echo "$ip" | grep -q ":"; then
        proto="ip6tables"
    else
        proto="iptables"
    fi

    case $action in
        accept) 
            $proto -I INPUT -s "$ip" -j ACCEPT 
            ;;
        drop)   
            $proto -I INPUT -s "$ip" -j DROP 
            # 【Docker 兼容改造 2】：如果存在 DOCKER-USER 链，将黑名单同步封禁在 Docker 顶端
            if [ "$proto" = "iptables" ] && iptables -L DOCKER-USER -n >/dev/null 2>&1; then
                if ! iptables -C DOCKER-USER -s "$ip" -j DROP 2>/dev/null; then
                    iptables -I DOCKER-USER -s "$ip" -j DROP
                fi
            fi
            ;;
        delete)
            while $proto -C INPUT -s "$ip" -j ACCEPT 2>/dev/null; do $proto -D INPUT -s "$ip" -j ACCEPT; done
            while $proto -C INPUT -s "$ip" -j DROP 2>/dev/null; do $proto -D INPUT -s "$ip" -j DROP; done
            if [ "$proto" = "iptables" ] && iptables -L DOCKER-USER -n >/dev/null 2>&1; then
                while iptables -C DOCKER-USER -s "$ip" -j DROP 2>/dev/null; do iptables -D DOCKER-USER -s "$ip" -j DROP; done
            fi
            ;;
    esac
}

ping_action() {
    local action=$1
    
    while iptables -C INPUT -p icmp -j DROP 2>/dev/null; do iptables -D INPUT -p icmp -j DROP; done
    while iptables -C OUTPUT -p icmp -j DROP 2>/dev/null; do iptables -D OUTPUT -p icmp -j DROP; done
    while iptables -C INPUT -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null; do iptables -D INPUT -p icmp --icmp-type echo-request -j ACCEPT; done
    while iptables -C OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT 2>/dev/null; do iptables -D OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT; done
    
    while ip6tables -C INPUT -p icmpv6 -j DROP 2>/dev/null; do ip6tables -D INPUT -p icmpv6 -j DROP; done
    while ip6tables -C OUTPUT -p icmpv6 -j DROP 2>/dev/null; do ip6tables -D OUTPUT -p icmpv6 -j DROP; done
    while ip6tables -C INPUT -p icmpv6 --icmpv6-type echo-request -j ACCEPT 2>/dev/null; do ip6tables -D INPUT -p icmpv6 --icmpv6-type echo-request -j ACCEPT; done
    while ip6tables -C OUTPUT -p icmpv6 --icmpv6-type echo-reply -j ACCEPT 2>/dev/null; do ip6tables -D OUTPUT -p icmpv6 --icmpv6-type echo-reply -j ACCEPT; done

    if [ "$action" = "allow" ]; then
        iptables -I INPUT -p icmp --icmp-type echo-request -j ACCEPT
        iptables -I OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT
        ip6tables -I INPUT -p icmpv6 --icmpv6-type echo-request -j ACCEPT
        ip6tables -I OUTPUT -p icmpv6 --icmpv6-type echo-reply -j ACCEPT
    else
        iptables -I INPUT -p icmp --icmp-type echo-request -j DROP
        iptables -I OUTPUT -p icmp --icmp-type echo-reply -j DROP
        ip6tables -I INPUT -p icmpv6 --icmpv6-type echo-request -j DROP
        ip6tables -I OUTPUT -p icmpv6 --icmpv6-type echo-reply -j DROP
    fi
}

uninstall_firewall() {
    clear
    echo -e "${RED}⚠️ 警告：该操作将清空所有宿主机入站规则并卸载防火墙组件，恢复网络全放行状态！${RESET}"
    printf "确定要彻底卸载吗？(y/n): " && read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "已取消卸载。"
        printf "按回车继续..." && read -r _
        return
    fi

    echo -e "${YELLOW}正在清理宿主机规则...${RESET}"
    for proto in iptables ip6tables; do
        $proto -F INPUT
        $proto -P INPUT ACCEPT
        $proto -P FORWARD ACCEPT
        $proto -P OUTPUT ACCEPT
    done
    if iptables -L DOCKER-USER -n >/dev/null 2>&1; then
        iptables -F DOCKER-USER
    fi

    echo -e "${YELLOW}正在停止并移除 OpenRC 守护服务...${RESET}"
    rc-service iptables stop >/dev/null 2>&1 || true
    rc-service ip6tables stop >/dev/null 2>&1 || true
    rc-update del iptables default >/dev/null 2>&1 || true
    rc-update del ip6tables default >/dev/null 2>&1 || true
    
    echo -e "${YELLOW}正在卸载包...${RESET}"
    apk del iptables ip6tables

    echo -e "${GREEN}✅ 防火墙已彻底卸载，Docker 链与网络已安全释放。${RESET}"
    exit 0
}

view_visual_rules() {
    clear
    local ports_tcp ports_udp ping_status_v4 ping_status_v6
    local policy_v4 policy_v6

    # 针对 Alpine 砍掉 grep -P 的兼容写法，使用 awk 提取 policy
    policy_v4=$(iptables -L INPUT -n 2>/dev/null | head -n 1 | awk '{print $4}' | tr -d ')')
    policy_v6=$(ip6tables -L INPUT -n 2>/dev/null | head -n 1 | awk '{print $4}' | tr -d ')')
    [ -z "$policy_v4" ] && policy_v4="UNKNOWN"
    [ -z "$policy_v6" ] && policy_v6="UNKNOWN"

    ports_tcp=$( (iptables -L INPUT -n 2>/dev/null; ip6tables -L INPUT -n 2>/dev/null) | grep "ACCEPT" | grep "tcp dpt:" | sed -E 's/.*dpt:([0-9:]+).*/\1/' | sort -nu | tr '\n' ' ')
    ports_udp=$( (iptables -L INPUT -n 2>/dev/null; ip6tables -L INPUT -n 2>/dev/null) | grep "ACCEPT" | grep "udp dpt:" | sed -E 's/.*dpt:([0-9:]+).*/\1/' | sort -nu | tr '\n' ' ')
    [ -z "$ports_tcp" ] && ports_tcp="无"
    [ -z "$ports_udp" ] && ports_udp="无"

    if iptables -L INPUT -n 2>/dev/null | grep "DROP" | grep -q "icmp"; then ping_status_v4="${RED}禁打(DROP)${RESET}"; else ping_status_v4="${GREEN}允许(ACCEPT)${RESET}"; fi
    if ip6tables -L INPUT -n 2>/dev/null | grep "DROP" | grep -q "ipv6-icmp"; then ping_status_v6="${RED}禁打(DROP)${RESET}"; else ping_status_v6="${GREEN}允许(ACCEPT)${RESET}"; fi

    echo -e "${CYAN}==================================================${RESET}"
    echo -e "${CYAN}         📊 核心网络数据及规则总览看板              ${RESET}"
    echo -e "${CYAN}==================================================${RESET}"
    echo -e " 🛡️  ${CYAN}宿主机默认入站策略 (Default Policy):${RESET}"
    echo -e "    - IPv4 INPUT 链 : $policy_v4"
    echo -e "    - IPv6 INPUT 链 : $policy_v6"
    echo -e " 🌐 ${CYAN}ICMP 响应状态 (PING):${RESET}"
    echo -e "    - IPv4 Ping 回应: $ping_status_v4"
    echo -e "    - IPv6 Ping 回应: $ping_status_v6"
    echo -e "${CYAN}--------------------------------------------------${RESET}"

    echo -e " 🔓 ${GREEN}当前对宿主机公网开放的端口列表：${RESET}"
    echo -e "    +----------+--------------------------------------+"
    echo -e "    | ${YELLOW}协议类型${RESET} | ${YELLOW}开放的端口号${RESET}                      |"
    echo -e "    +----------+--------------------------------------+"
    printf "    |  %-6s  | %-36s |\n" "TCP" "$ports_tcp"
    printf "    |  %-6s  | %-36s |\n" "UDP" "$ports_udp"
    echo -e "    +----------+--------------------------------------+"
    echo -e "${CYAN}--------------------------------------------------${RESET}"

    echo -e " ⚪ ${BLUE}IP 白名单规则 (放行特定源 IP)：${RESET}"
    local whitelist=$(iptables -L INPUT -n 2>/dev/null | grep "ACCEPT" | grep -vE "dpt:|spt:|0.0.0.0/0|state|ctstate" | awk '{print $4}' | grep -v "0.0.0.0" || true)
    local whitelist6=$(ip6tables -L INPUT -n 2>/dev/null | grep "ACCEPT" | grep -vE "dpt:|spt:|::/0|state|ctstate" | awk '{print $4}' | grep -v "::" || true)
    
    if [ -n "$whitelist" ] || [ -n "$whitelist6" ]; then
        for ip in $whitelist; do echo -e "    ⚡ [IPv4] -> $ip"; done
        for ip in $whitelist6; do echo -e "    ⚡ [IPv6] -> $ip"; done
    else
        echo -e "    (当前无特定 IP 白名单规则)"
    fi

    echo -e "\n ⚫ ${RED}IP 黑名单规则 (已同步阻断宿主机与 Docker)：${RESET}"
    local blacklist=$(iptables -L INPUT -n 2>/dev/null | grep -E "DROP|REJECT" | grep -vE "dpt:|spt:|0.0.0.0/0" | awk '{print $4}' | grep -v "0.0.0.0" || true)
    local blacklist6=$(ip6tables -L INPUT -n 2>/dev/null | grep -E "DROP|REJECT" | grep -vE "dpt:|spt:|::/0" | awk '{print $4}' | grep -v "::" || true)
    
    if [ -n "$blacklist" ] || [ -n "$blacklist6" ]; then
        for ip in $blacklist; do echo -e "    ❌ [IPv4] -> $ip"; done
        for ip in $blacklist6; do echo -e "    ❌ [IPv6] -> $ip"; done
    else
        echo -e "    (当前无特定 IP 黑名单规则)"
    fi

    echo -e "${CYAN}==================================================${RESET}"
    printf "按回车返回主菜单..." && read -r _
}

# ===============================
# 管理菜单
# ===============================
menu() {
    while true; do
        STATUS=$(get_firewall_status)
        TYPE_SHOW=$(get_firewall_type)
        PORT_SHOW=$(get_ssh_port)
        SITE_COUNT=$(get_banned_ip_count)

        clear
        echo -e "${GREEN}===============================${RESET}"
        echo -e "${GREEN}     ◈  双栈防火墙控制台 ◈     ${RESET}"
        echo -e "${GREEN}===============================${RESET}"
        echo -e "${GREEN} 状态  : ${STATUS}"
        echo -e "${GREEN} 内核  : ${YELLOW}${TYPE_SHOW}${RESET}"
        echo -e "${GREEN} 端口  : ${YELLOW}${PORT_SHOW}${RESET}"
        echo -e "${GREEN} 封禁  : ${YELLOW}${SITE_COUNT} 个 IP${RESET}"
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
        echo -e "${GREEN} 12. 卸载防火墙${RESET}"
        echo -e "${GREEN}  0. 退出${RESET}"
        echo -e "${GREEN}===============================${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        read -r choice

        case $choice in
            1)
                printf "请输入要开放的端口号: " && read -r PORT
                if ! echo "$PORT" | grep -qE '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                    echo -e "${RED}❌ 错误：请输入 1-65535 之间的有效端口号${RESET}"
                    printf "按回车返回菜单..." && read -r _
                    continue
                fi
                for proto in iptables ip6tables; do
                    while $proto -C INPUT -p tcp --dport "$PORT" -j DROP 2>/dev/null; do $proto -D INPUT -p tcp --dport "$PORT" -j DROP; done
                    while $proto -C INPUT -p udp --dport "$PORT" -j DROP 2>/dev/null; do $proto -D INPUT -p udp --dport "$PORT" -j DROP; done
                    if ! $proto -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
                        $proto -I INPUT -p tcp --dport "$PORT" -j ACCEPT
                    fi
                    if ! $proto -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null; then
                        $proto -I INPUT -p udp --dport "$PORT" -j ACCEPT
                    fi
                done
                save_rules
                echo -e "${GREEN}✅ 已开放端口 $PORT${RESET}"
                printf "按回车继续..." && read -r _
                ;;
            2)
                printf "请输入要关闭的端口号: " && read -r PORT
                if ! echo "$PORT" | grep -qE '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                    echo -e "${RED}❌ 错误：请输入 1-65535 之间的有效端口号${RESET}"
                    printf "按回车返回菜单..." && read -r _
                    continue
                fi
                if [ "$PORT" -eq "$PORT_SHOW" ]; then
                    echo -e "${RED}⚠️ 拒绝操作：当前端口为 SSH 端口！${RESET}"
                    printf "按回车返回菜单..." && read -r _
                    continue
                fi
                for proto in iptables ip6tables; do
                    while $proto -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; do $proto -D INPUT -p tcp --dport "$PORT" -j ACCEPT; done
                    while $proto -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null; do $proto -D INPUT -p udp --dport "$PORT" -j ACCEPT; done
                    if ! $proto -C INPUT -p tcp --dport "$PORT" -j DROP 2>/dev/null; then
                        $proto -I INPUT -p tcp --dport "$PORT" -j DROP
                    fi
                    if ! $proto -C INPUT -p udp --dport "$PORT" -j DROP 2>/dev/null; then
                        $proto -I INPUT -p udp --dport "$PORT" -j DROP
                    fi
                done
                save_rules
                echo -e "${GREEN}✅ 已关闭宿主机端口 $PORT (注:若该端口由Docker映射，可在容器配置中管理)${RESET}"
                printf "按回车继续..." && read -r _
                ;;
            3) open_all_ports ;;
            4) restore_default_rules ;;
            5)
                printf "请输入要放行的IP: " && read -r IP
                ip_action accept "$IP"
                save_rules
                echo -e "${GREEN}✅ IP $IP 已放行${RESET}"
                printf "按回车继续..." && read -r _
                ;;
            6)
                printf "请输入要封禁的IP: " && read -r IP
                ip_action drop "$IP"
                save_rules
                echo -e "${GREEN}✅ IP $IP 已封禁（已同步应用至宿主机与Docker容器）${RESET}"
                printf "按回车继续..." && read -r _
                ;;
            7)
                printf "请输入要删除的IP: " && read -r IP
                ip_action delete "$IP"
                save_rules
                echo -e "${GREEN}✅ IP $IP 规则已删除${RESET}"
                printf "按回车继续..." && read -r _
                ;;
            8)
                ping_action allow
                save_rules
                echo -e "${GREEN}✅ 已允许 PING（ICMP）${RESET}"
                printf "按回车继续..." && read -r _
                ;;
            9)
                ping_action deny
                save_rules
                echo -e "${GREEN}✅ 已禁用 PING（ICMP）${RESET}"
                printf "按回车继续..." && read -r _
                ;;
            10) view_visual_rules ;;
            11) save_and_enable_autoload ;;
            12) uninstall_firewall ;;
            0) clear; break ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

# ===============================
# 脚本入口
# ===============================
if [ "$(id -u)" -ne 0 ]; then
   echo -e "${RED}❌ 错误: 请使用 root 权限运行此脚本！${RESET}"
   exit 1
fi

if ! check_installed; then
    install_firewall
fi

menu
