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
BLUE="\033[34m"
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
    local current_os=$(get_os_type)
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
        if [ -z "$v6_addr" ]; then
            V6_STATUS="${YELLOW}已开启(无公网IP)${RESET}"
        else
            if [ "$current_os" = "alpine" ]; then
                V6_STATUS="${GREEN}已启用 (${RED}Alpine强制v6优先${GREEN})${RESET}"
            elif [ -f /etc/gai.conf ] && grep -q "^[[:space:]]*precedence[[:space:]]\+::ffff:0:0/96[[:space:]]\+100" /etc/gai.conf; then
                V6_STATUS="${GREEN}已启用 (${YELLOW}IPv4优先${GREEN})${RESET}"
            else
                V6_STATUS="${GREEN}已启用 (${YELLOW}默认IPv6优先${GREEN})${RESET}"
            fi
        fi
    fi
}

# 🛠️ 方案 B 核心：接管 cloud-init 并重写 Netplan
fix_ubuntu_netplan_cloudinit() {
    local iface="$1"
    local action="$2"
    
    local plan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
    
    if [ "$action" = "disable" ]; then
        # 1. 产生 cloud-init 屏蔽文件，使其不再重置网络
        if [ -d /etc/cloud/cloud.cfg.d ]; then
            echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
        fi
        
        # 2. 修改现有的 Netplan 文件
        if [ -n "$plan_file" ] && [ -f "$plan_file" ]; then
            # 备份原配置以防万一
            [ ! -f "${plan_file}.bak" ] && cp "$plan_file" "${plan_file}.bak"
            
            # 精准替换 dhcp6 状态
            sed -i "s/dhcp6:[[:space:]]*true/dhcp6: false/g" "$plan_file"
            
            # 如果配置中原本没有 accept-ra，在 dhcp6 下方强行追加入网策略控制
            if ! grep -q "accept-ra:" "$plan_file"; then
                sed -i "/dhcp6: false/a \            accept-ra: false" "$plan_file"
            fi
        fi
    else
        # 1. 解除 cloud-init 锁定
        rm -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
        
        # 2. 还原 Netplan
        if [ -f "${plan_file}.bak" ]; then
            mv "${plan_file}.bak" "$plan_file"
        else
            if [ -n "$plan_file" ] && [ -f "$plan_file" ]; then
                sed -i "s/dhcp6:[[:space:]]*false/dhcp6: true/g" "$plan_file"
                sed -i "/accept-ra: false/d" "$plan_file"
            fi
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
    echo -e "${GREEN}  1) 禁用 IPv6${RESET}"
    echo -e "${GREEN}  2) 开启 IPv6${RESET}"
    echo -e "${GREEN}  3) 设置 IPv4 优先(推荐:保留双栈但v4快)${RESET}"
    echo -e "${GREEN}  4) 恢复 IPv6 优先${RESET}"
    echo -e "${GREEN}  5) 查看网卡IP与连通性${RESET}"
    echo -e "${GREEN}  0) 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    
    echo -ne "${GREEN} 请选择操作编号: ${RESET}"
    read choice

    case "$choice" in
        1)
            sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.${iface}.disable_ipv6=1 >/dev/null 2>&1
            
            echo -e "${YELLOW}------ 💾 持久化配置选项 ------${RESET}"
            echo -e "${GREEN}  1) 临时禁用（重启服务器后恢复IPv6）${RESET}"
            echo -e "${GREEN}  2) 永久禁用 (完美适配 Debian/Ubuntu/Alpine)${RESET}"
            echo -ne "${YELLOW} 请选择禁用模式 [默认 1]: ${RESET}"
            read perm_choice
            
            if [ "$perm_choice" = "2" ]; then
                # 1. 基础内核参数写入 (优先采用标准 sysctl.d 目录，防止被冲)
                mkdir -p /etc/sysctl.d
                sysctl_file="/etc/sysctl.d/99-disable-ipv6.conf"
                
                rm -f /etc/sysctl.d/99-disable-ipv6.conf 2>/dev/null
                echo "net.ipv6.conf.all.disable_ipv6 = 1" >> "$sysctl_file"
                echo "net.ipv6.conf.default.disable_ipv6 = 1" >> "$sysctl_file"
                echo "net.ipv6.conf.${iface}.disable_ipv6 = 1" >> "$sysctl_file"
                
                # 同时写入传统文件防老系统漏看
                if [ "$os_type" != "alpine" ]; then
                    sed -i '/net.ipv6.conf./d' /etc/sysctl.conf 2>/dev/null
                    echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
                    echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
                    echo "net.ipv6.conf.${iface}.disable_ipv6 = 1" >> /etc/sysctl.conf
                fi

                # 2. 【Debian 专属神级补丁】：通过网卡后置钩子彻底锁死
                if [ "$os_type" = "debian" ]; then
                    echo -e "${YELLOW}⏳ 检测到 Debian 系统，正在写入 if-up 强制锁死钩子...${RESET}"
                    mkdir -p /etc/network/if-up.d
                    cat << 'EOF' > /etc/network/if-up.d/00-disable-ipv6
#!/bin/sh
# 强行在网卡启动后再次摁倒 IPv6，防止 ifupdown 抢跑
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
if [ -n "$IFACE" ]; then
    sysctl -w net.ipv6.conf.$IFACE.disable_ipv6=1 >/dev/null 2>&1
fi
EOF
                    chmod +x /etc/network/if-up.d/00-disable-ipv6
                fi
                
                # 3. 【Ubuntu 专属补丁】
                if [ "$os_type" = "ubuntu" ]; then
                    echo -e "${YELLOW}⏳ 检测到 Ubuntu 系统，正在锁定 cloud-init 并重构 Netplan...${RESET}"
                    fix_ubuntu_netplan_cloudinit "$iface" "disable"
                    if has_cmd netplan; then netplan apply >/dev/null 2>&1; fi
                    sysctl -w net.ipv6.conf.${iface}.disable_ipv6=1 >/dev/null 2>&1
                fi
                
                echo -e "\n${GREEN}✅ 已成功【永久锁定】禁用 IPv6，当前系统已打上防反弹补丁！${RESET}"
            else
                if [ -f /etc/sysctl.conf ]; then sed -i '/net.ipv6.conf./d' /etc/sysctl.conf; fi
                if [ -f /etc/sysctl.d/99-disable-ipv6.conf ]; then rm -f /etc/sysctl.d/99-disable-ipv6.conf; fi
                echo -e "\n${GREEN}✅ 已成功【临时禁用】IPv6（重启将恢复）。${RESET}"
            fi
            read -rp "按回车键返回菜单..."
            ;;
        2)
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.${iface}.disable_ipv6=0 >/dev/null 2>&1
            
            [ -f /etc/sysctl.conf ] && sed -i '/net.ipv6.conf./d' /etc/sysctl.conf
            [ -f /etc/sysctl.d/99-disable-ipv6.conf ] && rm -f /etc/sysctl.d/99-disable-ipv6.conf
            
            # 清除 Debian 专属补丁
            if [ "$os_type" = "debian" ]; then
                rm -f /etc/network/if-up.d/00-disable-ipv6 2>/dev/null
            fi
            
            if [ "$os_type" = "ubuntu" ]; then
                echo -e "${YELLOW}⏳ 检测到 Ubuntu 系统，正在恢复 cloud-init 网络托管...${RESET}"
                fix_ubuntu_netplan_cloudinit "$iface" "enable"
                if has_cmd netplan; then netplan apply >/dev/null 2>&1; fi
                sleep 1
                echo -e "${GREEN}✅ 网络控制权已归还云厂商系统，IPv6 模块已平滑激活。${RESET}"
                read -rp "按回车键返回菜单..."
            else
                echo -e "${GREEN}✅ 内核 IPv6 模块已激活。${RESET}"
                echo -e "${YELLOW}当前系统为 [${os_type}]，通常需要重启系统才能正确获取公网 IPv6 地址。${RESET}"
                read -rp "按回车键 [立即重启] 系统，或按 Ctrl+C 取消..."
                reboot
            fi
            ;;
        3)
            if [ "$os_type" = "alpine" ]; then
                echo -e "${RED}❌ 抱歉！Alpine Linux 不支持 /etc/gai.conf 优先级策略。${RESET}"
                echo -e "${YELLOW}💡 解决方案：请在主菜单选择【 1) 彻底禁用 IPv6 】来强制系统走 IPv4 通道。${RESET}"
            else
                echo -e "${YELLOW}⏳ 正在设置系统网络规则：IPv4 优先...${RESET}"
                [ ! -f /etc/gai.conf ] && touch /etc/gai.conf
                sed -i '/precedence ::ffff:0:0\/96/d' /etc/gai.conf
                echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
                echo -e "${GREEN}✅ 设置成功！当前系统已调整为：【IPv4 优先】。${RESET}"
                echo -e "${YELLOW}无需重启，已实时生效。${RESET}"
            fi
            read -rp "按回车键返回菜单..."
            ;;
        4)
            if [ "$os_type" = "alpine" ]; then
                echo -e "${BLUE}ℹ️  Alpine 默认即为强制 IPv6 优先，无需配置。${RESET}"
            else
                echo -e "${YELLOW}⏳ 正在恢复系统默认规则：IPv6 优先...${RESET}"
                [ -f /etc/gai.conf ] && sed -i '/^[[:space:]]*precedence[[:space:]]\+::ffff:0:0\/96[[:space:]]\+100/d' /etc/gai.conf
                echo -e "${GREEN}✅ 恢复成功！当前系统已调整回：【默认 IPv6 优先】。${RESET}"
                echo -e "${YELLOW}无需重启，已实时生效。${RESET}"
            fi
            read -rp "按回车键返回菜单..."
            ;;
        5)
            echo -e "${GREEN}🌐 [1/3] 内核 IPv6 状态：${RESET}"
            is_all_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
            is_iface_disabled=$(sysctl -n net.ipv6.conf.${iface}.disable_ipv6 2>/dev/null)
            
            if [ "$is_all_disabled" = "1" ] && [ "$is_iface_disabled" = "1" ]; then
                echo -e "${RED}❌ 内核与活跃网卡已完全禁用 IPv6${RESET}"
            elif [ "$is_all_disabled" = "1" ] && [ "$is_iface_disabled" = "0" ]; then
                echo -e "${YELLOW}⚠️  警告：内核全局已禁，但活跃网卡 [${iface}] 被强行拉起！${RESET}"
            else
                echo -ne "${GREEN}✅ 内核及网卡已正常启用 IPv6 ${RESET}"
                if [ "$os_type" = "alpine" ]; then
                    echo -e "${RED}(Alpine固件：强锁IPv6优先)${RESET}"
                elif [ -f /etc/gai.conf ] && grep -q "^[[:space:]]*precedence[[:space:]]\+::ffff:0:0/96[[:space:]]\+100" /etc/gai.conf; then
                    echo -e "${YELLOW}(策略锁定：IPv4优先)${RESET}"
                else
                    echo -e "${YELLOW}(策略锁定：IPv6优先)${RESET}"
                fi
            fi

            echo -e "\n${GREEN}📌 [2/3] 本地网卡 IP 地址分配情况：${RESET}"
            echo -ne "${YELLOW}  IPv4 地址: ${RESET}"
            ip -4 addr show dev "$iface" 2>/dev/null | grep "inet" | awk '{print $2}' || echo "${RED}未检测到 IPv4${RESET}"
            echo -ne "${YELLOW}  IPv6 地址: ${RESET}"
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
