#!/bin/bash
# ========================================================
#  SNIProxy & SmartDNS 流媒体解锁一键集成管理脚本
# ========================================================

# 参数配置
LISTEN_PORT="443"
FIREWALL_CHAIN="SNIPROXY_CLIENT_ALLOWLIST"
BINARY_NAME="sniproxy"
SNI_BASE_DIR="$(pwd)/sniproxy"
ALLOWLIST_FILE="$SNI_BASE_DIR/allowed_client_ips.txt"
SNI_SERVICE_FILE="/etc/systemd/system/sniproxy.service"

SMARTDNS_CONF_URL="https://raw.githubusercontent.com/pymumu/smartdns/master/etc/smartdns/smartdns.conf"
DOMAIN_LIST_URL="https://raw.githubusercontent.com/1-stream/1stream-public-utils/refs/heads/main/stream.text.list"
OUTPUT_FILE="smartdns.conf"
TEMP_DOMAIN_FILE="/tmp/domain_list.txt"
RESOLV_BACKUP_DIR="/etc/systemd/resolved.conf.d"
UNLOCK_IP="" 

# 颜色定义
RED='\033;31m'
GREEN='\033;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色

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
        print_error "命令 '$1' 未找到。请先安装它 (例如: apt install -y $1 或 yum install -y $1)"
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
    if [ "$machine" = "x86_64" ]; then
        echo "amd64"
    elif [ "$machine" = "aarch64" ] || [ "$machine" = "arm64" ]; then
        echo "arm64"
    else
        echo "unknown"
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/redhat-release ]; then
        echo "centos"
    else
        echo "unknown"
    fi
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
        print_error "未知的系统组件，请手动安装 $pkg 后重试。"
        exit 1
    fi
}

# ==================== 核心模块 1：SNIProxy 管理 ====================
persist_firewall_rules() {
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save >/dev/null 2>&1 && print_success "防火墙规则已持久化。"
    elif command -v iptables-save &> /dev/null && [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null && print_success "iptables 规则已保存至 /etc/iptables/rules.v4。"
    else
        print_warning "未检测到 iptables 持久化工具，重启后白名单可能会失效。"
    fi
}

clear_client_allowlist() {
    ensure_root
    print_info "正在清空客户端 IP 白名单，恢复为允许所有 IP 访问..."
    if command -v iptables &> /dev/null; then
        while iptables -C INPUT -p tcp --dport "$LISTEN_PORT" -j "$FIREWALL_CHAIN" 2>/dev/null; do
            iptables -D INPUT -p tcp --dport "$LISTEN_PORT" -j "$FIREWALL_CHAIN"
        done
        iptables -F "$FIREWALL_CHAIN" 2>/dev/null || true
        iptables -X "$FIREWALL_CHAIN" 2>/dev/null || true
    fi
    rm -f "$ALLOWLIST_FILE"
    persist_firewall_rules
    if systemctl is-active --quiet sniproxy; then
        systemctl restart sniproxy
    fi
    print_success "已恢复为允许所有 IP 访问 SNIProxy。"
}

apply_client_allowlist() {
    local allowed_ips=("$@")
    check_command "iptables"
    
    print_info "正在应用客户端 IP 白名单..."
    iptables -N "$FIREWALL_CHAIN" 2>/dev/null || true
    iptables -F "$FIREWALL_CHAIN"

    for ip in "${allowed_ips[@]}"; do
        iptables -A "$FIREWALL_CHAIN" -p tcp --dport "$LISTEN_PORT" -s "$ip" -j ACCEPT
    done
    iptables -A "$FIREWALL_CHAIN" -p tcp --dport "$LISTEN_PORT" -j DROP

    if ! iptables -C INPUT -p tcp --dport "$LISTEN_PORT" -j "$FIREWALL_CHAIN" 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "$LISTEN_PORT" -j "$FIREWALL_CHAIN"
    fi

    mkdir -p "$SNI_BASE_DIR"
    {
        echo "# 允许访问 SNIProxy 的客户端 IP/CIDR"
        printf '%s\n' "${allowed_ips[@]}"
    } > "$ALLOWLIST_FILE"

    persist_firewall_rules
    if systemctl is-active --quiet sniproxy; then
        systemctl restart sniproxy
    fi
    print_success "白名单已生效，仅允许指定 IP 访问阻断端口 $LISTEN_PORT。"
}

manage_client_allowlist() {
    ensure_root
    clear
    
    local current_allowed=""
    [ -f "$ALLOWLIST_FILE" ] && current_allowed=$(grep -v '^[[:space:]]*#' "$ALLOWLIST_FILE" | sed '/^[[:space:]]*$/d')
    
    # 打印对齐主菜单风格的白名单管理面板 (加入拦截端口提示)
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN}◈ SNIProxy 白名单安全管理 ◈${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN} 受控拦截端口 :${NC} ${YELLOW}${LISTEN_PORT}${NC}"
    if [ -n "$current_allowed" ]; then
        echo -e "${GREEN} 当前已放行的客户端 IP 列表:${NC}"
        echo "$current_allowed" | sed 's/^/  • /'
    else
        echo -e "${GREEN} 当前安全策略 :${NC} ${CYAN}未设限 (任意IP可经由 ${LISTEN_PORT} 端口中转)${NC}"
    fi
    echo -e "${GREEN}=================================${NC}"
    echo -e " ${GREEN}1. 设置/覆盖允许 IP 白名单${NC}"
    echo -e " ${GREEN}2. 追加允许 IP 到白名单${NC}"
    echo -e " ${GREEN}3. 清空白名单 (开放所有IP)${NC}"
    echo -e " ${GREEN}0. 返回主菜单${NC}"
    echo -e "${GREEN}=================================${NC}"
    
    local action=""
    read -r -p $'\033[32m请输入选项: \033[0m' action || true
    action=$(echo "$action" | xargs 2>/dev/null || echo "")

    case "$action" in
        1|2)
            echo -e "\n${YELLOW}[提示] 多个 IP 或 CIDR 请使用空格或逗号分隔${NC}"
            echo -n -e "${GREEN}请输入客户端 IP/CIDR: ${NC}"
            local input_ips
            read_required_input input_ips
            input_ips=$(echo "$input_ips" | tr ',' ' ')

            local allowed_ips=()
            if [ "$action" = "2" ] && [ -n "$current_allowed" ]; then
                while IFS= read -r ip; do [ -n "$ip" ] && allowed_ips+=("$ip"); done <<< "$current_allowed"
            fi

            for ip in $input_ips; do
                ip=$(echo "$ip" | tr -d '\r\n' | sed 's/[[:space:]]//g')
                [ -z "$ip" ] && continue
                if validate_ip_or_cidr "$ip"; then
                    allowed_ips+=("$ip")
                else
                    print_error "无效的 IP/CIDR 格式: $ip"
                    return 1
                fi
            done
            
            [ "${#allowed_ips[@]}" -eq 0 ] && { print_warning "未输入有效IP。"; return 0; }
            mapfile -t allowed_ips < <(printf '%s\n' "${allowed_ips[@]}" | awk '!seen[$0]++')
            apply_client_allowlist "${allowed_ips[@]}"
            ;;
        3) clear_client_allowlist ;;
        0) return 0 ;;
        *) print_error "无效选项" ;;
    esac
}

install_sniproxy() {
    ensure_root
    if systemctl list-unit-files | grep -q "^sniproxy\.service"; then
        print_warning "检测到 SNIProxy 已安装。如果需要获取新版本，请选择菜单中的更新选项。"
        return 0
    fi
    
    print_info "开始全新安装 SNIProxy..."
    install_dependency "curl"
    install_dependency "jq"
    
    local arch=$(detect_arch)
    if [ "$arch" = "unknown" ]; then
        print_error "不支持的系统架构。仅支持 x86_64 与 arm64。"
        exit 1
    fi

    print_info "正在获取 SNIProxy 最新版本..."
    local version=$(curl -sSL "https://api.github.com/repos/XIU2/SNIProxy/releases/latest" | jq -r '.tag_name')
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        print_error "获取最新版本号失败，请检查 network。"
        exit 1
    fi
    print_success "最新版本: $version"

    local tar_name="sniproxy_linux_${arch}.tar.gz"
    local download_url="https://github.com/XIU2/SNIProxy/releases/download/${version}/${tar_name}"
    
    print_info "正在下载: $download_url"
    if ! curl -fL "$download_url" -o "/tmp/$tar_name"; then
        print_error "下载 SNIProxy 失败。"
        exit 1
    fi

    local tmp_extract="/tmp/sniproxy_$$"
    mkdir -p "$tmp_extract" "$SNI_BASE_DIR"
    tar -xzf "/tmp/$tar_name" -C "$tmp_extract"
    local binary_path=$(find "$tmp_extract" -type f -name "$BINARY_NAME" | head -n 1)
    
    mv "$binary_path" "$SNI_BASE_DIR/$BINARY_NAME"
    chmod +x "$SNI_BASE_DIR/$BINARY_NAME"
    rm -f "/tmp/$tar_name" && rm -rf "$tmp_extract"

    # 生成初始配置
    cat <<EOF > "$SNI_BASE_DIR/config.yaml"
listen_addr: ":$LISTEN_PORT"
allow_all_hosts: true
EOF

    # 注册 systemd
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

    systemctl daemon-reload
    systemctl enable sniproxy
    systemctl start sniproxy
    
    sleep 1
    if systemctl is-active --quiet sniproxy; then
        print_success "SNIProxy 安装并成功运行在端口 $LISTEN_PORT 上！"
    else
        print_error "服务启动失败，请检查 journalctl -u sniproxy"
    fi
}

update_sniproxy() {
    ensure_root
    if ! systemctl list-unit-files | grep -q "^sniproxy\.service"; then
        print_error "系统未检测到已安装的 SNIProxy 服务，无法更新。"
        return 1
    fi

    print_info "正在检查并更新 SNIProxy..."
    install_dependency "curl"
    install_dependency "jq"
    
    local arch=$(detect_arch)
    local version=$(curl -sSL "https://api.github.com/repos/XIU2/SNIProxy/releases/latest" | jq -r '.tag_name')
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        print_error "获取最新版本号失败。"
        return 1
    fi

    print_info "停止旧版 SNIProxy 服务并拉取核心..."
    systemctl stop sniproxy.service

    local tar_name="sniproxy_linux_${arch}.tar.gz"
    local download_url="https://github.com/XIU2/SNIProxy/releases/download/${version}/${tar_name}"
    
    if curl -fL "$download_url" -o "/tmp/$tar_name"; then
        local tmp_extract="/tmp/sniproxy_$$"
        mkdir -p "$tmp_extract"
        tar -xzf "/tmp/$tar_name" -C "$tmp_extract"
        local binary_path=$(find "$tmp_extract" -type f -name "$BINARY_NAME" | head -n 1)
        mv "$binary_path" "$SNI_BASE_DIR/$BINARY_NAME"
        chmod +x "$SNI_BASE_DIR/$BINARY_NAME"
        rm -f "/tmp/$tar_name" && rm -rf "$tmp_extract"
        print_success "更新包替换成功。"
    else
        print_error "下载更新资产失败，尝试拉起原有旧核心。"
    fi

    systemctl start sniproxy
    print_success "SNIProxy 服务更新流程完成。"
}

manage_sniproxy_service() {
    ensure_root
    if ! systemctl list-unit-files | grep -q "^sniproxy\.service"; then
        print_error "服务未安装，无法进行状态管理。"
        return 1
    fi
    clear
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN}◈ SNIProxy 状态管理 ◈${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e " ${GREEN}1. 启动服务${NC}"
    echo -e " ${GREEN}2. 停止服务${NC}"
    echo -e " ${GREEN}3. 重启服务${NC}"
    echo -e " ${GREEN}0. 返回${NC}"
    echo -e "${GREEN}=================================${NC}"
    
    local s_opt=""
    read -r -p $'\033[32m请输入选项: \033[0m' s_opt || true
    s_opt=$(echo "$s_opt" | xargs 2>/dev/null || echo "")

    case "$s_opt" in
        1) systemctl start sniproxy && print_success "服务已完成启动指令。" ;;
        2) systemctl stop sniproxy && print_success "服务已完成停止指令。" ;;
        3) systemctl restart sniproxy && print_success "服务已完成重启指令。" ;;
        *) return 0 ;;
    esac
}

uninstall_sniproxy() {
    ensure_root
    print_info "正在完全卸载中转端 SNIProxy 服务..."
    systemctl stop sniproxy 2>/dev/null || true
    systemctl disable sniproxy 2>/dev/null || true
    clear_client_allowlist
    rm -f "$SNI_SERVICE_FILE"
    rm -rf "$SNI_BASE_DIR"
    systemctl daemon-reload
    print_success "SNIProxy 卸载干净。"
}

# ==================== 核心模块 2：SmartDNS 管理 ====================
check_and_fix_port_conflict() {
    print_info "检查 53 端口占用情况..."
    local port_usage=""
    if command -v lsof &> /dev/null; then port_usage=$(lsof -i :53 2>/dev/null); fi
    if [ -z "$port_usage" ] && command -v ss &> /dev/null; then port_usage=$(ss -tulnp | grep :53 2>/dev/null); fi
    
    [ -z "$port_usage" ] && { print_success "端口 53 未被占用。"; return 0; }
    
    if echo "$port_usage" | grep -q "systemd-resolve"; then
        print_warning "发现 systemd-resolved 正在占用端口 53，将尝试自动接管..."
        ensure_root
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        
        chattr -i /etc/resolv.conf 2>/dev/null || true
        [ -L /etc/resolv.conf ] && rm /etc/resolv.conf
        [ -f /etc/resolv.conf ] && mv /etc/resolv.conf /etc/resolv.conf.bak.$(date +%u)

        cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
nameserver 1.1.1.1
EOF
        if ! chattr +i /etc/resolv.conf 2>/dev/null; then
            print_warning "环境不支持 chattr 锁定，重置后 resolv.conf 可能会被覆盖。"
        fi
        print_success "已成功接管 53 端口系统解析组件。"
        return 0
    else
        print_error "端口 53 被其他未知进程占用，请手动排查:\n$port_usage"
        return 1
    fi
}

install_smartdns_binary() {
    if command -v smartdns &> /dev/null; then
        print_warning "检测到 SmartDNS 二进制程序已存在，跳过编译安装。"
        return 0
    fi
    local os_type=$(detect_os)
    local arch=$(detect_arch)
    
    print_info "正在获取 SmartDNS 最新版本资产..."
    local latest_release=$(curl -s https://api.github.com/repos/pymumu/smartdns/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$latest_release" ] && latest_release="Release47"

    local asset_arch=""
    if [ "$arch" = "amd64" ]; then asset_arch="x86_64"; else asset_arch="aarch64"; fi

    local download_url=$(curl -s https://api.github.com/repos/pymumu/smartdns/releases/latest | grep "browser_download_url" | grep "$asset_arch-linux-all.tar.gz" | head -n 1 | cut -d '"' -f 4)
    if [ -z "$download_url" ]; then
        download_url="https://github.com/pymumu/smartdns/releases/download/${latest_release}/smartdns.${asset_arch}-linux-all.tar.gz"
    fi

    print_info "下载 SmartDNS 资产包..."
    cd /tmp
    if ! wget -q --show-progress "${download_url}" -O smartdns.tar.gz; then
        print_error "下载 SmartDNS 资产失败。"
        return 1
    fi

    tar -xzf smartdns.tar.gz
    cd smartdns
    chmod +x ./install
    ./install -i
    cd /tmp && rm -rf smartdns smartdns.tar.gz
    print_success "SmartDNS 核心编译安装完成。"
    return 0
}

update_smartdns_binary() {
    ensure_root
    if ! command -v smartdns &> /dev/null; then
        print_error "系统未曾装载 SmartDNS 核心组件，无法执行更新。"
        return 1
    fi
    print_info "准备对本地 SmartDNS 进行核心升级..."
    systemctl stop smartdns 2>/dev/null || true
    rm -f $(command -v smartdns)
    install_smartdns_binary
    systemctl start smartdns
    print_success "SmartDNS 升级覆盖工作执行完毕。"
}

configure_smartdns_rules() {
    echo -e "\n========================================"
    print_info "配置流媒体劫持（SmartDNS 侧）"
    echo -e "========================================\n"
    echo -n "请输入远端 SNI 解锁机的公网 IP: "
    local input_ip
    read_required_input input_ip
    input_ip=$(echo "$input_ip" | tr -d '\r\n' | sed 's/[[:space:]]//g')
    
    if ! validate_ip "$input_ip"; then
        print_error "输入的 IP 格式错误。"
        return 1
    fi
    UNLOCK_IP="$input_ip"

    check_required_tools() { check_command wget; check_command curl; }
    check_required_tools

    if ! command -v smartdns &> /dev/null; then
        print_warning "未检测到 SmartDNS 二进制程序，开始自动安装..."
        install_smartdns_binary || exit 1
    fi

    if ! check_and_fix_port_conflict; then exit 1; fi

    print_info "获取官方 SmartDNS 基础模板配置..."
    wget -q -O "${OUTPUT_FILE}" "${SMARTDNS_CONF_URL}"

    sed -i '/^server /d' "${OUTPUT_FILE}"
    sed -i '/^bind /d' "${OUTPUT_FILE}"

    cat > "${OUTPUT_FILE}.tmp" << 'EOF'
# ===== 自动化劫持上游配置 =====
server 1.1.1.1
server 8.8.8.8
bind :53
cache-size 32768
prefetch-domain yes
serve-expired yes
EOF
    cat "${OUTPUT_FILE}" >> "${OUTPUT_FILE}.tmp"
    mv "${OUTPUT_FILE}.tmp" "${OUTPUT_FILE}"

    print_info "获取流媒体解锁域名数据源（450+ 域名）..."
    curl -s "${DOMAIN_LIST_URL}" -o "${TEMP_DOMAIN_FILE}"
    
    cat >> "${OUTPUT_FILE}" << EOF

# ===== 流媒体一键解锁路由规则 =====
# 目标解锁机: ${UNLOCK_IP}
EOF

    awk -v ip="${UNLOCK_IP}" '/^[^#[:space:]]/ {print "address /" $1 "/" ip}' "${TEMP_DOMAIN_FILE}" >> "${OUTPUT_FILE}"
    rm -f "${TEMP_DOMAIN_FILE}"

    mkdir -p /etc/smartdns
    [ -f /etc/smartdns/smartdns.conf ] && cp /etc/smartdns/smartdns.conf /etc/smartdns/smartdns.conf.bak
    cp "${OUTPUT_FILE}" /etc/smartdns/smartdns.conf
    rm -f "${OUTPUT_FILE}"

    print_info "正在启动/重启 SmartDNS 解析引擎..."
    systemctl enable smartdns &>/dev/null || true
    systemctl restart smartdns

    sleep 1
    if systemctl is-active --quiet smartdns; then
        print_success "解锁端配置大功告成！SmartDNS 现已在 53 端口本地运行。"
        print_info "规则总条数: $(grep -c "^address " /etc/smartdns/smartdns.conf) 条"
    else
        print_error "SmartDNS 运行异常，请通过 'journalctl -u smartdns' 查看系统日志。"
    fi
}

manage_smartdns_service() {
    ensure_root
    if ! systemctl list-unit-files | grep -q "^smartdns\.service"; then
        print_error "服务未安装，无法进行状态管理。"
        return 1
    fi
    clear
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN}◈ SmartDNS 状态管理 ◈${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e " ${GREEN}1. 启动服务${NC}"
    echo -e " ${GREEN}2. 停止服务${NC}"
    echo -e " ${GREEN}3. 重启服务${NC}"
    echo -e " ${GREEN}0. 返回${NC}"
    echo -e "${GREEN}=================================${NC}"
    
    local s_opt=""
    read -r -p $'\033[32m请输入选项: \033[0m' s_opt || true
    s_opt=$(echo "$s_opt" | xargs 2>/dev/null || echo "")

    case "$s_opt" in
        1) systemctl start smartdns && print_success "服务已完成启动指令。" ;;
        2) systemctl stop smartdns && print_success "服务已完成停止指令。" ;;
        3) systemctl restart smartdns && print_success "服务已完成重启指令。" ;;
        *) return 0 ;;
    esac
}

restore_system_defaults() {
    ensure_root
    echo -e "\n========================================"
    print_warning "正在回滚环境并恢复默认 Systemd-resolved 解析"
    echo -e "========================================\n"

    print_info "停止并清空 SmartDNS 路由..."
    if systemctl is-active --quiet smartdns 2>/dev/null; then
        systemctl stop smartdns && systemctl disable smartdns 2>/dev/null || true
        print_success "SmartDNS 服务已彻底关闭。"
    fi

    print_info "尝试还原初始化 systemd-resolved 守护进程..."
    if systemctl list-unit-files | grep -q systemd-resolved; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
        rm -f /etc/resolv.conf
        
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        systemctl enable systemd-resolved 2>/dev/null || true
        systemctl start systemd-resolved 2>/dev/null || true
        print_success "系统原生 Systemd-resolved 托管已恢复。"
    else
        print_warning "本地不存在 systemd-resolved 单元，将使用静态网络配置代答。"
        chattr -i /etc/resolv.conf 2>/dev/null || true
        rm -f /etc/resolv.conf
        cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    fi
    
    if command -v smartdns &> /dev/null; then
        local smartdns_bin=$(command -v smartdns)
        rm -f "$smartdns_bin"
    fi
    rm -rf /etc/smartdns
    print_success "网络环境净化还原成功！"
}

# ==================== 系统主控入口面板（状态注入版） ====================
show_main_menu() {
    clear
    
    # 1. 动态获取 SNIProxy 状态与监听端口
    local sni_status_view="${RED}未安装${NC}"
    if systemctl list-unit-files | grep -q "^sniproxy\.service"; then
        if systemctl is-active --quiet sniproxy; then
            sni_status_view="${GREEN}运行中${NC} (端口: ${YELLOW}${LISTEN_PORT}${NC})"
        else
            sni_status_view="${YELLOW}已停止${NC} (配置端口: ${LISTEN_PORT})"
        fi
    fi

    # 2. 动态获取 SmartDNS 状态
    local smartdns_status_view="${RED}未安装${NC}"
    if systemctl list-unit-files | grep -q "^smartdns\.service"; then
        if systemctl is-active --quiet smartdns; then
            smartdns_status_view="${GREEN}运行中${NC} (端口: 53)"
        else
            smartdns_status_view="${YELLOW}已停止${NC}"
        fi
    fi

    # 3. 动态获取安全策略与规则路由数
    local whitelist_view="${CYAN}全部放行${NC}"
    if [ -f "$ALLOWLIST_FILE" ] && [ -s "$ALLOWLIST_FILE" ]; then
        local count=$(grep -v '^[[:space:]]*#' "$ALLOWLIST_FILE" | sed '/^[[:space:]]*$/d' | wc -l)
        whitelist_view="${PURPLE}白名单模式 (阻断除 ${count} 个IP外的所有流量)${NC}"
    fi

    local rules_count="0"
    if [ -f /etc/smartdns/smartdns.conf ]; then
        rules_count=$(grep -c "^address " /etc/smartdns/smartdns.conf)
    fi

    # 打印完全对齐 Xray-Argo 模板的全新界面
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN}◈流媒体 SNI-SmartDNS 管理面板◈${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN} SNIProxy 状态 :${NC} $sni_status_view"
    echo -e "${GREEN} SmartDNS 状态 :${NC} $smartdns_status_view"
    echo -e "${GREEN} 安全策略模式 :${NC} $whitelist_view"
    echo -e "${GREEN} 劫持域名总数 :${NC} ${YELLOW}${rules_count} 条${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e " ${GREEN}1. 安装 SNIProxy 服务${NC}"
    echo -e " ${GREEN}2. 更新 SNIProxy 服务${NC}"
    echo -e " ${GREEN}3. 卸载 SNIProxy 服务${NC}"
    echo -e " ${GREEN}4. SNIProxy 状态管理${NC}"
    echo -e " ${GREEN}5. 配置 SNIProxy 客户端白名单${NC}"
    echo -e " ${GREEN}6. 安装/配置 SmartDNS 解锁规则${NC}"
    echo -e " ${GREEN}7. 更新 SmartDNS 核心${NC}"
    echo -e " ${GREEN}8. SmartDNS 状态管理${NC}"
    echo -e " ${GREEN}9. 卸载 SmartDNS (恢复系统默认DNS)${NC}"
    echo -e " ${GREEN}0. 退出${NC}"
    echo -e "${GREEN}=================================${NC}"
    
    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    echo "$choice" | xargs 2>/dev/null || echo ""
}

main() {
    while true; do
        local user_choice=$(show_main_menu)

        case "$user_choice" in
            1) install_sniproxy; echo -n "按回车键返回主菜单..."; read -r _ ;;
            2) update_sniproxy; echo -n "按回车键返回主菜单..."; read -r _ ;;
            3) uninstall_sniproxy; echo -n "按回车键返回主菜单..."; read -r _ ;;
            4) manage_sniproxy_service; echo -n "按回车键返回主菜单..."; read -r _ ;;
            5) manage_client_allowlist; echo -n "按回车键返回主菜单..."; read -r _ ;;
            6) configure_smartdns_rules; echo -n "按回车键返回主菜单..."; read -r _ ;;
            7) update_smartdns_binary; echo -n "按回车键返回主菜单..."; read -r _ ;;
            8) manage_smartdns_service; echo -n "按回车键返回主菜单..."; read -r _ ;;
            9) restore_system_defaults; echo -n "按回车键返回主菜单..."; read -r _ ;;
            0) print_info "已安全退出面板。"; exit 0 ;;
            *) print_error "无效选项: '$user_choice'，请重新输入。"; sleep 1.5 ;;
        esac
    done
}

main "$@"
