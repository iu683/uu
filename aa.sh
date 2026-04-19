#!/bin/bash
# IPv4 / IPv6 切换脚本（完美适配 Alpine/Debian/Ubuntu/CentOS）

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 检查命令是否存在
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# 获取系统类型
get_os_type() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "linux"
    fi
}

# 安装依赖（自动识别 sudo/apk/apt）
install_pkg() {
    local pkg="$1"
    local os=$(get_os_type)
    
    # 针对 Alpine 的包名转换
    [[ "$os" == "alpine" && "$pkg" == "lsb-release" ]] && pkg="catatonit" # 示例转换

    if has_cmd "$pkg"; then return; fi

    echo -e "${YELLOW}🔧 安装依赖: $pkg${RESET}"
    
    # 自动判断是否使用 sudo
    local cmd="sudo"
    if [ "$(id -u)" -eq 0 ]; then cmd=""; fi

    case "$os" in
        ubuntu|debian) $cmd apt update && $cmd apt install -y "$pkg" ;;
        alpine) $cmd apk add --no-cache "$pkg" ;;
        centos|rhel|fedora) $cmd yum install -y "$pkg" || $cmd dnf install -y "$pkg" ;;
    esac
}

# 检查常用依赖
check_deps() {
    local deps=(curl ip ping sysctl)
    for cmd in "${deps[@]}"; do
        install_pkg "$cmd"
    done
    # Alpine 特供：确保有基础网络工具
    if [ "$(get_os_type)" == "alpine" ]; then
        install_pkg "busybox-extras"
    fi
}

# 自动检测主网卡
detect_iface() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1
}

# 刷新 IPv6 (Alpine 深度适配)
refresh_ipv6() {
    local iface="$1"
    local os=$(get_os_type)
    echo -e "${YELLOW}🔄 刷新 IPv6 地址 (${iface})...${RESET}"

    if [[ "$os" == "alpine" ]]; then
        # Alpine 尝试重新触发 DHCPv6
        if has_cmd udhcpc; then
            # Alpine 默认使用 udhcpc
            killall udhcpc 2>/dev/null || true
            udhcpc -i "$iface" -n -q 2>/dev/null
        fi
        rc-service networking restart 2>/dev/null || /etc/init.d/networking restart 2>/dev/null
        echo -e "${GREEN}✔ Alpine 网络已重载${RESET}"
    else
        echo -e "${YELLOW}ℹ️ 系统已尝试启用，如无 IP 请重启 VPS${RESET}"
    fi
}

# 执行初始化检查
check_deps

# 主循环
while true; do
    clear
    echo -e "${GREEN}======== IPv4/IPv6 管理 ========${RESET}"
    echo -e "${GREEN} 1) IPv4 优先 (禁用 IPv6)${RESET}"
    echo -e "${GREEN} 2) IPv6 优先 (启用并刷新 IPv6)${RESET}"
    echo -e "${GREEN} 3) 查看网络状态与公网 IP${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    read -p "$(echo -e ${GREEN} 请选择:${RESET}) " choice

    iface=$(detect_iface)

    case $choice in
        1)
            sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
            echo -e "${GREEN}✅ 已禁用 IPv6${RESET}"
            read -p "按回车返回菜单..."
            ;;
        2)
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
            echo -e "${GREEN}✅ 已启用 IPv6${RESET}"
            refresh_ipv6 "$iface"
            read -p "按回车返回菜单..."
            ;;
        3)
            echo -e "${GREEN}🌐 IPv6 状态：${RESET}"
            dis_v6=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
            if [ "$dis_v6" == "1" ]; then echo "状态: 已禁用"; else echo "状态: 已启用"; fi
            
            echo -e "${GREEN}🌐 内网 IP 列表：${RESET}"
            ip addr show "$iface" | grep "inet" || echo "无地址"

            echo -e "\n${GREEN}🔎 连通性测试：${RESET}"
            # 通用 ping 测试
            ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 && echo -e "IPv4: ${GREEN}正常${RESET}" || echo -e "IPv4: ${RED}失败${RESET}"
            ping6 -c 2 -W 3 ipv6.google.com >/dev/null 2>&1 && echo -e "IPv6: ${GREEN}正常${RESET}" || echo -e "IPv6: ${RED}失败${RESET}"

            echo -e "\n${GREEN}🌍 公网 IP：${RESET}"
            if has_cmd curl; then
                echo -n "IPv4: "
                curl -4 -s --max-time 5 api64.ipify.org || echo "无法获取"
                echo -n "IPv6: "
                curl -6 -s --max-time 5 api64.ipify.org || echo "无法获取"
            fi
            echo ""
            read -p "按回车返回菜单..."
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 无效选项${RESET}"; sleep 1 ;;
    esac
done
