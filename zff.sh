#!/bin/bash
# IPv4 / IPv6 切换脚本 (循环版，跨系统，自动安装依赖)

# 颜色
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
    echo -e "${YELLOW}🔧 检查依赖: $pkg${RESET}"

    if has_cmd "$pkg"; then
        echo -e "${GREEN}✔ 已安装 $pkg${RESET}"
        return 0
    fi

    echo -e "${RED}✘ 未找到 $pkg，正在安装...${RESET}"

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

# 先检查并安装常用依赖
install_pkg curl
install_pkg iproute2 || install_pkg iproute   # 有的系统包名不同
install_pkg iputils-ping || install_pkg inetutils-ping || install_pkg iputils

while true; do
    echo "=============================="
    echo " 1) IPv4 优先 (禁用 IPv6)"
    echo " 2) IPv6 优先 (启用 IPv6)"
    echo " 3) 查看 IPv6 状态 & 公网IP"
    echo " 0) 退出"
    echo "=============================="
    read -p "请输入选择: " choice

    case $choice in
        1)
            if has_cmd sysctl; then
                sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
                sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null 2>&1
                echo -e "${GREEN}✅ 已切换为 IPv4 优先（禁用 IPv6）${RESET}"
            else
                echo -e "${RED}⚠️ 系统不支持 sysctl，无法切换${RESET}"
            fi
            ;;
        2)
            if has_cmd sysctl; then
                sysctl -w net.ipv6.conf.all.disable_ipv6=0 > /dev/null 2>&1
                sysctl -w net.ipv6.conf.default.disable_ipv6=0 > /dev/null 2>&1
                echo -e "${GREEN}✅ 已切换为 IPv6 优先（启用 IPv6）${RESET}"
            else
                echo -e "${RED}⚠️ 系统不支持 sysctl，无法切换${RESET}"
            fi
            ;;
        3)
            echo "🌐 当前 IPv6 状态："
            if has_cmd sysctl; then
                sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null || true
                sysctl net.ipv6.conf.default.disable_ipv6 2>/dev/null || true
            fi

            ip -6 addr | grep "inet6 " || echo "未检测到 IPv6 地址"

            echo
            echo "🔎 测试 IPv6 连通性..."
            if has_cmd ping6; then
                ping6 -c 3 ipv6.google.com >/dev/null 2>&1 && echo -e "${GREEN}✅ IPv6 网络连通正常${RESET}" || echo -e "${RED}❌ IPv6 无法访问公网${RESET}"
            elif has_cmd ping; then
                ping -6 -c 3 ipv6.google.com >/dev/null 2>&1 && echo -e "${GREEN}✅ IPv6 网络连通正常${RESET}" || echo -e "${RED}❌ IPv6 无法访问公网${RESET}"
            else
                echo -e "${RED}⚠️ 系统没有 ping/ping6 命令${RESET}"
            fi

            echo
            echo "🌍 公网 IP 信息："
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
            ;;
        0)
            echo "👋 已退出"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ 无效选项，请重新输入${RESET}"
            ;;
    esac
    echo
done
