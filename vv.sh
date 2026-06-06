#!/bin/bash
# =========================================================================
# IPv4 / IPv6 管理面板 
# =========================================================================

if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31m❌ 错误：请使用 root 权限运行此脚本！\033[0m"
    exit 1
fi

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

has_cmd() { command -v "$1" >/dev/null 2>&1; }

get_os_type() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

install_pkg() {
    local pkg="$1"
    local os=$(get_os_type)
    if has_cmd "$pkg"; then return; fi
    
    echo -e "${YELLOW}🔧 正在补全系统依赖: $pkg ...${RESET}"
    case "$os" in
        ubuntu|debian)
            apt-get update -y >/dev/null 2>&1
            apt-get install -y "$pkg" >/dev/null 2>&1
            ;;
        alpine)
            apk add --no-cache "$pkg" >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux)
            yum install -y "$pkg" >/dev/null 2>&1 || dnf install -y "$pkg" >/dev/null 2>&1
            ;;
    esac
}

check_deps() {
    local deps=(curl ip ping sysctl awk grep sed)
    for cmd in "${deps[@]}"; do install_pkg "$cmd"; done
}

detect_iface() {
    ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|docker|veth|br-' | head -n1
}

get_public_ip() {
    local mode="$1"
    local ip_res=""
    local apis=("https://api.ip.sb/ip" "https://icanhazip.com" "https://v4.ident.me")
    [ "$mode" = "-6" ] && apis=("https://api-ipv6.ip.sb/ip" "https://ipv6.icanhazip.com" "https://v6.ident.me")

    for url in "${apis[@]}"; do
        ip_res=$(curl "$mode" -sL -A "Mozilla/5.0" --connect-timeout 3 "$url" 2>/dev/null | tr -d '\r\n[:space:]')
        if [ -n "$ip_res" ] && [[ ! "$ip_res" == *"<"* && ! "$ip_res" == *"html"* ]]; then
            echo "$ip_res"
            return 0
        fi
    done
    echo "未获取到公网IP"
    return 1
}

get_menu_status() {
    local iface="$1"
    local v4_addr=$(ip -4 addr show dev "$iface" 2>/dev/null | grep "inet" | awk '{print $2}' | head -n1)
    V4_STATUS=$( [ -z "$v4_addr" ] && echo -e "${RED}未启用${RESET}" || echo -e "${GREEN}已启用${RESET}" )

    local is_all_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    local is_iface_disabled=$(sysctl -n net.ipv6.conf.${iface}.disable_ipv6 2>/dev/null)
    
    if [ "$is_all_disabled" = "1" ] && [ "$is_iface_disabled" = "1" ]; then
        V6_STATUS="${RED}已禁用${RESET}"
    elif [ "$is_all_disabled" = "1" ] && [ "$is_iface_disabled" = "0" ]; then
        V6_STATUS="${YELLOW}已禁用(网卡冲突/残留)${RESET}"
    else
        local v6_addr=$(ip -6 addr show dev "$iface" 2>/dev/null | grep "inet6" | grep -v "fe80" | awk '{print $2}' | head -n1)
        V6_STATUS=$( [ -z "$v6_addr" ] && echo -e "${YELLOW}已开启(无公网IP)${RESET}" || echo -e "${GREEN}已启用${RESET}" )
    fi
}

# 🛠️ 治本核心：修复 Ubuntu Netplan 配置文件
fix_ubuntu_netplan() {
    local iface="$1"
    local action="$2" # "disable" 或 "enable"
    
    # 寻找主要的 netplan yaml 文件
    local plan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
    [ -z "$plan_file" ] && return
    
    if [ "$action" = "disable" ]; then
        # 治本：关闭 dhcp6，并显式禁用 accept-ra（接受路由通告）
        if grep -q "$iface:" "$plan_file"; then
            # 备份原配置
            cp "$plan_file" "${plan_file}.bak"
            
            # 使用 sed 优雅地在网卡配置下插入或修改 dhcp6 和 accept-ra
            # 寻找网卡所在行，并在其下方安全处理
            sed -i "/$iface:/,/^[[:space:]]*[a-zA-Z0-9_-]\+:/ {
                s/[[:space:]]*dhcp6:.*/      dhcp6: false/
                s/[[:space:]]*accept-ra:.*/      accept-ra: false/
            }" "$plan_file"
            
            # 如果原本没有 dhcp6 行，则手动补齐
            if ! grep -A 5 "$iface:" "$plan_file" | grep -q "dhcp6:"; then
                sed -i "/$iface:/a \            dhcp6: false" "$plan_file"
            fi
        fi
    else
        # 恢复：恢复 dhcp6 允许
        if [ -f "${plan_file}.bak" ]; then
            mv "${plan_file}.bak" "$plan_file"
        else
            sed -i "/$iface:/,/^[[:space:]]*[a-zA-Z0-9_-]\+:/ {
                s/[[:space:]]*dhcp6:.*/      dhcp6: true/
            }" "$plan_file"
        fi
    fi
}

check_deps
os_type=$(get_os_type)

while true; do
    clear
    iface=$(detect_iface)
    [ -z "$iface" ] && iface="未检测到网卡"
    get_menu_status "$iface"

    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}     ◈  IPv4 / IPv6 管理面板  ◈       ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 当前系统  : ${YELLOW}${os_type}${RESET}"
    echo -e "${GREEN} 活跃网卡  : ${YELLOW}${iface}${RESET}"
    echo -e "${GREEN} IPv4 状态 : ${V4_STATUS}"
    echo -e "${GREEN} IPv6 状态 : ${V6_STATUS}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}  1) 禁用 IPv6 ${RESET}"
    echo -e "${GREEN}  2) 开启 IPv6 ${RESET}"
    echo -e "${GREEN}  3) 查看网卡IP${RESET}"
    echo -e "${GREEN}  0) 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    
    echo -ne "${GREEN} 请选择操作编号: ${RESET}"
    read choice

    case "$choice" in
        1)
            # 1. 立即通过内核断开当前和全局的 IPv6
            sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.${iface}.disable_ipv6=1 >/dev/null 2>&1
            
            echo -e "${YELLOW}------ 💾 持久化配置选项 ------${RESET}"
            echo -e "${GREEN}  1) 仅临时禁用（重启服务器后恢复 IPv6）${RESET}"
            echo -e "${GREEN}  2) 永久禁用${RESET}"
            echo -ne "${YELLOW} 请选择禁用模式 [默认 1]: ${RESET}"
            read perm_choice
            
            if [ "$perm_choice" = "2" ]; then
                # 写入 sysctl 配置文件
                if [ -f /etc/sysctl.conf ]; then
                    sed -i '/net.ipv6.conf./d' /etc/sysctl.conf
                    echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
                    echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
                    echo "net.ipv6.conf.${iface}.disable_ipv6 = 1" >> /etc/sysctl.conf
                fi
                
                # 【治本核心】针对 Ubuntu 处理 Netplan
                if [ "$os_type" = "ubuntu" ] && has_cmd netplan; then
                    echo -e "${YELLOW}⏳ 检测到 Ubuntu 系统，正在重构 Netplan 配置文件防反弹...${RESET}"
                    fix_ubuntu_netplan "$iface" "disable"
                    netplan apply >/dev/null 2>&1
                    # 再次强刷内核，防止 netplan apply 期间把网卡弹回 0
                    sysctl -w net.ipv6.conf.${iface}.disable_ipv6=1 >/dev/null 2>&1
                fi
                echo -e "\n${GREEN}✅ 已成功【永久锁定】禁用 IPv6，Netplan 刷新或重启绝不失效！${RESET}"
            else
                if [ -f /etc/sysctl.conf ]; then
                    sed -i '/net.ipv6.conf./d' /etc/sysctl.conf
                fi
                echo -e "\n${GREEN}✅ 已成功【临时禁用】IPv6（重启服务器后将自动恢复）。${RESET}"
            fi
            read -rp "按回车键返回菜单..."
            ;;
        2)
            # 1. 恢复内核参数
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.${iface}.disable_ipv6=0 >/dev/null 2>&1
            
            if [ -f /etc/sysctl.conf ]; then
                sed -i '/net.ipv6.conf./d' /etc/sysctl.conf
            fi
            
            # 2. 联动恢复 Netplan
            if [ "$os_type" = "ubuntu" ]; then
                if has_cmd netplan; then
                    echo -e "${YELLOW}⏳ 检测到 Ubuntu 系统，正在通过 Netplan 恢复网络...${RESET}"
                    fix_ubuntu_netplan "$iface" "enable"
                    netplan apply >/dev/null 2>&1
                    sleep 2
                fi
                echo -e "${GREEN}✅ 内核 IPv6 模块已平滑激活。${RESET}"
                echo -e "${YELLOW}提示：Ubuntu 系统无需重启。如果仍未获取到 IPv6，请尝试断开重连或重启。${RESET}"
                read -rp "按回车键返回菜单..."
            else
                echo -e "${GREEN}✅ 内核 IPv6 模块已激活。${RESET}"
                echo -e "${YELLOW}当前系统为 [${os_type}]，通常需要重启系统才能正确获取公网 IPv6 地址。${RESET}"
                read -rp "按回车键 [立即重启] 系统，或按 Ctrl+C 取消..."
                reboot
            fi
            ;;
        3)
            echo -e "${GREEN}🌐 [1/3] 内核 IPv6 状态：${RESET}"
            is_all_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
            is_iface_disabled=$(sysctl -n net.ipv6.conf.${iface}.disable_ipv6 2>/dev/null)
            
            if [ "$is_all_disabled" = "1" ] && [ "$is_iface_disabled" = "1" ]; then
                echo -e "${RED}❌ 内核与活跃网卡已完全禁用 IPv6${RESET}"
            elif [ "$is_all_disabled" = "1" ] && [ "$is_iface_disabled" = "0" ]; then
                echo -e "${YELLOW}⚠️  警告：内核全局已禁，但活跃网卡 [${iface}] 被 Netplan 强行拉起！${RESET}"
            else
                echo -e "${GREEN}✅ 内核及网卡已正常启用 IPv6${RESET}"
            fi

            echo -e "\n${GREEN}📌 [2/3] 本地网卡 IP 地址分配情况：${RESET}"
            echo -ne "${YELLOW}  IPv4 地址: ${RESET}"
            ip -4 addr show dev "$iface" 2>/dev/null | grep "inet" | awk '{print $2}' || echo "${RED}未检测到 IPv4${RESET}"
            echo -ne "${YELLOW}  IPv6 地址: ${RESET}"
            # 排除由于禁用残留但未释放的 fe80 链路本地地址，让显示更直观
            ip -6 addr show dev "$iface" 2>/dev/null | grep "inet6" | awk '{print $2}' || echo "${RED}未检测到 IPv6${RESET}"

            echo -e "\n${GREEN}🔎 [3/3] 公网双栈连通性及公网 IP 测试：${RESET}"
            if has_cmd ping; then
                ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 && echo -e "${GREEN}✅ IPv4 路由连通正常${RESET}" || echo -e "${RED}❌ IPv4 路由无法访问公网${RESET}"
            fi
            echo -n "    └─ 本机公网 IPv4: "
            get_public_ip "-4"

            has_v6=false
            if has_cmd ping6; then ping6 -c 2 -W 3 240c::6666 >/dev/null 2>&1 && has_v6=true
            elif has_cmd ping; then ping -6 -c 2 -W 3 240c::6666 >/dev/null 2>&1 && has_v6=true; fi

            if [ "$has_v6" = "true" ] && [ "$is_iface_disabled" = "0" ]; then
                echo -e "${GREEN}✅ IPv6 路由连通正常${RESET}"
                echo -n "    └─ 本机公网 IPv6: "
                get_public_ip "-6"
            else
                echo -e "${RED}❌ IPv6 无法访问外部网络 (内核已死锁或网络环境不支持)${RESET}"
            fi
            echo
            read -rp "按回车键返回菜单..."
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 输入错误，无此选项${RESET}"; sleep 1 ;;
    esac
done
