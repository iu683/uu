#!/bin/bash
# IPv4 / IPv6 切换脚本 (循环版，跨系统，自动安装依赖 + 自动刷新IPv6 + 自动网卡检测 + 按回车返回菜单)

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 检查命令是否存在
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# 自动安装函数
install_pkg() {
    local pkg="$1"
    if has_cmd "$pkg"; then
        return 0
    fi
    echo -e "${YELLOW}🔧 安装依赖: $pkg${RESET}"
    if has_cmd apt; then
        apt update -y && apt install -y "$pkg"
    elif has_cmd apk; then
        apk add --no-cache "$pkg"
    elif has_cmd yum; then
        yum install -y "$pkg"
    elif has_cmd dnf; then
        dnf install -y "$pkg"
    else
        echo -e "${RED}❌ 未找到可用的包管理器，无法安装 $pkg${RESET}"
    fi
}

# 自动检测主网卡名称
detect_iface() {
    iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1)
    echo "$iface"
}

# 检查依赖
install_pkg curl
install_pkg iproute2 || install_pkg iproute
install_pkg iputils-ping || install_pkg inetutils-ping || install_pkg iputils
install_pkg isc-dhcp-client || install_pkg dhclient

# 主循环
while true; do
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1) IPv4 优先 (禁用 IPv6)${RESET}"
    echo -e "${GREEN} 2) IPv6 优先 (启用 IPv6 并刷新网络)${RESET}"
    echo -e "${GREEN} 3) 查看 IPv6 状态 & 公网IP${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    read -p "请输入选择: " choice

    iface=$(detect_iface)

    case $choice in
        1)
            if has_cmd sysctl; then
                sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
                sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
                echo -e "${GREEN}✅ 已切换为 IPv4 优先（禁用 IPv6）${RESET}"
            else
                echo -e "${RED}⚠️ 系统不支持 sysctl，无法切换${RESET}"
            fi
            read -p "按回车返回菜单..."
            ;;
        2)
            if has_cmd sysctl; then
                sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
                sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
                echo -e "${GREEN}✅ 已切换为 IPv6 优先（启用 IPv6）${RESET}"

                echo -e "${YELLOW}🔄 正在刷新 IPv6 地址 (${iface})...${RESET}"
                if has_cmd dhclient; then
                    dhclient -6 -r "$iface" 2>/dev/null
                    dhclient -6 "$iface" 2>/dev/null && echo -e "${GREEN}✔ 已通过 dhclient 刷新 IPv6${RESET}"
                elif has_cmd systemctl; then
                    systemctl restart networking 2>/dev/null && echo -e "${GREEN}✔ 已重启 networking 服务${RESET}"
                elif has_cmd rc-service; then
                    rc-service networking restart 2>/dev/null && echo -e "${GREEN}✔ 已重启 networking 服务${RESET}"
                else
                    echo -e "${RED}⚠️ 未找到合适的网络刷新方式，请手动执行 ifdown/ifup ${iface}${RESET}"
                fi
            else
                echo -e "${RED}⚠️ 系统不支持 sysctl，无法切换${RESET}"
            fi
            read -p "按回车返回菜单..."
            ;;
        3)
            echo -e "${GREEN}🌐 当前 IPv6 状态：${RESET}"
            if has_cmd sysctl; then
                sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null || true
                sysctl net.ipv6.conf.default.disable_ipv6 2>/dev/null || true
            fi

            ip -6 addr | grep "inet6 " || echo "未检测到 IPv6 地址"

            echo
            echo -e "${GREEN}🔎 测试 IPv6 连通性...${RESET}"
            if has_cmd ping6; then
                ping6 -c 3 ipv6.google.com >/dev/null 2>&1 && echo -e "${GREEN}✅ IPv6 网络连通正常${RESET}" || echo -e "${RED}❌ IPv6 无法访问公网${RESET}"
            elif has_cmd ping; then
                ping -6 -c 3 ipv6.google.com >/dev/null 2>&1 && echo -e "${GREEN}✅ IPv6 网络连通正常${RESET}" || echo -e "${RED}❌ IPv6 无法访问公网${RESET}"
            else
                echo -e "${RED}⚠️ 系统没有 ping/ping6 命令${RESET}"
            fi

            echo
            echo -e "${GREEN}🌍 公网 IP 信息：${RESET}"
            if has_cmd curl; then
                echo -n "IPv4: "
                curl -4 -s ifconfig.co || echo "获取失败"
                echo
                echo -n "IPv6: "
                curl -6 -s ifconfig.co || echo "获取失败"
                echo
            else
                echo -e "${RED}⚠️ 未安装 curl，无法获取公网 IP${RESET}"
            fi
            read -p "按回车返回菜单..."
            ;;
        0)
            echo -e "${GREEN}👋 已退出${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ 无效选项，请重新输入${RESET}"
            read -p "按回车返回菜单..."
            ;;
    esac
done
