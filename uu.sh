#!/bin/bash
# =========================================================================
# IPv4 / IPv6 智能管理面板（支持选择性持久化配置 + 多系统自动适配）
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

    if [ "$os" = "alpine" ]; then
        case "$pkg" in
            sysctl) return 0 ;; 
            ping6|ping) pkg="iputils" ;; 
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
    ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|docker|veth|br-' | head -n1
}

# 高可靠性公网 IP 获取函数（多接口轮询，彻底过滤 HTML 代码）
get_public_ip() {
    local mode="$1" # -4 或 -6
    local ip_res=""
    
    # 备用 API 列表，全部选用无 Cloudflare 盾的纯净接口
    local apis=(
        "https://api.ip.sb/ip"
        "https://icanhazip.com"
        "https://v4.ident.me"
    )
    [ "$mode" = "-6" ] && apis=("https://api-ipv6.ip.sb/ip" "https://ipv6.icanhazip.com" "https://v6.ident.me")

    for url in "${apis[@]}"; do
        # 加上伪装的浏览器 User-Agent，超时控制在3秒
        ip_res=$(curl "$mode" -sL -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" --connect-timeout 3 "$url" 2>/dev/null | tr -d '\r\n[:space:]')
        
        # 严格过滤：只有纯粹的 IP 地址（不包含 < 或 html 字样）才算获取成功
        if [ -n "$ip_res" ] && [[ ! "$ip_res" == *"<"* && ! "$ip_res" == *"html"* ]]; then
            echo "$ip_res"
            return 0
        fi
    done
    
    echo "获取超时或无此协议公网IP"
    return 1
}

# 获取并格式化主页的 IP 状态
get_menu_status() {
    local iface="$1"
    
    # 1. 检查 IPv4 本地地址
    local v4_addr=$(ip -4 addr show dev "$iface" 2>/dev/null | grep "inet" | awk '{print $2}' | head -n1)
    if [ -z "$v4_addr" ]; then
        V4_STATUS="${RED}未就绪 (无IP)${RESET}"
    else
        V4_STATUS="${YELLOW}已启用 (${v4_addr})${RESET}"
    fi

    # 2. 检查 IPv6 内核状态与本地地址
    local is_v6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    if [ "$is_v6_disabled" = "1" ]; then
        V6_STATUS="${RED}已禁用${RESET}"
    else
        local v6_addr=$(ip -6 addr show dev "$iface" 2>/dev/null | grep "inet6" | grep -v "fe80" | awk '{print $2}' | head -n1)
        if [ -z "$v6_addr" ]; then
            V6_STATUS="${YELLOW}已开启${RESET}"
        else
            V6_STATUS="${YELLOW}已启用(${v6_addr})${RESET}"
        fi
    fi
}

# 执行依赖检查
check_deps

# 主循环
while true; do
    clear
    iface=$(detect_iface)
    [ -z "$iface" ] && iface="未检测到网卡"
    get_menu_status "$iface"

    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}       ◈  IPv4 / IPv6 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 活跃主网卡 : ${YELLOW}${iface}${RESET}"
    echo -e "${GREEN} IPv4 状态  : ${V4_STATUS}"
    echo -e "${GREEN} IPv6 状态  : ${V6_STATUS}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  1) 禁用 IPv6（可选临时或永久）${RESET}"
    echo -e "${GREEN}  2) 开启 IPv6${RESET}"
    echo -e "${GREEN}  3) 查看IP状态&公网连通性测试${RESET}"
    echo -e "${GREEN}  0) 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    
    echo -ne "${GREEN} 请选择操作编号: ${RESET}"
    read choice

    case "$choice" in
        1)
            # 临时禁用（对内核直接生效）
            sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.${iface}.disable_ipv6=1 >/dev/null 2>&1
            
            # 弹出子菜单询问是否转为永久
            echo -e "${YELLOW}------ 💾 持久化配置选项 ------${RESET}"
            echo -e "${GREEN}  1) 仅临时禁用（默认，重启服务器后恢复 IPv6）${RESET}"
            echo -e "${GREEN}  2) 转为永久禁用（锁入系统文件，重启不失效）${RESET}"
            echo -ne "${YELLOW} 请选择禁用模式 [默认 1]: ${RESET}"
            read perm_choice
            
            if [ "$perm_choice" = "2" ]; then
                # 写入永久配置文件
                if [ -f /etc/sysctl.conf ]; then
                    sed -i '/net.ipv6.conf./d' /etc/sysctl.conf
                    echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
                    echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
                    echo "net.ipv6.conf.${iface}.disable_ipv6 = 1" >> /etc/sysctl.conf
                    sysctl -p >/dev/null 2>&1
                fi
                echo -e "\n${GREEN}✅ 已成功【永久禁用】IPv6，重启不会失效！${RESET}"
            else
                # 默认或选1，清理可能存在的旧永久文件残留，保持纯临时状态
                if [ -f /etc/sysctl.conf ]; then
                    sed -i '/net.ipv6.conf./d' /etc/sysctl.conf
                    sysctl -p >/dev/null 2>&1
                fi
                echo -e "\n${GREEN}✅ 已成功【临时禁用】IPv6（重启服务器后将自动恢复）。${RESET}"
            fi
            read -rp "按回车键返回菜单..."
            ;;
        2)
            # 1. 临时生效
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.${iface}.disable_ipv6=0 >/dev/null 2>&1
            
            # 2. 清理永久禁用的配置文件残留，防止重启后又被禁用
            if [ -f /etc/sysctl.conf ]; then
                sed -i '/net.ipv6.conf./d' /etc/sysctl.conf
                sysctl -p >/dev/null 2>&1
            fi
            
            echo -e "${GREEN}✅ 内核 IPv6 模块已激活。${RESET}"
            echo -e "${YELLOW}系统需重启才能获取公网 IPv6 地址${RESET}"
            read -rp "按回车键立即重启系统，或 Ctrl+C 取消..."
            reboot
            read -rp "按回车键返回菜单..."
            ;;
        3)
            echo -e "${GREEN}🌐 [1/3] 内核 IPv6 状态：${RESET}"
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
                get_public_ip "-4"
                echo
            fi

            # IPv6 测试
            has_v6=false
            if has_cmd ping6; then
                ping6 -c 2 -W 3 ipv6.google.com >/dev/null 2>&1 && has_v6=true
            elif has_cmd ping; then
                ping -6 -c 2 -W 3 ipv6.google.com >/dev/null 2>&1 && has_v6=true
            fi

            if [ "$has_v6" = true ]; then
                echo -e "${GREEN}✅ IPv6 路由连通正常${RESET}"
                if has_cmd curl; then
                    echo -n "   └─ 本机公网 IPv6: "
                    get_public_ip "-6"
                    echo
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
