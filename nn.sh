#!/bin/bash
# ========================================================
#  SNIProxy & SmartDNS 公共解锁 DNS管理脚本 (修复版)
# ========================================================

# 参数配置
LISTEN_PORT="443"
FIREWALL_CHAIN_TCP="ALLOW_TCP_443"
FIREWALL_CHAIN_UDP="ALLOW_UDP_53"
BINARY_NAME="sniproxy"
SNI_BASE_DIR="$(pwd)/sniproxy"
ALLOWLIST_FILE="$SNI_BASE_DIR/allowed_client_ips.txt"
VERSION_FILE="$SNI_BASE_DIR/version.txt"
SNI_SERVICE_FILE="/etc/systemd/system/sniproxy.service"

SMARTDNS_CONF_URL="https://raw.githubusercontent.com/pymumu/smartdns/master/etc/smartdns/smartdns.conf"
DOMAIN_LIST_URL="https://raw.githubusercontent.com/1-stream/1stream-public-utils/refs/heads/main/stream.text.list"
OUTPUT_FILE="smartdns.conf"
TEMP_DOMAIN_FILE="/tmp/domain_list.txt"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' 

# ==================== 基础打印与通用工具函数 ====================
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "此操作需要 root 权限。请使用 sudo 或以 root 用户身份运行。"
        exit 1
    fi
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "命令 '$1' 未找到。请先安装它 (例如: apt install -y $1 || yum install -y $1)"
        exit 1
    fi
}

read_user_input() {
    local var_name=$1
    if [ -r /dev/tty ]; then
        { read -r "$var_name" < /dev/tty; } 2>/dev/null && return 0
    fi
    read -r "$var_name"
}

read_required_input() {
    local var_name=$1
    if ! read_user_input "$var_name"; then
        print_error "未读取到输入。请在交互式终端运行脚本。"
        exit 1
    fi
}

validate_ip() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        local -a octets=($ip)
        for octet in "${octets[@]}"; do
            if ((octet > 255)); then return 1; fi
        done
        return 0
    fi
    return 1
}

validate_ip_or_cidr() {
    local value=$1
    local ip="${value%/*}"
    if [[ "$value" == */* ]]; then
        local cidr="${value#*/}"
        if ! [[ "$cidr" =~ ^[0-9]+$ ]] || ((cidr < 0 || cidr > 32)); then return 1; fi
    fi
    validate_ip "$ip"
}

detect_arch() {
    local machine=$(uname -m)
    if [ "$machine" = "x86_64" ]; then echo "amd64"
    elif [ "$machine" = "aarch64" ] || [ "$machine" = "arm64" ]; then echo "arm64"
    else echo "unknown"; fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/redhat-release ]; then echo "centos"
    else echo "unknown"; fi
}

get_public_ip() {
    local pub_ip
    pub_ip=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || echo "你的中转机公网IP")
    echo "$pub_ip"
}

get_remote_sni_version() {
    curl -sS --max-time 1.5 "https://api.github.com/repos/XIU2/SNIProxy/releases/latest" | jq -r '.tag_name' 2>/dev/null || echo "未知"
}

get_remote_smartdns_version() {
    curl -sS --max-time 1.5 "https://api.github.com/repos/pymumu/smartdns/releases/latest" | jq -r '.tag_name' 2>/dev/null || echo "未知"
}

install_dependency() {
    local pkg=$1
    if command -v "$pkg" &> /dev/null; then return 0; fi
    print_info "正在安装依赖 $pkg..."
    local os_type=$(detect_os)
    if [[ "$os_type" == "ubuntu" || "$os_type" == "debian" ]]; then
        apt-get update -qq && apt-get install -y "$pkg"
    elif [[ "$os_type" == "centos" || "$os_type" == "rhel" || "$os_type" == "fedora" ]]; then
        yum install -y "$pkg"
    else
        print_error "未知系统，请手动安装 $pkg 后重试。"
        exit 1
    fi
}

# ==================== 安全策略模块 ====================
persist_firewall_rules() {
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save >/dev/null 2>&1 && print_success "防火墙规则已持久化。"
    elif command -v iptables-save &> /dev/null && [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null && print_success "iptables 规则已保存。"
    else
        print_warning "未检测到 iptables 持久化工具，重启后白名单可能会失效。"
    fi
}

clear_client_allowlist() {
    ensure_root
    print_info "正在清空客户端 IP 白名单，开放公网访问 (53/443)..."
    if command -v iptables &> /dev/null; then
        while iptables -C INPUT -p tcp --dport "$LISTEN_PORT" -j "$FIREWALL_CHAIN_TCP" 2>/dev/null; do
            iptables -D INPUT -p tcp --dport "$LISTEN_PORT" -j "$FIREWALL_CHAIN_TCP"
        done
        iptables -F "$FIREWALL_CHAIN_TCP" 2>/dev/null || true
        iptables -X "$FIREWALL_CHAIN_TCP" 2>/dev/null || true

        while iptables -C INPUT -p udp --dport 53 -j "$FIREWALL_CHAIN_UDP" 2>/dev/null; do
            iptables -D INPUT -p udp --dport 53 -j "$FIREWALL_CHAIN_UDP"
        done
        iptables -F "$FIREWALL_CHAIN_UDP" 2>/dev/null || true
        iptables -X "$FIREWALL_CHAIN_UDP" 2>/dev/null || true
    fi
    rm -f "$ALLOWLIST_FILE"
    persist_firewall_rules
    print_success "安全策略已变更为：允许任意公网落地机连接本 DNS。"
}

apply_client_allowlist() {
    local allowed_ips=("$@")
    check_command "iptables"
    
    print_info "正在应用客户端 IP 安全白名单..."
    iptables -N "$FIREWALL_CHAIN_TCP" 2>/dev/null || true
    iptables -F "$FIREWALL_CHAIN_TCP"
    iptables -N "$FIREWALL_CHAIN_UDP" 2>/dev/null || true
    iptables -F "$FIREWALL_CHAIN_UDP"

    for ip in "${allowed_ips[@]}"; do
        iptables -A "$FIREWALL_CHAIN_TCP" -p tcp --dport "$LISTEN_PORT" -s "$ip" -j ACCEPT
        iptables -A "$FIREWALL_CHAIN_UDP" -p udp --dport 53 -s "$ip" -j ACCEPT
    done
    
    iptables -A "$FIREWALL_CHAIN_TCP" -p tcp --dport "$LISTEN_PORT" -j DROP
    iptables -A "$FIREWALL_CHAIN_UDP" -p udp --dport 53 -j DROP

    if ! iptables -C INPUT -p tcp --dport "$LISTEN_PORT" -j "$FIREWALL_CHAIN_TCP" 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "$LISTEN_PORT" -j "$FIREWALL_CHAIN_TCP"
    fi
    if ! iptables -C INPUT -p udp --dport 53 -j "$FIREWALL_CHAIN_UDP" 2>/dev/null; then
        iptables -I INPUT -p udp --dport 53 -j "$FIREWALL_CHAIN_UDP"
    fi

    mkdir -p "$SNI_BASE_DIR"
    {
        echo "# 授权访问此公共 DNS 与 解锁中转的落地机 IP"
        printf '%s\n' "${allowed_ips[@]}"
    } > "$ALLOWLIST_FILE"

    persist_firewall_rules
    print_success "安全策略已变更为：仅允许授权白名单 IP 接入解析与解锁服务。"
}

manage_client_allowlist() {
    ensure_root
    clear
    local current_allowed=""
    [ -f "$ALLOWLIST_FILE" ] && current_allowed=$(grep -v '^[[:space:]]*#' "$ALLOWLIST_FILE" | sed '/^[[:space:]]*$/d')
    
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}      ◈  落地机(客户端) 访问授权管理  ◈       ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    if [ -n "$current_allowed" ]; then
        echo -e "${GREEN} 当前已授权放行的落地机 IP 列表:${NC}"
        echo "$current_allowed" | sed 's/^/  • /'
    else
        echo -e "${GREEN} 当前安全策略 :${NC} ${YELLOW}公开解锁模式${NC}"
    fi
    echo -e "${GREEN}=============================================${NC}"
    
    echo -e "${GREEN}  1. 设置授权落地机 IP${NC}"
    echo -e "${GREEN}  2. 追加授权落地机 IP${NC}"
    echo -e "${GREEN}  3. 清空限制(公开解锁)${NC}"
    echo -e "${GREEN}  0. 返回主菜单${NC}"
    echo -e "${GREEN}=============================================${NC}"
    
    echo -ne "${GREEN} 请输入选项: ${NC}"
    local choice
    read -r choice
    choice=$(echo "$choice" | xargs 2>/dev/null || echo "")

    case "$choice" in
        1|2)
            echo -e "\n${YELLOW}[提示] 多个落地机 IP 请使用空格或逗号分隔${NC}"
            echo -n -e "${GREEN}请输入落地机 IP: ${NC}"
            local input_ips
            read_required_input input_ips
            input_ips=$(echo "$input_ips" | tr ',' ' ')

            local allowed_ips=()
            if [ "$choice" = "2" ] && [ -n "$current_allowed" ]; then
                while IFS= read -r ip; do [ -n "$ip" ] && allowed_ips+=("$ip"); done <<< "$current_allowed"
            fi

            for ip in $input_ips; do
                ip=$(echo "$ip" | tr -d '\r\n' | sed 's/[[:space:]]//g')
                [ -z "$ip" ] && continue
                if validate_ip_or_cidr "$ip"; then allowed_ips+=("$ip")
                else print_error "无效的 IP 格式: $ip"; return 1; fi
            done
            
            [ "${#allowed_ips[@]}" -eq 0 ] && { print_warning "未输入有效IP。"; return 0; }
            mapfile -t allowed_ips < <(printf '%s\n' "${allowed_ips[@]}" | awk '!seen[$0]++')
            apply_client_allowlist "${allowed_ips[@]}"
            ;;
        3) clear_client_allowlist ;;
        *) return 0 ;;
    esac
}

# ==================== SNIProxy 模块 ====================
install_sniproxy() {
    ensure_root
    local is_update=$1
    
    if [ "$is_update" != "true" ] && systemctl list-unit-files | grep -q "^sniproxy\.service"; then
        print_warning "检测到 SNIProxy 已安装。"
        return 0
    fi
    
    if [ "$is_update" = "true" ]; then
        print_info "正在升级 SNIProxy 核心版本..."
        systemctl stop sniproxy 2>/dev/null || true
    else
        print_info "开始全新安装 SNIProxy..."
    fi
    
    install_dependency "curl"; install_dependency "jq"
    local arch=$(detect_arch)
    if [ "$arch" = "unknown" ]; then print_error "不支持的架构。"; exit 1; fi

    local version=$(curl -sSL "https://api.github.com/repos/XIU2/SNIProxy/releases/latest" | jq -r '.tag_name')
    if [ -z "$version" ] || [ "$version" = "null" ]; then version="v1.0.7"; fi
    
    local tar_name="sniproxy_linux_${arch}.tar.gz"
    local download_url="https://github.com/XIU2/SNIProxy/releases/download/${version}/${tar_name}"
    
    curl -fL "$download_url" -o "/tmp/$tar_name"
    local tmp_extract="/tmp/sniproxy_$$"; mkdir -p "$tmp_extract" "$SNI_BASE_DIR"
    tar -xzf "/tmp/$tar_name" -C "$tmp_extract"
    mv "$(find "$tmp_extract" -type f -name "$BINARY_NAME" | head -n 1)" "$SNI_BASE_DIR/$BINARY_NAME"
    chmod +x "$SNI_BASE_DIR/$BINARY_NAME"
    rm -f "/tmp/$tar_name" && rm -rf "$tmp_extract"

    echo "$version" > "$VERSION_FILE"

    if [ "$is_update" != "true" ]; then
        cat <<EOF > "$SNI_BASE_DIR/config.yaml"
listen_addr: ":$LISTEN_PORT"
allow_all_hosts: true
EOF

        cat <<EOF > "$SNI_SERVICE_FILE"
[Unit]
Description=SNI Proxy
After=network.target

[Service]
ExecStart=$SNI_BASE_DIR/$BINARY_NAME -c $SNI_BASE_DIR/config.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable sniproxy
    fi

    systemctl start sniproxy
    print_success "SNIProxy 核心包 ($version) 部署成功。"
}

# ==================== SmartDNS 模块 ====================
check_and_fix_port_conflict() {
    print_info "检查 53 端口占用情况..."
    local port_usage=""
    if command -v lsof &> /dev/null; then port_usage=$(lsof -i :53 2>/dev/null); fi
    if [ -z "$port_usage" ] && command -v ss &> /dev/null; then port_usage=$(ss -tulnp | grep :53 2>/dev/null); fi
    [ -z "$port_usage" ] && return 0
    
    if echo "$port_usage" | grep -q "systemd-resolve"; then
        print_warning "发现 systemd-resolved 正在占用端口 53，执行清理释放..."
        systemctl stop systemd-resolved && systemctl disable systemd-resolved
        chattr -i /etc/resolv.conf 2>/dev/null || true
        [ -L /etc/resolv.conf ] && rm /etc/resolv.conf
        cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
EOF
        return 0
    else
        echo "$port_usage" | grep -q "smartdns" && return 0
        print_error "端口 53 被其他未知程序占用，请先手动清理:\n$port_usage"
        return 1
    fi
}

install_smartdns_binary() {
    local is_update=$1
    if [ "$is_update" != "true" ] && command -v smartdns &> /dev/null; then return 0; fi
    
    if [ "$is_update" = "true" ]; then
        print_info "正在升级并重新编译 SmartDNS 二进制程序..."
        systemctl stop smartdns 2>/dev/null || true
    else
        print_info "正在获取并编译安装 SmartDNS 核心..."
    fi

    install_dependency "wget"
    local arch=$(detect_arch)
    local asset_arch=$([ "$arch" = "amd64" ] && echo "x86_64" || echo "aarch64")
    local download_url=$(curl -s https://api.github.com/repos/pymumu/smartdns/releases/latest | grep "browser_download_url" | grep "$asset_arch-linux-all.tar.gz" | head -n 1 | cut -d '"' -f 4)
    
    cd /tmp && wget -q --show-progress "${download_url}" -O smartdns.tar.gz
    tar -xzf smartdns.tar.gz && cd smartdns && chmod +x ./install && ./install -i
    cd /tmp && rm -rf smartdns smartdns.tar.gz
    print_success "SmartDNS 核心包编译装载就绪。"
}

configure_smartdns_rules() {
    local is_update=$1
    ensure_root
    if [ "$is_update" != "true" ]; then
        if ! check_and_fix_port_conflict; then exit 1; fi
    fi
    install_smartdns_binary "$is_update"

    print_info "正在构建公网分流规则库..."
    wget -q -O "${OUTPUT_FILE}" "${SMARTDNS_CONF_URL}"
    sed -i '/^server /d' "${OUTPUT_FILE}"
    sed -i '/^bind /d' "${OUTPUT_FILE}"

    cat > "${OUTPUT_FILE}.tmp" << 'EOF'
# ===== 公网公共 DNS 基础属性 =====
server 1.1.1.1
server 8.8.8.8
bind :53
cache-size 32768
prefetch-domain yes
serve-expired yes
EOF
    cat "${OUTPUT_FILE}" >> "${OUTPUT_FILE}.tmp"
    mv "${OUTPUT_FILE}.tmp" "${OUTPUT_FILE}"

    print_info "正在同步全球流媒体解锁域名数据源..."
    curl -s "${DOMAIN_LIST_URL}" -o "${TEMP_DOMAIN_FILE}"
    
    cat >> "${OUTPUT_FILE}" << EOF

# ===== 自动化就地劫持分流核心规则 =====
EOF

    # ==================== 💥 修复核心开始 💥 ====================
    # 使用 gsub(/[[:space:]\r]/, "") 彻底清除所有行内空格及 Windows 换行符，防止首字母被吞
    awk '/^[^#[:space:]]/ {gsub(/[[:space:]\r]/, ""); if($0!="") print "address /" $0 "/127.0.0.1"}' "${TEMP_DOMAIN_FILE}" >> "${OUTPUT_FILE}"
    # ==================== 💥 修复核心结束 💥 ====================

    rm -f "${TEMP_DOMAIN_FILE}"

    mkdir -p /etc/smartdns
    [ -f /etc/smartdns/smartdns.conf ] && cp /etc/smartdns/smartdns.conf /etc/smartdns/smartdns.conf.bak
    cp "${OUTPUT_FILE}" /etc/smartdns/smartdns.conf
    rm -f "${OUTPUT_FILE}"

    systemctl restart smartdns
    sleep 1
    if systemctl is-active --quiet smartdns; then
        print_success "中转端解锁 DNS 构建完成！"
        print_info "当前已接管流媒体分流拦截规则共: $(grep -c "^address " /etc/smartdns/smartdns.conf) 条"
    else
        print_error "SmartDNS 启动异常。"
    fi
}

show_logs() {
    ensure_root
    clear
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}◈  流媒体解锁服务 实时运行日志  ◈${NC}"
    echo -e "${GREEN}=============================================${NC}"
    print_info "正在读取最近 30 行日志（按 Ctrl+C 即可退出查看）:"
    echo -e "${YELLOW}--- SmartDNS 分流日志 ---${NC}"
    journalctl -u smartdns -n 15 --no-pager 2>/dev/null || echo "无日志"
    echo -e "\n${YELLOW}--- SNIProxy 中转日志 ---${NC}"
    journalctl -u sniproxy -n 15 --no-pager 2>/dev/null || echo "无日志"
    echo -e "${GREEN}=============================================${NC}"
}

# ==================== 彻底净化卸载模块 (修复核心) ====================
uninstall_all_services() {
    ensure_root
    print_warning "正在全面卸载并净化本机的中转与分流服务..."
    
    # 1. 停止并禁用 Systemd 服务
    systemctl stop sniproxy smartdns 2>/dev/null || true
    systemctl disable sniproxy smartdns 2>/dev/null || true
    
    # 2. 调用 SmartDNS 官方自带的卸载逻辑（根治卸载不干净、状态残留的罪魁祸首）
    if [ -f /usr/sbin/smartdns ] || [ -f /usr/bin/smartdns ]; then
        print_info "正在调用 SmartDNS 核心卸载脚本..."
        # 尝试重新拉取最新包或寻找本地残留的安装引导来执行卸载
        local arch=$(detect_arch)
        local asset_arch=$([ "$arch" = "amd64" ] && echo "x86_64" || echo "aarch64")
        local download_url=$(curl -s https://api.github.com/repos/pymumu/smartdns/releases/latest | grep "browser_download_url" | grep "$asset_arch-linux-all.tar.gz" | head -n 1 | cut -d '"' -f 4)
        
        if [ -n "$download_url" ]; then
            cd /tmp && wget -q "${download_url}" -O smartdns_un.tar.gz
            tar -xzf smartdns_un.tar.gz && cd smartdns && chmod +x ./install
            ./install -u >/dev/null 2>&1 # 官方卸载命令
            cd /tmp && rm -rf smartdns smartdns_un.tar.gz
        fi
    fi

    # 3. 强力清除所有可能的遗留残余文件
    clear_client_allowlist
    rm -f "$SNI_SERVICE_FILE"
    rm -rf "$SNI_BASE_DIR"
    rm -rf /etc/smartdns
    rm -f /usr/lib/systemd/system/smartdns.service /lib/systemd/system/smartdns.service
    rm -f /usr/sbin/smartdns /usr/bin/smartdns
    
    # 4. 刷新 Systemd 守护进程守护缓存
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true
    
    print_success "系统环境已彻底净化，恢复至初始状态。"
}

# ==================== 主控控制面板 ====================

main() {
    local my_ip
    my_ip=$(get_public_ip)
    
    # -------------------------------------------------------------
    # 【优化项 1】远程版本属于静态数据，移到菜单外，启动脚本时仅获取一次
    # -------------------------------------------------------------
    local remote_sni_ver=$(get_remote_sni_version)
    local remote_sdns_ver=$(get_remote_smartdns_version)

    # 定义需要跨循环持久化的状态变量
    local sni_installed="false"
    local smartdns_installed="false"
    local current_sni_ver="${RED}未装载${NC}"
    local current_sdns_ver="${RED}未装载${NC}"

    # -------------------------------------------------------------
    # 【优化项 2】将耗时的“本地安装检测”和“本地版本解析”封装为独立函数
    # -------------------------------------------------------------
    refresh_local_status() {
        # SNIProxy 安装与版本判定
        sni_installed="false"
        if systemctl list-unit-files | grep -q "^sniproxy\.service"; then
            sni_installed="true"
            if [ -f "$VERSION_FILE" ]; then 
                current_sni_ver=$(cat "$VERSION_FILE")
            else
                current_sni_ver="v1.0.7"
            fi
        else
            current_sni_ver="${RED}未装载${NC}"
        fi

        # SmartDNS 安装与版本判定
        smartdns_installed="false"
        if systemctl list-unit-files | grep -q "^smartdns\.service" || command -v smartdns &> /dev/null; then
            smartdns_installed="true"
            local raw_ver=$(smartdns -v 2>&1 | head -n 1)
            local main_ver=$(echo "$raw_ver" | awk '{print $2}' | cut -d'-' -f1)
            local sub_ver=$(echo "$raw_ver" | grep -o 'Release[^)]*')

            if [ -n "$main_ver" ] && [ -n "$sub_ver" ]; then
                current_sdns_ver="${main_ver} (${sub_ver})"
            elif [ -n "$main_ver" ]; then
                current_sdns_ver="${main_ver}"
            else
                current_sdns_ver="未知版本"
            fi
        else
            current_sdns_ver="${RED}未装载${NC}"
        fi
    }

    # 脚本启动时，先初始化调用一次状态探测
    refresh_local_status

    # -------------------------------------------------------------
    # 【主循环】现在这里面没有任何耗时命令，按下回车瞬时刷新！
    # -------------------------------------------------------------
    while true; do
        clear
        
        # 1. 动态服务运行状态（systemctl is-active 响应速度极快，可保留在内部提供实时状态）
        local sni_status_view="${RED}未安装${NC}"
        if [ "$sni_installed" = "true" ]; then
            if systemctl is-active --quiet sniproxy; then
                sni_status_view="${GREEN}运行中${NC} ${YELLOW}(端口: ${LISTEN_PORT})${NC}"
            else
                sni_status_view="${YELLOW}已停止${NC}"
            fi
        fi

        local smartdns_status_view="${RED}未安装${NC}"
        if [ "$smartdns_installed" = "true" ]; then
            if systemctl is-active --quiet smartdns; then
                smartdns_status_view="${GREEN}运行中${NC} ${YELLOW}(端口: 53)${NC}"
            else
                smartdns_status_view="${YELLOW}已停止${NC}"
            fi
        fi

        # 2. 动态白名单文件体积检查（本地纯文件判断，不卡顿）
        local whitelist_view="${YELLOW}公开解锁(任意设备改DNS即可解锁)${NC}"
        if [ -f "$ALLOWLIST_FILE" ] && [ -s "$ALLOWLIST_FILE" ]; then
            local count=$(grep -v '^[[:space:]]*#' "$ALLOWLIST_FILE" | sed '/^[[:space:]]*$/d' | wc -l)
            whitelist_view="${YELLOW}安全模式(允许已授权的 ${count} 个IP)${NC}"
        fi

        # 3. 渲染主面板
        echo -e "${GREEN}=============================================${NC}"
        echo -e "${GREEN}     ◈  流媒体公共 DNS 解锁中转面板  ◈       ${NC}"
        echo -e "${GREEN}=============================================${NC}"
        echo -e "${GREEN} SNIProxy 状态:${NC} $sni_status_view"
        echo -e "${GREEN} SmartDNS 状态:${NC} $smartdns_status_view"
        echo -e "${GREEN} SNIProxy 版本:${NC} ${YELLOW}${current_sni_ver}${NC}"
        echo -e "${GREEN} SmartDNS 版本:${NC} ${YELLOW}${current_sdns_ver}${NC}"
        echo -e "${GREEN} 安全策略访问 :${NC} $whitelist_view"
        echo -e "${GREEN}=============================================${NC}"
        echo -e "${GREEN}  1. 安装 解锁服务${NC}"
        echo -e "${GREEN}  2. 更新 解锁服务${NC}"
        echo -e "${GREEN}  3. 卸载 解锁服务${NC}"
        echo -e "${GREEN}  4. 白名单规则${NC}"
        echo -e "${GREEN}  5. 启动 解锁服务${NC}"
        echo -e "${GREEN}  6. 停止 解锁服务${NC}"
        echo -e "${GREEN}  7. 重启 解锁服务${NC}"
        echo -e "${GREEN}  8. 查看日志${NC}"
        echo -e "${GREEN}  9. 查看配置${NC}"
        echo -e "${GREEN}  0. 退出 ${NC}"
        echo -e "${GREEN}=============================================${NC}"
        
        echo -ne "${GREEN} 请输入选项: ${NC}"
        local choice
        read -r choice
        choice=$(echo "$choice" | xargs 2>/dev/null || echo "")

        case "$choice" in
            1)
                install_sniproxy "false"
                configure_smartdns_rules "false"
                refresh_local_status # 安装后主动刷新本地状态缓存
                echo -e "\n${GREEN}==================================================${NC}"
                print_success "中转端部署完全就绪！"
                echo -e "现在，你其他的【落地机】不需要装任何东西，直接执行这三行命令即可解锁："
                echo -e "${YELLOW}chattr -i /etc/resolv.conf 2>/dev/null || true${NC}"
                echo -e "${YELLOW}echo \"nameserver ${my_ip}\" > /etc/resolv.conf${NC}"
                echo -e "${YELLOW}chattr +i /etc/resolv.conf 2>/dev/null${NC}"
                echo -e "${GREEN}==================================================${NC}"
                echo -n "按回车键返回面板..."; read -r _ ;;
            2) 
                install_sniproxy "true"
                configure_smartdns_rules "true"
                refresh_local_status # 更新后主动刷新本地状态缓存
                print_success "SNIProxy 和 SmartDNS 核心程序以及分流规则已全部升级成功！"
                echo -n "按回车键返回面板..."; read -r _ ;;
            3) 
                uninstall_all_services
                refresh_local_status # 卸载后主动刷新本地状态缓存
                echo -n "按回车键返回面板..."; read -r _ ;;
            4) 
                manage_client_allowlist
                echo -n "按回车键返回面板..."; read -r _ ;;
            5) systemctl start sniproxy smartdns 2>/dev/null && print_success "服务已完成启动指令。"; sleep 1.5 ;;
            6) systemctl stop sniproxy smartdns 2>/dev/null && print_success "服务已完成停止指令。"; sleep 1.5 ;;
            7) systemctl restart sniproxy smartdns 2>/dev/null && print_success "核心组件已全部重启。"; sleep 1.5 ;;
            8) show_logs; echo -n "按回车键返回面板..."; read -r _ ;;
            9) 
                clear
                echo -e "${GREEN}--- 当前运行配置摘要 ---${NC}"
                echo -e "DNS 监听地址: 0.0.0.0:53  |  SNI 中转端口: 0.0.0.0:${LISTEN_PORT}"
                echo -e "已加载劫持分流域名数量: ${YELLOW}$(grep -c "^address " /etc/smartdns/smartdns.conf 2>/dev/null || echo "0")${NC} 条"
                echo -e "\n${GREEN}--- 本机流媒体原生出口测试 ---${NC}"
                if command -v curl &> /dev/null; then
                    echo -n "Netflix 出口状态: "
                    curl -sI --max-time 3 https://www.netflix.com | head -n 1 || echo "连接超时"
                else
                    print_warning "本地缺少 curl，无法执行出口活性探测。"
                fi
                echo -n "按回车键返回面板..."; read -r _ ;;
            0) exit 0 ;;
            *) print_error "无效选项: '$choice'，请重新输入。"; sleep 1.5 ;;
        esac
    done
}

main "$@"
