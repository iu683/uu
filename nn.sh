#!/bin/bash
# =========================================================================
# IPv4 / IPv6 智能管理面板（多系统依赖自动检测安装 + Alpine/Debian 深度优化）
# =========================================================================

# 严格的 Root 权限检查
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31m❌ 错误：请使用 root 权限（或通过 sudo）运行此脚本！\033[0m"
    exit 1
fi

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 检查命令是否存在
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# 获取系统内核/发行版 ID
get_os_type() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

# 智能安装依赖
install_pkg() {
    local pkg="$1"
    local os=$(get_os_type)

    if has_cmd "$pkg"; then
        return
    fi

    # 针对 Alpine 的特殊包名转换与跳过逻辑
    if [ "$os" = "alpine" ]; then
        case "$pkg" in
            sysctl) return 0 ;; # Alpine 自带 sysctl 工具，无需安装
            ping6|ping) pkg="iputils" ;; # Alpine 的 ping6 在 iputils 包中
        esac
    fi

    echo -e "${YELLOW}🔧 正在为您补全系统依赖: $pkg ...${RESET}"

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

# 检查常用核心依赖
check_deps() {
    local deps=(curl ip ping sysctl awk grep)
    for cmd in "${deps[@]}"; do
        install_pkg "$cmd"
    done
}

# 自动检测主网卡名称
detect_iface() {
    # 排除本地环回(lo)和虚拟网卡，精准锁定物理/虚拟主网卡
    ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|docker|veth|br-' | head -n1
}

# 动态刷新 IPv6 地址（免重启）
refresh_ipv6() {
    local iface="$1"
    local os=$(get_os_type)
    echo -e "${YELLOW}🔄 正在为您动态刷新网卡 [${iface}] 的 IPv6 地址...${RESET}"

    case "$os" in
        alpine)
            if has_cmd rc-service && [ -f /etc/init.d/networking ]; then
                rc-service networking restart >/dev/null 2>&1
                echo -e "${GREEN}✔ Alpine 网络服务已重启${RESET}"
            else
                ip link set "$iface" down && ip link set "$iface" up
                echo -e "${GREEN}✔ 网卡已硬重启${RESET}"
            fi
            ;;
        ubuntu|debian)
            # 通过强制网卡重新进行无状态地址自动配置(SLAAC)或DHCPv6来刷新，无需重启VPS
            ip link set "$iface" down && ip link set "$iface" up
            if has_cmd systemctl; then
                systemctl restart systemd-networkd >/dev/null 2>&1
                systemctl restart Networking >/dev/null 2>&1
            fi
            echo -e "${GREEN}✔ Debian/Ubuntu 网卡队列已重置并刷新完成${RESET}"
            ;;
        *)
            ip link set "$iface" down && ip link set "$iface" up
            echo -e "${GREEN}✔ 网卡已重启刷新${RESET}"
            ;;
    esac
}

# 执行依赖检查
check_deps

# 主循环
while true; do
    clear
    iface=$(detect_iface)
    [ -z "$iface" ] && iface="未检测到网卡"

    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}       ◈  IPv4 / IPv6 管理面板  ◈      ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 活跃主网卡 : ${YELLOW}${iface}${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  1) 彻底禁用 IPv6（仅保留 IPv4）${RESET}"
    echo -e "${GREEN}  2) 开启并启用 IPv6（自动刷新网络）${RESET}"
    echo -e "${GREEN}  3) 深度查看 IP 状态 & 公网连通性测试${RESET}"
    echo -e "${GREEN}  0) 退出脚本${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    
    echo -ne "${GREEN} 请选择操作编号: ${RESET}"
    read choice

    case "$choice" in
        1)
            sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.${iface}.disable_ipv6=1 >/dev/null 2>&1
            echo -e "\n${GREEN}✅ 已成功在内核中关闭 IPv6 模块。${RESET}"
            echo -e "${YELLOW}💡 提示：如需永久生效，请将 'net.ipv6.conf.all.disable_ipv6=1' 写入 /etc/sysctl.conf${RESET}"
            read -rp "按回车键返回菜单..."
            ;;
        2)
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.${iface}.disable_ipv6=0 >/dev/null 2>&1
            echo -e "\n${GREEN}✅ 内核 IPv6 模块已激活。${RESET}"
            refresh_ipv6 "$iface"
            read -rp "按回车键返回菜单..."
            ;;
        3)
            echo -e "\n${GREEN}🌐 [1/3] 内核 IPv6 状态：${RESET}"
            is_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
            if [ "$is_disabled" = "1" ]; then
                echo -e "${RED}❌ 内核已禁用 IPv6${RESET}"
            else
                echo -e "${GREEN}✅ 内核已启用 IPv6${RESET}"
            fi

            echo -e "\n${GREEN}📌 [2/3] 本地网卡 IPv6 地址分配情况：${RESET}"
            if ip -6 addr show dev "$iface" >/dev/null 2>&1; then
                ip -6 addr show dev "$iface" | grep "inet6" || echo "⚠️ 该网卡暂未获取到任何 IPv6 地址"
            else
                ip -6 addr | grep "inet6" || echo "❌ 未检测到任何 IPv6 地址"
            fi

            echo -e "\n${GREEN}🔎 [3/3] 公网连通性及双栈公网 IP 测试：${RESET}"
            
            # IPv4 测试
            if has_cmd ping; then
                ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 && echo -e "${GREEN}✅ IPv4 路由连通正常${RESET}" || echo -e "${RED}❌ IPv4 路由无法访问公网${RESET}"
            fi
            if has_cmd curl; then
                echo -n "   └─ 本机公网 IPv4: "
                curl -4 -s --connect-timeout 4 ifconfig.co || echo -e "${YELLOW}获取超时（可能无公网IPv4）${RESET}"
            fi

            # IPv6 测试
            local has_v6=false
            if has_cmd ping6; then
                ping6 -c 2 -W 3 ipv6.google.com >/dev/null 2>&1 && has_v6=true
            elif has_cmd ping; then
                ping -6 -c 2 -W 3 ipv6.google.com >/dev/null 2>&1 && has_v6=true
            fi

            if [ "$has_v6" = true ]; then
                echo -e "${GREEN}✅ IPv6 路由连通正常${RESET}"
                if has_cmd curl; then
                    echo -n "   └─ 本机公网 IPv6: "
                    curl -6 -s --connect-timeout 4 ifconfig.co || echo -e "${YELLOW}获取超时${RESET}"
                fi
            else
                echo -e "${RED}❌ IPv6 无法访问外部网络${RESET}"
            fi

            echo
            read -rp "按回车键返回菜单..."
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}❌ 输入错误，无此选项${RESET}"
            sleep 1
            ;;
    esac
done
