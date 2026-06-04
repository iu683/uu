#!/bin/sh
set -e

# ===============================
# 防火墙管理脚本（Alpine Linux 双栈 IPv4/IPv6 - Docker 完美兼容版）
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
    [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]] && port=22
    echo "$port"
}

get_firewall_status() {
    if rc-service iptables status 2>/dev/null | grep -q "started"; then
        echo -e "${YELLOW}● 已开启(开机自启)${RESET}"
    else
        if iptables -P INPUT 2>/dev/null | grep -q "DROP"; then
            echo -e "${YELLOW}运行中(未设自启)${RESET}"
        else
            echo -e "${RED}○ 已关闭 (全放行)${RESET}"
        fi
    fi
}

get_firewall_type() {
    if command -v iptables &>/dev/null; then
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
    local count4 count6 total
    count4=$(iptables -S INPUT 2>/dev/null | grep " -j DROP" | grep -vE "dport|sport" | wc -l || echo 0)
    count6=$(ip6tables -S INPUT 2>/dev/null | grep " -j DROP" | grep -vE "dport|sport" | wc -l || echo 0)
    total=$((count4 + count6))
    echo "$total"
}

# ===============================
# 防火墙核心逻辑函数
# ===============================

save_rules() {
    # Alpine 存储机制
    if [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    else
        # 兼容旧版 Alpine 路径
        rc-service iptables save 2>/dev/null || true
        rc-service ip6tables save 2>/dev/null || true
    fi
}

save_and_enable_autoload() {
    save_rules
    rc-update add iptables default 2>/dev/null || true
    rc-update add ip6tables default 2>/dev/null || true
    rc-service iptables start 2>/dev/null || true
    rc-service ip6tables start 2>/dev/null || true
    echo -e "${GREEN}✅ 规则已保存，并设置为开机自动加载${RESET}"
    read -p "按回车继续..."
}

init_rules() {
    local ssh_port
    ssh_port=$(get_ssh_port)
    for proto in iptables ip6tables; do
        # 【Docker 兼容】：不执行全局清空(-F)，只精准清空 INPUT 链
        $proto -F INPUT
        
        # 核心策略
        $proto -P INPUT DROP
        $proto -P FORWARD ACCEPT
        $proto -P OUTPUT ACCEPT
        
        # 基础放行规则
        $proto -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        $proto -A INPUT -i lo -j ACCEPT
        $proto -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
        $proto -A INPUT -p tcp --dport 80 -j ACCEPT
        $proto -A INPUT -p tcp --dport 443 -j ACCEPT
    done
    save_rules
    rc-update add iptables default 2>/dev/null || true
    rc-update add ip6tables default 2>/dev/null || true
}

check_installed() {
    # 检查 alpine 核心防火墙包及 OpenRC 脚本是否存在
    [ -f /etc/init.d/iptables ] && command -v iptables &>/dev/null
}

install_firewall() {
    echo -e "${YELLOW}正在安装防火墙，请稍候...${RESET}"
    apk update
    # 确保安装了 iptables、ip6tables、iproute2等基础包
    apk add iptables ip6tables curl
    
    # 建立规则目录
    mkdir -p /etc/iptables
    
    init_rules
    rc-service iptables start 2>/dev/null || true
    rc-service ip6tables start 2>/dev/null || true
    echo -e "${GREEN}✅ 防火墙安装完成，默认放行 SSH/80/443${RESET}"
    echo -e "${GREEN}✅ 已设置开机自动加载规则${RESET}"
    read -p "按回车继续..."
}

clear_firewall() {
    echo -e "${YELLOW}正在恢复宿主机默认策略并放行所有流量...${RESET}"
    for proto in iptables ip6tables; do
        $proto -F INPUT
        $proto -P INPUT ACCEPT
        $proto -P FORWARD ACCEPT
        $proto -P OUTPUT ACCEPT
    done
    if iptables -L DOCKER-USER -n &>/dev/null; then
        iptables -F DOCKER-USER
    fi
    save_rules
    rc-update del iptables default 2>/dev/null || true
    rc-update del ip6tables default 2>/dev/null || true
    echo -e "${GREEN}✅ 防火墙入站限制已清空，宿主机流量已全放行（未损坏 Docker 链）${RESET}"
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
    echo -e "${YELLOW}正在放行所有宿主机端口（IPv4/IPv6）...${RESET}"
    for proto in iptables ip6tables; do
        $proto -F INPUT
        $proto -P INPUT ACCEPT
        $proto -P FORWARD ACCEPT
    done
    save_rules
    echo -e "${GREEN}✅ 宿主机所有端口已放行（全开放）${RESET}"
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
        accept) 
            if ! $proto -C INPUT -s "$ip" -j ACCEPT 2>/dev/null; then
                $proto -I INPUT 1 -s "$ip" -j ACCEPT 
            fi
            ;;
        drop)   
            if ! $proto -C INPUT -s "$ip" -j DROP 2>/dev/null; then
                $proto -I INPUT 1 -s "$ip" -j DROP 
            fi
            # 【Docker 兼容改造】
            if [ "$proto" = "iptables" ] && iptables -L DOCKER-USER -n &>/dev/null; then
                if ! iptables -C DOCKER-USER -s "$ip" -j DROP 2>/dev/null; then
                    iptables -I DOCKER-USER 1 -s "$ip" -j DROP
                fi
            fi
            ;;
        delete)
            while $proto -C INPUT -s "$ip" -j ACCEPT 2>/dev/null; do $proto -D INPUT -s "$ip" -j ACCEPT; done
            while $proto -C INPUT -s "$ip" -j DROP 2>/dev/null; do $proto -D INPUT -s "$ip" -j DROP; done
            if [ "$proto" = "iptables" ] && iptables -L DOCKER-USER -n &>/dev/null; then
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
    read -p "确定要彻底卸载吗？(y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消卸载。"
        read -p "按回车继续..."
        return
    fi

    echo -e "${YELLOW}正在清理宿主机 INPUT 规则并修改策略...${RESET}"
    for proto in iptables ip6tables; do
        $proto -F INPUT
        $proto -P INPUT ACCEPT
        $proto -P FORWARD ACCEPT
        $proto -P OUTPUT ACCEPT
    done
    if iptables -L DOCKER-USER -n &>/dev/null; then
        iptables -F DOCKER-USER
    fi

    echo -e "${YELLOW}正在停止并卸载守护服务...${RESET}"
    rc-service iptables stop 2>/dev/null || true
    rc-service ip6tables stop 2>/dev/null || true
    rc-update del iptables default 2>/dev/null || true
    rc-update del ip6tables default 2>/dev/null || true
    
    rm -rf /etc/iptables
    apk del iptables ip6tables

    echo -e "${GREEN}✅ 防火墙已彻底卸载，Docker 及系统核心流量未受干扰。${RESET}"
    exit 0
}

view_visual_rules() {
    clear
    local ports_tcp ports_udp ping_status_v4 ping_status_v6
    local policy_v4 policy_v6

    # 适配 Alpine/Busybox 的 awk / grep 提炼规则
    policy_v4=$(iptables -L INPUT -n 2>/dev/null | head -n 1 | awk '{print $4}' | tr -d ')')
    policy_v6=$(ip6tables -L INPUT -n 2>/dev/null | head -n 1 | awk '{print $4}' | tr -d ')')
    [[ -z "$policy_v4" ]] && policy_v4="UNKNOWN"
    [[ -z "$policy_v6" ]] && policy_v6="UNKNOWN"

    ports_tcp=$( (iptables -S INPUT 2>/dev/null; ip6tables -S INPUT 2>/dev/null) | grep " -j ACCEPT" | grep "dport " | grep -E "tcp" | awk '{for(i=1;i<=NF;i++) if($i=="--dport") print $(i+1)}' | sort -nu | tr '\n' ' ')
    ports_udp=$( (iptables -S INPUT 2>/dev/null; ip6tables -S INPUT 2>/dev/null) | grep " -j ACCEPT" | grep "dport " | grep -E "udp" | awk '{for(i=1;i<=NF;i++) if($i=="--dport") print $(i+1)}' | sort -nu | tr '\n' ' ')
    [[ -z "$ports_tcp" ]] && ports_tcp="无"
    [[ -z "$ports_udp" ]] && ports_udp="无"

    if iptables -S INPUT 2>/dev/null | grep "icmp" | grep -q "DROP"; then ping_status_v4="${RED}禁打(DROP)${RESET}"; else ping_status_v4="${GREEN}允许(ACCEPT)${RESET}"; fi
    if ip6tables -S INPUT 2>/dev/null | grep "icmpv6" | grep -q "DROP"; then ping_status_v6="${RED}禁打(DROP)${RESET}"; else ping_status_v6="${GREEN}允许(ACCEPT)${RESET}"; fi

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
    # 改用 awk 规避 busybox grep 不支持 -P 的局限性
    local whitelist=$(iptables -S INPUT 2>/dev/null | grep " -j ACCEPT" | grep -E " -s [0-9]" | grep -vE "dport|sport|lo|state" | awk '{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}')
    local whitelist6=$(ip6tables -S INPUT 2>/dev/null | grep " -j ACCEPT" | grep -E " -s [0-9a-fA-F:]" | grep -vE "dport|sport|lo|state" | awk '{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}')
    
    if [[ -n "$whitelist" || -n "$whitelist6" ]]; then
        for ip in $whitelist; do echo -e "    ⚡ [IPv4] -> $ip"; done
        for ip in $whitelist6; do echo -e "    ⚡ [IPv6] -> $ip"; done
    else
        echo -e "    (当前无特定 IP 白名单规则)"
    fi

    echo -e "\n ⚫ ${RED}IP 黑名单规则 (已同步阻断宿主机与 Docker)：${RESET}"
    local blacklist=$(iptables -S INPUT 2>/dev/null | grep " -j DROP" | grep -E " -s [0-9]" | grep -vE "dport|sport" | awk '{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}')
    local blacklist6=$(ip6tables -S INPUT 2>/dev/null | grep " -j DROP" | grep -E " -s [0-9a-fA-F:]" | grep -vE "dport|sport" | awk '{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}')
    
    if [[ -n "$blacklist" || -n "$blacklist6" ]]; then
        for ip in $blacklist; do echo -e "    ❌ [IPv4] -> $ip"; done
        for ip in $blacklist6; do echo -e "    ❌ [IPv6] -> $ip"; done
    else
        echo -e "    (当前无特定 IP 黑名单规则)"
    fi

    echo -e "${CYAN}==================================================${RESET}"
    read -r -p "按回车返回主菜单..." || true
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
        echo -e "${GREEN}    ◈   双栈防火墙控制台   ◈   ${RESET}"
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
                read -p "请输入要开放的端口号: " PORT
                if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                    echo -e "${RED}❌ 错误：请输入 1-65535 之间的有效端口号${RESET}"
                    read -p "按回车返回菜单..."
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
                read -p "按回车继续..."
                ;;
            2)
                read -p "请输入要关闭的端口号: " PORT
                if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                    echo -e "${RED}❌ 错误：请输入 1-65535 之间的有效端口号${RESET}"
                    read -p "按回车返回菜单..."
                    continue
                fi
                
                if [ "$PORT" -eq "$PORT_SHOW" ]; then
                    echo -e "${RED}⚠️ 拒绝操作：当前端口为 SSH 端口！${RESET}"
                    read -p "按回车返回菜单..."
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
                echo -e "${GREEN}✅ IP $IP 已封禁（已同步应用至宿主机与Docker容器）${RESET}"
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
