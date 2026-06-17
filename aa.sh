#!/bin/bash
# ========================================================
#  SNIProxy & SmartDNS 公共解锁 DNS管理脚本
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

# 【修复 1】删除下方重名的简单 get_public_ip，统一保留这个功能完备的高级版本
get_public_ip() {
    local mode=${1:-"auto"} # 默认走自动双栈判定
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    echo "127.0.0.1" && return 0
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
    
    echo -e "${GREEN}  1. 覆盖设置 授权落地机 IP${NC}"
    echo -e "${GREEN}  2. 追加放行 授权落地机 IP${NC}"
    echo -e "${GREEN}  3. 精准删除 某个授权 IP${NC}"
    echo -e "${GREEN}  4. 清空限制 (变更为公开解锁)${NC}"
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
        3)
            if [ -z "$current_allowed" ]; then
                print_warning "当前处于公开解锁模式，无需删除 IP。"
                sleep 1.5
                return 0
            fi
            echo -n -e "\n${YELLOW}请输入要删除的落地机 IP: ${NC}"
            local remove_ip
            read_required_input remove_ip
            remove_ip=$(echo "$remove_ip" | sed 's/[[:space:]]//g')

            # 匹配并过滤掉要删除的 IP
            local allowed_ips=()
            local found=false
            while IFS= read -r ip; do
                if [ "$ip" = "$remove_ip" ]; then
                    found=true
                elif [ -n "$ip" ]; then
                    allowed_ips+=("$ip")
                fi
            done <<< "$current_allowed"

            if [ "$found" = "false" ]; then
                print_error "白名单中未找到该 IP: $remove_ip"
                sleep 1.5
                return 0
            fi

            # 如果删完之后白名单空了，直接切回公开模式；否则重新应用剩下的白名单
            if [ "${#allowed_ips[@]}" -eq 0 ]; then
                clear_client_allowlist
            else
                apply_client_allowlist "${allowed_ips[@]}"
            fi
            ;;
        4) clear_client_allowlist ;;
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
    
    install_dependency "curl"
    install_dependency "jq"
    
    # ==================== 🔒 新增：防火墙持久化依赖自动安装 ====================
    local os_type=$(detect_os)
    if [[ "$os_type" == "ubuntu" || "$os_type" == "debian" ]]; then
        # Debian/Ubuntu 自动接受预设配置，防止弹出交互式蓝屏挂起脚本
        if ! dpkg -s iptables-persistent &>/dev/null; then
            print_info "检测到系统为 Debian/Ubuntu，正在安装 iptables-persistent 以支持白名单持久化..."
            echo iptables-persistent iptables-persistent/ensure-backend select true | debconf-set-selections
            echo iptables-persistent iptables-persistent/save_v4 select true | debconf-set-selections
            apt-get update -qq && apt-get install -y iptables-persistent
        fi
    elif [[ "$os_type" == "centos" || "$os_type" == "rhel" || "$os_type" == "fedora" ]]; then
        if ! rpm -q iptables-services &>/dev/null; then
            print_info "检测到系统为 RHEL 系，正在安装 iptables-services 并开机自启..."
            yum install -y iptables-services
            systemctl enable iptables
        fi
    fi
    # =========================================================================

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
        # 【修复 3】纠正日志措辞，避免误导用户
        print_info "正在升级并更新 SmartDNS 二进制包..."
        systemctl stop smartdns 2>/dev/null || true
    else
        print_info "正在获取并解压部署 SmartDNS 核心..."
    fi

    install_dependency "wget"
    local arch=$(detect_arch)
    local asset_arch=$([ "$arch" = "amd64" ] && echo "x86_64" || echo "aarch64")
    local download_url=$(curl -s https://api.github.com/repos/pymumu/smartdns/releases/latest | grep "browser_download_url" | grep "$asset_arch-linux-all.tar.gz" | head -n 1 | cut -d '"' -f 4)
    
    cd /tmp && wget -q --show-progress "${download_url}" -O smartdns.tar.gz
    tar -xzf smartdns.tar.gz && cd smartdns && chmod +x ./install && ./install -i
    cd /tmp && rm -rf smartdns smartdns.tar.gz
    print_success "SmartDNS 核心包分发与加载就绪。"
}

configure_smartdns_rules() {
    local is_update=$1
    ensure_root
    if [ "$is_update" != "true" ]; then
        if ! check_and_fix_port_conflict; then exit 1; fi
    fi
    install_smartdns_binary "$is_update"

    print_info "正在自动获取中转端公网 IPv4 地址..."
    local public_ip=""
    public_ip=$(get_public_ip "v4") # 明确指定调用高级防卡死函数
    
    public_ip=$(echo "${public_ip}" | tr -d '[:space:]')

    if [ -z "${public_ip}" ] || [ "${public_ip}" = "127.0.0.1" ]; then
        print_warning "未能自动确认公网 IP，将使用回环地址 127.0.0.1 保底。"
        public_ip="127.0.0.1"
    else
        print_success "成功确认中转端公网 IP: ${public_ip}"
    fi

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

    awk -v ip="${public_ip}" '/^[^#[:space:]]/ {gsub(/[[:space:]\r]/, ""); if($0!="") print "address /" $0 "/" ip}' "${TEMP_DOMAIN_FILE}" >> "${OUTPUT_FILE}"

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

uninstall_all_services() {
    ensure_root
    print_warning "正在全面卸载并净化本机的中转与分流服务..."
    
    systemctl stop sniproxy smartdns 2>/dev/null || true
    systemctl disable sniproxy smartdns 2>/dev/null || true
    
    if [ -f /usr/sbin/smartdns ] || [ -f /usr/bin/smartdns ]; then
        print_info "正在调用 SmartDNS 核心卸载..."
        local arch=$(detect_arch)
        local asset_arch=$([ "$arch" = "amd64" ] && echo "x86_64" || echo "aarch64")
        local download_url=$(curl -s https://api.github.com/repos/pymumu/smartdns/releases/latest | grep "browser_download_url" | grep "$asset_arch-linux-all.tar.gz" | head -n 1 | cut -d '"' -f 4)
        
        if [ -n "$download_url" ]; then
            cd /tmp && wget -q "${download_url}" -O smartdns_un.tar.gz
            tar -xzf smartdns_un.tar.gz && cd smartdns && chmod +x ./install
            ./install -u >/dev/null 2>&1 
            cd /tmp && rm -rf smartdns smartdns_un.tar.gz
        fi
    fi

    clear_client_allowlist
    rm -f "$SNI_SERVICE_FILE"
    rm -rf "$SNI_BASE_DIR"
    rm -rf /etc/smartdns
    rm -f /usr/lib/systemd/system/smartdns.service /lib/systemd/system/smartdns.service
    rm -f /usr/sbin/smartdns /usr/bin/smartdns
    
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true
    
    print_success "系统环境已彻底净化，恢复至初始状态。"
}

# ==================== GitHub 代理下载核心函数 ====================
run_dns() {
    clear
    local GITHUB_PROXY=(
        ''
        'https://v6.gh-proxy.org/'
        'https://gh-proxy.com/'
        'https://hub.glowp.xyz/'
        'https://proxy.vvvv.ee/'
        'https://ghproxy.lvedong.eu.org/'
    )
    
    local RAW_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/unlockdns.sh"
    local TEMP_SCRIPT="/tmp/nginx_backup_restore_temp.sh"
    local success=false

    for proxy in "${GITHUB_PROXY[@]}"; do
        local target_url="${proxy}${RAW_URL}"
        if curl -fsSL --connect-timeout 8 "$target_url" -o "$TEMP_SCRIPT"; then
            success=true
            break
        fi
        # 【修复 4】将未定义的 ${RESET} 统一修正为头部定义的 ${NC}
        echo -e "${RED}❌ 当前连接失败，正在切换下一个节点...${NC}"
    done

    if [ "$success" = true ] && [ -f "$TEMP_SCRIPT" ]; then
        chmod +x "$TEMP_SCRIPT"
        bash "$TEMP_SCRIPT"
        rm -f "$TEMP_SCRIPT"
    else
        echo -e "${RED}❌ 致命错误：所有 GitHub 代理节点均无法连接，请检查您的 VPS 网络！${NC}"
    fi
}

# ==================== 主控控制面板 ====================
main() {
    local my_ip
    my_ip=$(get_public_ip "v4") # 精准调取
    
    local remote_sni_ver=$(get_remote_sni_version)
    local remote_sdns_ver=$(get_remote_smartdns_version)

    local sni_installed="false"
    local smartdns_installed="false"
    local current_sni_ver="${RED}未装载${NC}"
    local current_sdns_ver="${RED}未装载${NC}"

    refresh_local_status() {
        sni_installed="false"
        if systemctl list-unit-files | grep -q "^sniproxy\.service"; then
            sni_installed="true"
            if [ -f "$VERSION_FILE" ]; then 
                current_sni_ver=$(cat "$VERSION_FILE")
            else
                current_sni_ver="v1.0.7"
            fi
        else
            current_sni_ver="${RED}未安装${NC}"
        fi

        smartdns_installed="false"
        if systemctl list-unit-files | grep -q "^smartdns\.service" || command -v smartdns &> /dev/null; then
            smartdns_installed="true"
            local raw_ver
            raw_ver=$(smartdns -v 2>&1 | head -n 1)
            local main_ver
            main_ver=$(echo "$raw_ver" | awk '{print $2}' | cut -d'-' -f1)
            local sub_ver
            sub_ver=$(echo "$raw_ver" | grep -o 'Release[^)]*')

            if [ -n "$main_ver" ] && [ -n "$sub_ver" ]; then
                current_sdns_ver="${main_ver} (${sub_ver})"
            elif [ -n "$main_ver" ]; then
                current_sdns_ver="${main_ver}"
            else
                current_sdns_ver="未知版本"
            fi
        else
            current_sdns_ver="${RED}未安装${NC}"
        fi
    }

    refresh_local_status

    while true; do
        clear
        
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

        local whitelist_view="${YELLOW}公开解锁(任意设备改DNS可解锁)${NC}"
        if [ -f "$ALLOWLIST_FILE" ] && [ -s "$ALLOWLIST_FILE" ]; then
            local count
            count=$(grep -v '^[[:space:]]*#' "$ALLOWLIST_FILE" | sed '/^[[:space:]]*$/d' | wc -l)
            whitelist_view="${YELLOW}安全模式(允许已授权的 ${count} 个IP)${NC}"
        fi

        echo -e "${GREEN}=============================================${NC}"
        echo -e "${GREEN}        ◈    流媒体 DNS 解锁面板    ◈         ${NC}"
        echo -e "${GREEN}=============================================${NC}"
        echo -e "${GREEN} SNIProxy 状态:${NC} $sni_status_view"
        echo -e "${GREEN} SmartDNS 状态:${NC} $smartdns_status_view"
        echo -e "${GREEN} SNIProxy 版本:${NC} ${YELLOW}${current_sni_ver}${NC} / 远程: ${CYAN}${remote_sni_ver}${NC}"
        echo -e "${GREEN} SmartDNS 版本:${NC} ${YELLOW}${current_sdns_ver}${NC} / 远程: ${CYAN}${remote_sdns_ver}${NC}"
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
        echo -e "${GREEN} 10.${NC} ${YELLOW}自定义DNS解锁${NC}"
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
                refresh_local_status 
                echo -e "\n${GREEN}==================================================${NC}"
                print_success "中转端部署完全就绪！"
                echo -e "现在，你其他的【落地机】不需要装任何东西，直接执行这三行命令即可解锁："
                echo -e "${YELLOW}chattr -i /etc/resolv.conf 2>/dev/null || true${NC}"
                echo -e "${YELLOW}echo \"nameserver ${my_ip}\" > /etc/resolv.conf${NC}"
                echo -e "${YELLOW}chattr +i /etc/resolv.conf 2>/dev/null${NC}"
                echo -e "${GREEN}==================================================${NC}"
                echo -n "按回车键返回面板..."; read -r _ < /dev/tty ;;
            2) 
                install_sniproxy "true"
                configure_smartdns_rules "true"
                refresh_local_status 
                print_success "SNIProxy 和 SmartDNS 核心程序以及分流规则已全部升级成功！"
                echo -n "按回车键返回面板..."; read -r _ < /dev/tty ;;
            3) 
                uninstall_all_services
                refresh_local_status 
                echo -n "按回车键返回面板..."; read -r _ < /dev/tty ;;
            4) 
                manage_client_allowlist
                echo -n "按回车键返回面板..."; read -r _ < /dev/tty ;;
            5) systemctl start sniproxy smartdns 2>/dev/null && print_success "服务已完成启动指令。"; sleep 1.5 ;;
            6) systemctl stop sniproxy smartdns 2>/dev/null && print_success "服务已完成停止指令. "; sleep 1.5 ;;
            7) systemctl restart sniproxy smartdns 2>/dev/null && print_success "核心组件已全部重启。"; sleep 1.5 ;;
            8) show_logs; echo -n "按回车键返回面板..."; read -r _ < /dev/tty ;;
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
                echo -n "按回车键返回面板..."; read -r _ < /dev/tty ;;
            10) run_dns ;;
            0) exit 0 ;;
            *) print_error "无效选项: '$choice'，请重新输入。"; sleep 1.5 ;;
        esac
    done
}

main "$@"
