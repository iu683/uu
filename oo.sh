#!/bin/sh
set -e

# ===============================
# 防火墙管理脚本（Alpine Linux 双栈 IPv4/IPv6 - POSIX 完美修复版）
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
    if [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
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
        echo -e "${GREEN}✅ 规则已保存并注册服务${RESET}"
    else
        mkdir -p /etc/local.d >/dev/null 2>&1 || true
        echo "#!/bin/sh" > /etc/local.d/firewall.start 2>/dev/null || true
        echo "iptables-restore < /etc/iptables/rules.v4" >> /etc/local.d/firewall.start 2>/dev/null || true
        echo "ip6tables-restore < /etc/iptables/rules.v6" >> /etc/local.d/firewall.start 2>/dev/null || true
        chmod +x /etc/local.d/firewall.start >/dev/null 2>&1 || true
        echo -e "${GREEN}✅ 规则已成功保存到本地 (已通过 local.d 注入后门自启)${RESET}"
    fi
    read -p "按回车继续..."
}

init_rules() {
    local ssh_port
    ssh_port=$(get_ssh_port)
    for proto in iptables ip6tables; do
        $proto -F INPUT
        $proto -F OUTPUT
        $proto -P INPUT DROP
        $proto -P FORWARD ACCEPT
        $proto -P OUTPUT ACCEPT
        $proto -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        $proto -A INPUT -i lo -j ACCEPT
        $proto -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
        $proto -A INPUT -p tcp --dport 80 -j ACCEPT
        $proto -A INPUT -p tcp --dport 443 -j ACCEPT
    done
    save_rules
}

check_installed() {
    # 彻底重写：使用最稳健的 POSIX 显式返回，解决 Ash 条件连写状态码丢失的 Bug
    if command -v iptables >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

install_firewall() {
    echo -e "${YELLOW}正在初始化环境，请稍候...${RESET}"
    apk update
    apk add iptables ip6tables curl iptables-openrc 2>/dev/null || apk add iptables ip6tables curl
    mkdir -p /etc/iptables
    init_rules
    if command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/iptables ]; then
        rc-update add iptables default >/dev/null 2>&1 || true
        rc-update add ip6tables default >/dev/null 2>&1 || true
    fi
    echo -e "${GREEN}✅ 初始化完成，默认安全防御已开启${RESET}"
    read -p "按回车继续..."
}

clear_firewall() {
    echo -e "${YELLOW}正在恢复宿主机默认策略并放行所有流量...${RESET}"
    for proto in iptables ip6tables; do
        $proto -F INPUT
        $proto -F OUTPUT
        $proto -P INPUT ACCEPT
        $proto -P FORWARD ACCEPT
        $proto -P OUTPUT ACCEPT
    done
    save_rules
    echo -e "${GREEN}✅ 防火墙限制已清空，流量已全放行${RESET}"
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
        $proto -P FORWARD ACCEPT
    done
    save_rules
    echo -e "${GREEN}✅ 所有端口已放行${RESET}"
    read -p "按回车继续..."
}

ip_action() {
    local action=$1 ip=$2 proto
    if echo "$ip" | grep -q ":"; then proto="ip6tables"; else proto="iptables"; fi

    case $action in
        accept) 
            if ! $proto -C INPUT -s "$ip" -j ACCEPT >/dev/null 2>&1; then $proto -I INPUT 1 -s "$ip" -j ACCEPT; fi
            ;;
        drop)   
            if ! $proto -C INPUT -s "$ip" -j DROP >/dev/null 2>&1; then $proto -I INPUT 1 -s "$ip" -j DROP; fi
            ;;
        delete)
            while $proto -C INPUT -s "$ip" -j ACCEPT >/dev/null 2>&1; do $proto -D INPUT -s "$ip" -j ACCEPT; done
            while $proto -C INPUT -s "$ip" -j DROP >/dev/null 2>&1; do $proto -D INPUT -s "$ip" -j DROP; done
            ;;
    esac
}

ping_action() {
    local action=$1
    iptables -F OUTPUT 2>/dev/null || true
    ip6tables -F OUTPUT 2>/dev/null || true

    while iptables -S INPUT 2>/dev/null | grep -q "icmp"; do
        local rule=$(iptables -S INPUT 2>/dev/null | grep "icmp" | head -n 1 | sed 's/-A/iptables -D/')
        eval "$rule" >/dev/null 2>&1 || break
    done
    while ip6tables -S INPUT 2>/dev/null | grep -q "icmpv6"; do
        local rule=$(ip6tables -S INPUT 2>/dev/null | grep "icmpv6" | head -n 1 | sed 's/-A/ip6tables -D/')
        eval "$rule" >/dev/null 2>&1 || break
    done

    if [ "$action" = "allow" ]; then
        iptables -I INPUT 1 -p icmp --icmp-type echo-request -j ACCEPT
        ip6tables -I INPUT 1 -p icmpv6 --icmpv6-type echo-request -j ACCEPT
    else
        iptables -I INPUT 1 -p icmp --icmp-type echo-request -j DROP
        ip6tables -I INPUT 1 -p icmpv6 --icmpv6-type echo-request -j DROP
    fi
}

uninstall_firewall() {
    clear
    echo -e "${RED}⚠️ 警告：该操作将彻底卸载防火墙并放行所有网络流量！${RESET}"
    read -p "确定要彻底卸载吗？(y/n): " confirm
    if ! echo "$confirm" | grep -qE '^[Yy]$'; then return; fi

    for proto in iptables ip6tables; do
        $proto -F INPUT
        $proto -F OUTPUT
        $proto -P INPUT ACCEPT
    done
    
    rm -rf /etc/iptables /etc/local.d/firewall.start
    apk del iptables ip6tables iptables-openrc 2>/dev/null || true
    echo -e "${GREEN}✅ 防火墙已彻底卸载！${RESET}"
    exit 0
}

view_visual_rules() {
    clear
    local ports_tcp ports_udp ping_status_v4 ping_status_v6 policy_v4
    if iptables -L INPUT -n 2>/dev/null | head -n 1 | grep -q "policy DROP"; then policy_v4="DROP"; else policy_v4="ACCEPT"; fi
    ports_tcp=$( (iptables -S INPUT 2>/dev/null; ip6tables -S INPUT 2>/dev/null) | grep " -j ACCEPT" | grep "dport " | grep -E "tcp" | awk '{for(i=1;i<=NF;i++) if($i=="--dport") print $(i+1)}' | sort -nu | tr '\n' ' ')
    ports_udp=$( (iptables -S INPUT 2>/dev/null; ip6tables -S INPUT 2>/dev/null) | grep " -j ACCEPT" | grep "dport " | grep -E "udp" | awk '{for(i=1;i<=NF;i++) if($i=="--dport") print $(i+1)}' | sort -nu | tr '\n' ' ')
    [ -z "$ports_tcp" ] && ports_tcp="无"
    [ -z "$ports_udp" ] && ports_udp="无"
    if iptables -S INPUT 2>/dev/null | grep "icmp" | grep -q "DROP"; then ping_status_v4="${RED}禁打(DROP)${RESET}"; else ping_status_v4="${GREEN}允许(ACCEPT)${RESET}"; fi

    echo -e "${CYAN}==================================================${RESET}"
    echo -e " 🛡️  默认入站策略 : $policy_v4"
    echo -e " 🌐 Ping 回应状态 : $ping_status_v4"
    echo -e " 🔓 开放的TCP端口 : ${GREEN}$ports_tcp${RESET}"
    echo -e " 🔓 开放的UDP端口 : ${GREEN}$ports_udp${RESET}"
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
                read -p "请输入端口: " PORT
                if ! echo "$PORT" | grep -qE '^[0-9]+$'; then continue; fi
                for proto in iptables ip6tables; do
                    while $proto -C INPUT -p tcp --dport "$PORT" -j DROP >/dev/null 2>&1; do $proto -D INPUT -p tcp --dport "$PORT" -j DROP; done
                    if ! $proto -C INPUT -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1; then $proto -I INPUT -p tcp --dport "$PORT" -j ACCEPT; fi
                done
                save_rules; echo -e "${GREEN}✅ 已开放端口 $PORT${RESET}"; read -p "按回车继续..."
                ;;
            2)
                read -p "请输入端口: " PORT
                if [ "$PORT" -eq "$PORT_SHOW" ]; then echo -e "${RED}⚠️ 不能关闭 SSH 端口！${RESET}"; read -p "按回车..."; continue; fi
                for proto in iptables ip6tables; do
                    while $proto -C INPUT -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1; do $proto -D INPUT -p tcp --dport "$PORT" -j ACCEPT; done
                    if ! $proto -C INPUT -p tcp --dport "$PORT" -j DROP >/dev/null 2>&1; then $proto -I INPUT -p tcp --dport "$PORT" -j DROP; fi
                done
                save_rules; echo -e "${GREEN}✅ 已关闭端口 $PORT${RESET}"; read -p "按回车继续..."
                ;;
            3) open_all_ports ;;
            4) restore_default_rules ;;
            5) read -p "IP: " IP; ip_action accept "$IP"; save_rules; read -p "OK..." ;;
            6) read -p "IP: " IP; ip_action drop "$IP"; save_rules; read -p "OK..." ;;
            7) read -p "IP: " IP; ip_action delete "$IP"; save_rules; read -p "OK..." ;;
            8) ping_action allow; save_rules; echo -e "${GREEN}✅ 已允许 PING${RESET}"; read -p "按回车..." ;;
            9) ping_action deny; save_rules; echo -e "${GREEN}✅ 已禁用 PING${RESET}"; read -p "按回车..." ;;
            10) view_visual_rules ;;
            11) save_and_enable_autoload ;;
            12) uninstall_firewall ;;
            0) clear; break ;;
            *) sleep 1 ;;
        esac
    done
}

# ===============================
# 入口
# ===============================
if [ "$(id -u)" -ne 0 ]; then
   echo "错误: 请使用 root 权限运行！"
   exit 1
fi

# 核心 Bug 修复处：显式处理函数的布尔真假
if check_installed; then
    menu
else
    install_firewall
    menu
fi
