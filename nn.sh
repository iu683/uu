#!/bin/sh
set -e

# ===============================
# 防火墙管理脚本（Alpine Linux 双栈 IPv4/IPv6 - 终极修复版）
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
    if [ -z "$port" ] || ! echo "$port" | grep -qE '^[0-9]+$'; then
        port=22
    fi
    echo "$port"
}

get_firewall_status() {
    if iptables -L INPUT -n 2>/dev/null | head -n 1 | grep -q "policy DROP"; then
        if [ -f /etc/init.d/iptables ] && rc-status default 2>/dev/null | grep -q "iptables"; then
            echo -e "${GREEN}● 已开启 (开机自启)${RESET}"
        else
            echo -e "${GREEN}● 运行中 (策略已拦截)${RESET}"
        fi
    else
        echo -e "${RED}○ 已关闭 (全放行)${RESET}"
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
    # Alpine 规范：规则必须保存在 /etc/iptables/ 目录下供 openrc 读取
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    
    # 联动 Alpine OpenRC 核心持久化
    if command -v rc-service >/dev/null 2>&1; then
        rc-service iptables save >/dev/null 2>&1 || true
        rc-service ip6tables save >/dev/null 2>&1 || true
    fi
}

save_and_enable_autoload() {
    save_rules
    if command -v rc-update >/dev/null 2>&1 && [ -f /etc/init.d/iptables ]; then
        rc-update add iptables default >/dev/null 2>&1 || true
        rc-update add ip6tables default >/dev/null 2>&1 || true
        rc-service iptables start >/dev/null 2>&1 || true
        rc-service ip6tables start >/dev/null 2>&1 || true
        echo -e "${GREEN}✅ 规则已成功保存，OpenRC 服务开机自启已同步激活！${RESET}"
    else
        echo -e "${RED}❌ 错误：未检测到系统 OpenRC 防火墙服务！${RESET}"
    fi
    read -p "按回车继续..."
}

init_rules() {
    local ssh_port
    ssh_port=$(get_ssh_port)
    for proto in iptables ip6tables; do
        # 【Docker 兼容】：绝对不用全局清空(-F)，只精准清空自身 INPUT 链
        $proto -F INPUT
        
        # 核心策略：入站拦截，转发和出站保持 ACCEPT（Docker 极度依赖 FORWARD 互联）
        $proto -P INPUT DROP
        $proto -P FORWARD ACCEPT
        $proto -P OUTPUT ACCEPT
        
        # 基础放行规则（用 -A 追加，确保前排 -I 1 的 IP 黑白名单有最高优先级）
        $proto -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        $proto -A INPUT -i lo -j ACCEPT
        $proto -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
        $proto -A INPUT -p tcp --dport 80 -j ACCEPT
        $proto -A INPUT -p tcp --dport 443 -j ACCEPT
    done
    # 核心修复：初始化完毕立即强制落盘并调用自启注册，确保首次安装成功率
    save_rules
}

check_installed() {
    if command -v iptables >/dev/null 2>&1 && [ -f /etc/init.d/iptables ]; then
        return 0
    else
        return 1
    fi
}

install_firewall() {
    echo -e "${YELLOW}正在为 Alpine Linux 安装并初始化防火墙环境，请稍候...${RESET}"
    apk update
    apk add iptables ip6tables curl iptables-openrc
    
    # 核心修复：建立目录 -> 灌入默认规则 -> 生成初始 rules 文件
    mkdir -p /etc/iptables
    init_rules
    
    # 核心修复：只有在 rules 配置文件存在后，启动 openrc 服务才不会报错挂起
    if command -v rc-update >/dev/null 2>&1; then
        rc-update add iptables default >/dev/null 2>&1 || true
        rc-update add ip6tables default >/dev/null 2>&1 || true
        rc-service iptables start >/dev/null 2>&1 || true
        rc-service ip6tables start >/dev/null 2>&1 || true
    fi
    echo -e "${GREEN}✅ 首次安装成功！默认安全规则已加载，且已设置为【开机自动启动】。${RESET}"
    read -p "按回车继续..."
}

clear_firewall() {
    echo -e "${YELLOW}正在恢复宿主机默认策略并放行所有流量...${RESET}"
    for proto in iptables ip6tables; do
        $proto -F INPUT
        $proto -P INPUT ACCEPT
    done
    if iptables -L DOCKER-USER -n >/dev/null 2>&1; then
        iptables -F DOCKER-USER
    fi
    save_rules
    echo -e "${GREEN}✅ 防火墙限制已清空，流量已全面放行 (未损坏 Docker 内部链)${RESET}"
    read -p "按回车继续..."
}

restore_default_rules() {
    echo -e "${YELLOW}正在恢复默认防火墙规则 (仅放行 SSH/80/443)...${RESET}"
    init_rules
    echo -e "${GREEN}✅ 默认规则已恢复${RESET}"
    read -p "按回车继续..."
}

open_all_ports() {
    echo -e "${YELLOW}正在放行所有宿主机端口（IPv4/IPv6）...${RESET}"
    for proto in iptables ip6tables; do
        $proto -F INPUT
        $proto -P INPUT ACCEPT
    done
    save_rules
    echo -e "${GREEN}✅ 宿主机所有公网端口已放行${RESET}"
    read -p "按回车继续..."
}

ip_action() {
    local action=$1 ip=$2 proto
    if echo "$ip" | grep -q ":"; then proto="ip6tables"; else proto="iptables"; fi

    while $proto -D INPUT -s "$ip" -j ACCEPT >/dev/null 2>&1; do :; done
    while $proto -D INPUT -s "$ip" -j DROP >/dev/null 2>&1; do :; done
    if [ "$proto" = "iptables" ] && iptables -L DOCKER-USER -n >/dev/null 2>&1; then
        while iptables -D DOCKER-USER -s "$ip" -j DROP >/dev/null 2>&1; do :; done
    fi

    case $action in
        accept) 
            $proto -I INPUT 1 -s "$ip" -j ACCEPT 
            ;;
        drop)   
            $proto -I INPUT 1 -s "$ip" -j DROP 
            if [ "$proto" = "iptables" ] && iptables -L DOCKER-USER -n >/dev/null 2>&1; then
                iptables -I DOCKER-USER 1 -s "$ip" -j DROP
            fi
            ;;
    esac
}

ping_action() {
    local action=$1
    
    # 核心修复：全面安全清理旧的包含 BusyBox 精准模块定位的 ICMP 规则
    while iptables -D INPUT -p icmp -m icmp --icmp-type echo-request -j ACCEPT >/dev/null 2>&1; do :; done
    while iptables -D INPUT -p icmp -m icmp --icmp-type echo-request -j DROP >/dev/null 2>&1; do :; done
    while ip6tables -D INPUT -p icmpv6 -m icmpv6 --icmpv6-type echo-request -j ACCEPT >/dev/null 2>&1; do :; done
    while ip6tables -D INPUT -p icmpv6 -m icmpv6 --icmpv6-type echo-request -j DROP >/dev/null 2>&1; do :; done

    if [ "$action" = "allow" ]; then
        # 核心修复：Alpine 必须显式附带 -m icmp / -m icmpv6 模块声明
        iptables -A INPUT -p icmp -m icmp --icmp-type echo-request -j ACCEPT
        ip6tables -A INPUT -p icmpv6 -m icmpv6 --icmpv6-type echo-request -j ACCEPT
    else
        # 禁用 PING 时采取 1 号位强行置顶拦截
        iptables -I INPUT 1 -p icmp -m icmp --icmp-type echo-request -j DROP
        ip6tables -I INPUT 1 -p icmpv6 -m icmpv6 --icmpv6-type echo-request -j DROP
    fi
}

uninstall_firewall() {
    clear
    echo -e "${RED}⚠️ 警告：该操作将清空所有入站规则并彻底从 Alpine 卸载防火墙！${RESET}"
    read -p "确定要彻底卸载吗？(y/n): " confirm
    if ! echo "$confirm" | grep -qE '^[Yy]$'; then return; fi

    echo -e "${YELLOW}正在恢复网络默认放行状态...${RESET}"
    for proto in iptables ip6tables; do
        $proto -F INPUT
        $proto -P INPUT ACCEPT
    done
    if iptables -L DOCKER-USER -n >/dev/null 2>&1; then
        iptables -F DOCKER-USER
    fi
    
    rm -rf /etc/iptables
    if command -v rc-update >/dev/null 2>&1; then
        rc-update del iptables default >/dev/null 2>&1 || true
        rc-update del ip6tables default >/dev/null 2>&1 || true
    fi
    apk del iptables iptables-openrc 2>/dev/null || true
    echo -e "${GREEN}✅ 防火墙已彻底卸载！${RESET}"
    exit 0
}

view_visual_rules() {
    clear
    local ports_tcp ports_udp ping_status_v4 ping_status_v6
    local policy_v4 policy_v6

    policy_v4=$(iptables -L INPUT -n 2>/dev/null | head -n 1 | awk '{print $4}' | tr -d ')')
    policy_v6=$(ip6tables -L INPUT -n 2>/dev/null | head -n 1 | awk '{print $4}' | tr -d ')')
    [ -z "$policy_v4" ] && policy_v4="UNKNOWN"
    [ -z "$policy_v6" ] && policy_v6="UNKNOWN"

    ports_tcp=$( (iptables -S INPUT 2>/dev/null; ip6tables -S INPUT 2>/dev/null) | grep " -j ACCEPT" | grep "dport " | grep -E "tcp" | awk '{for(i=1;i<=NF;i++) if($i=="--dport") print $(i+1)}' | sort -nu | tr '\n' ' ')
    ports_udp=$( (iptables -S INPUT 2>/dev/null; ip6tables -S INPUT 2>/dev/null) | grep " -j ACCEPT" | grep "dport " | grep -E "udp" | awk '{for(i=1;i<=NF;i++) if($i=="--dport") print $(i+1)}' | sort -nu | tr '\n' ' ')
    [ -z "$ports_tcp" ] && ports_tcp="无"
    [ -z "$ports_udp" ] && ports_udp="无"

    if iptables -S INPUT 2>/dev/null | grep "icmp" | grep -q "DROP"; then ping_status_v4="${RED}禁打 (DROP)${RESET}"; else ping_status_v4="${GREEN}允许 (ACCEPT)${RESET}"; fi
    if ip6tables -S INPUT 2>/dev/null | grep "icmpv6" | grep -q "DROP"; then ping_status_v6="${RED}禁打 (DROP)${RESET}"; else ping_status_v6="${GREEN}允许 (ACCEPT)${RESET}"; fi

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
    local whitelist=$(iptables -S INPUT 2>/dev/null | grep " -j ACCEPT" | grep -E " -s " | grep -vE "dport|sport|lo|state" | awk '{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}' || true)
    local whitelist6=$(ip6tables -S INPUT 2>/dev/null | grep " -j ACCEPT" | grep -E " -s " | grep -vE "dport|sport|lo|state" | awk '{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}' || true)
    
    if [ -n "$whitelist" ] || [ -n "$whitelist6" ]; then
        for ip in $whitelist; do echo -e "    ⚡ [IPv4] -> $ip"; done
        for ip in $whitelist6; do echo -e "    ⚡ [IPv6] -> $ip"; done
    else
        echo -e "    (当前无特定 IP 白名单规则)"
    fi

    echo -e "\n ⚫ ${RED}IP 黑名单规则 (已同步阻断宿主机与 Docker)：${RESET}"
    local blacklist=$(iptables -S INPUT 2>/dev/null | grep " -j DROP" | grep -E " -s " | grep -vE "dport|sport|icmp" | awk '{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}' || true)
    local blacklist6=$(ip6tables -S INPUT 2>/dev/null | grep " -j DROP" | grep -E " -s " | grep -vE "dport|sport|icmp" | awk '{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}' || true)
    
    if [ -n "$blacklist" ] || [ -n "$blacklist6" ]; then
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
        echo -e "${GREEN}    ◈  Alpine 双栈防火墙控制台 ◈      ${RESET}"
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
        echo -e "${GREEN} 11. 保存规则并应用永久同步${RESET}"
        echo -e "${GREEN} 12. 卸载防火墙${RESET}"
        echo -e "${GREEN}  0. 退出${RESET}"
        echo -e "${GREEN}===============================${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        read -r choice

        case $choice in
            1)
                read -p "请输入要开放的端口号: " PORT
                if [ -z "$PORT" ] || ! echo "$PORT" | grep -qE '^[0-9]+$'; then
                    echo -e "${RED}❌ 错误：请输入有效的端口号${RESET}"; sleep 1; continue
                fi
                for proto in iptables ip6tables; do
                    while $proto -D INPUT -p tcp --dport "$PORT" -j DROP >/dev/null 2>&1; do :; done
                    while $proto -D INPUT -p udp --dport "$PORT" -j DROP >/dev/null 2>&1; do :; done
                    
                    if ! $proto -C INPUT -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1; then
                        $proto -A INPUT -p tcp --dport "$PORT" -j ACCEPT
                    fi
                    if ! $proto -C INPUT -p udp --dport "$PORT" -j ACCEPT >/dev/null 2>&1; then
                        $proto -A INPUT -p udp --dport "$PORT" -j ACCEPT
                    fi
                done
                save_rules
                echo -e "${GREEN}✅ 已开放端口 $PORT${RESET}"
                read -p "按回车继续..."
                ;;
            2)
                read -p "请输入要关闭的端口号: " PORT
                if [ -z "$PORT" ] || ! echo "$PORT" | grep -qE '^[0-9]+$'; then
                    echo -e "${RED}❌ 错误：请输入有效的端口号${RESET}"; sleep 1; continue
                fi
                if [ "$PORT" = "$PORT_SHOW" ]; then
                    echo -e "${RED}⚠️ 拒绝操作：当前端口为 SSH 端口！${RESET}"; read -p "按回车返回菜单..."; continue
                fi
                for proto in iptables ip6tables; do
                    while $proto -D INPUT -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1; do :; done
                    while $proto -D INPUT -p udp --dport "$PORT" -j ACCEPT >/dev/null 2>&1; do :; done
                    
                    if ! $proto -C INPUT -p tcp --dport "$PORT" -j DROP >/dev/null 2>&1; then
                        $proto -A INPUT -p tcp --dport "$PORT" -j DROP
                    fi
                    if ! $proto -C INPUT -p udp --dport "$PORT" -j DROP >/dev/null 2>&1; then
                        $proto -A INPUT -p udp --dport "$PORT" -j DROP
                    fi
                done
                save_rules
                echo -e "${GREEN}✅ 已关闭宿主机端口 $PORT (注:若由Docker映射，可在容器配置中管理)${RESET}"
                read -p "按回车继续..."
                ;;
            3) open_all_ports ;;
            4) restore_default_rules ;;
            5)
                read -p "请输入要放行的IP: " IP
                if [ -n "$IP" ]; then
                    ip_action accept "$IP"
                    save_rules
                    echo -e "${GREEN}✅ IP $IP 已放行${RESET}"
                fi
                read -p "按回车继续..."
                ;;
            6)
                read -p "请输入要封禁的IP: " IP
                if [ -n "$IP" ]; then
                    ip_action drop "$IP"
                    save_rules
                    echo -e "${GREEN}✅ IP $IP 已封禁（已同步应用至宿主机与Docker容器）${RESET}"
                fi
                read -p "按回车继续..."
                ;;
            7)
                read -p "请输入要删除的IP: " IP
                if [ -n "$IP" ]; then
                    ip_action delete "$IP"
                    save_rules
                    echo -e "${GREEN}✅ IP $IP 规则已删除${RESET}"
                fi
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
