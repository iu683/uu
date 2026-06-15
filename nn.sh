#!/bin/sh
# ========================================================
#  SNIProxy & SmartDNS 公共解锁 DNS管理脚本 (Alpine 自动依赖完整版)
# ========================================================

# ==================== 🛠️ 1. Alpine 基础依赖自动检测与强制补齐 ====================
# 由于用户可能直接使用 sh 运行，我们在这里静默完成基础设施搭建
if [ ! -f /tmp/alpine_dep_ok.flag ]; then
    echo "[INFO] 正在检测 Alpine 系统核心依赖组件..."
    # 强制刷新软件源索引
    apk update --no-cache >/dev/null 2>&1
    
    # 检查并补齐 bash (脚本运行核心环境)
    if ! command -v bash >/dev/null 2>&1; then
        echo "[INFO] 发现系统缺少 bash，正在自动安装..."
        apk add --no-cache bash >/dev/null 2>&1
    fi
    
    # 检查并补齐网络与防火墙必要组件
    for pkg in curl jq iptables ip6tables wget make gcc g++ musl-dev linux-headers openssl-dev xargs; do
        if ! command -v $pkg >/dev/null 2>&1 && [ "$pkg" != "musl-dev" ] && [ "$pkg" != "linux-headers" ] && [ "$pkg" != "openssl-dev" ]; then
            echo "[INFO] 正在自动补齐核心组件: $pkg..."
            apk add --no-cache $pkg >/dev/null 2>&1
        fi
    done
    
    # 额外补充编译环境需要的库文件
    apk add --no-cache musl-dev linux-headers openssl-dev >/dev/null 2>&1
    
    # 启动并允许防火墙服务开机自启（白名单核心保障）
    if [ -f /etc/init.d/iptables ]; then
        rc-update add iptables default >/dev/null 2>&1
        rc-service iptables start >/dev/null 2>&1
    fi

    touch /tmp/alpine_dep_ok.flag
    echo "[SUCCESS] Alpine 基础运行环境与依赖组件已全部自动补齐！"
fi

# ==================== 🚀 2. 无缝移交控制权给高级 Bash 逻辑 ====================
if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

# ==================== 💎 3. 高级 Bash 核心业务逻辑实现 ====================
# 参数配置
LISTEN_PORT="443"
BINARY_NAME="sniproxy"
SNI_BASE_DIR="/etc/sniproxy"
ALLOWLIST_FILE="$SNI_BASE_DIR/allowed_client_ips.txt"
VERSION_FILE="$SNI_BASE_DIR/version.txt"

SMARTDNS_CONF_URL="https://raw.githubusercontent.com/pymumu/smartdns/master/etc/smartdns/smartdns.conf"
DOMAIN_LIST_URL="https://raw.githubusercontent.com/1-stream/1stream-public-utils/refs/heads/main/stream.text.list"
OUTPUT_FILE="smartdns.conf"
TEMP_DOMAIN_FILE="/tmp/domain_list.txt"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "此操作需要 root 权限。请使用 root 用户身份运行。"
        exit 1
    fi
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "核心依赖 '$1' 异常丢失，正在尝试二次强制修复..."
        apk add --no-cache "$1" >/dev/null 2>&1
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

get_public_ip() {
    local pub_ip
    pub_ip=$(curl -s4 --max-time 3 api.ipify.org || curl -s4 --max-time 3 ifconfig.me || echo "你的中转机公网IP")
    echo "$pub_ip"
}

get_remote_sni_version() {
    curl -sS --max-time 1.5 "https://api.github.com/repos/XIU2/SNIProxy/releases/latest" | jq -r '.tag_name' 2>/dev/null || echo "未知"
}

get_remote_smartdns_version() {
    curl -sS --max-time 1.5 "https://api.github.com/repos/pymumu/smartdns/releases/latest" | jq -r '.tag_name' 2>/dev/null || echo "未知"
}

# ==================== 安全策略模块 (Alpine OpenRC 完美兼容版) ====================
persist_firewall_rules() {
    if [ -f /etc/init.d/iptables ]; then
        rc-service iptables save >/dev/null 2>&1 && print_success "防火墙规则已持久化。"
    else
        print_warning "未检测到 Alpine iptables 服务，白名单在重启后可能会失效。"
    fi
}

clear_client_allowlist() {
    ensure_root
    print_info "正在清空客户端 IP 白名单，放行任意公网连接 (53/443)..."
    if command -v iptables &> /dev/null; then
        iptables -D INPUT -p tcp --dport "$LISTEN_PORT" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        
        if [ -f "$ALLOWLIST_FILE" ]; then
            while read -r ip; do
                [[ "$ip" =~ ^# ]] || [ -z "$ip" ] && continue
                iptables -D INPUT -p tcp --dport "$LISTEN_PORT" -s "$ip" -j ACCEPT 2>/dev/null || true
                iptables -D INPUT -p udp --dport 53 -s "$ip" -j ACCEPT 2>/dev/null || true
            done < "$ALLOWLIST_FILE"
        fi
        # 移除可能存在的阻断规则，确保彻底放行
        iptables -D INPUT -p tcp --dport "$LISTEN_PORT" -j DROP 2>/dev/null || true
        iptables -D INPUT -p udp --dport 53 -j DROP 2>/dev/null || true
    fi
    rm -f "$ALLOWLIST_FILE"
    persist_firewall_rules
    print_success "安全策略已变更为：允许任意公网落地机连接本 DNS。"
}

apply_client_allowlist() {
    local allowed_ips=("$@")
    check_command "iptables"
    
    print_info "正在构建客户端 IP 安全白名单规则..."
    clear_client_allowlist >/dev/null 2>&1

    # 依次允许授权落地机
    for ip in "${allowed_ips[@]}"; do
        iptables -A INPUT -p tcp --dport "$LISTEN_PORT" -s "$ip" -j ACCEPT
        iptables -A INPUT -p udp --dport 53 -s "$ip" -j ACCEPT
    done
    
    # 拦截其他一切未授权请求
    iptables -A INPUT -p tcp --dport "$LISTEN_PORT" -j DROP
    iptables -A INPUT -p udp --dport 53 -j DROP

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
    choice=$(echo "$choice" | tr -d '[:space:]')

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
            
            # =============== ✨ 此处已彻底修复 Alpine 语法解析报错暗坑 ✨ ===============
            local unique_ips=()
            while IFS= read -r line; do
                [ -n "$line" ] && unique_ips+=("$line")
            done <<EOF
$(printf '%s\n' "${allowed_ips[@]}" | awk '!seen[$0]++')
EOF
            # =========================================================================
            
            apply_client_allowlist "${unique_ips[@]}"
            ;;
        3) clear_client_allowlist ;;
        *) return 0 ;;
    esac
}

# ==================== SNIProxy 模块 (Alpine OpenRC 版) ====================
install_sniproxy() {
    ensure_root
    local is_update=$1
    
    if [ "$is_update" != "true" ] && [ -f "/etc/init.d/sniproxy" ]; then
        print_warning "检测到 SNIProxy 已安装。"
        return 0
    fi
    
    if [ "$is_update" = "true" ]; then
        print_info "正在升级 SNIProxy 核心版本..."
        rc-service sniproxy stop 2>/dev/null || true
    else
        print_info "开始全新安装 SNIProxy..."
    fi
    
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

        # 构造并写入 Alpine 官方级规范 OpenRC 服务脚本
        cat <<'EOF' > /etc/init.d/sniproxy
#!/sbin/openrc-run

description="SNI Proxy Service"
pidfile="/run/sniproxy.pid"
command="/etc/sniproxy/sniproxy"
command_args="-c /etc/sniproxy/config.yaml"
command_background="yes"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/sniproxy
        rc-update add sniproxy default >/dev/null 2>&1
    fi

    rc-service sniproxy start
    print_success "SNIProxy 核心包 ($version) 部署成功。"
}

# ==================== SmartDNS 模块 (Alpine 适配) ====================
check_and_fix_port_conflict() {
    print_info "检查 53 端口占用情况..."
    local port_usage=""
    if command -v ss &> /dev/null; then port_usage=$(ss -tulnp | grep :53 2>/dev/null); fi
    [ -z "$port_usage" ] && return 0
    
    if echo "$port_usage" | grep -q "smartdns"; then return 0; fi
    print_error "端口 53 被其他未知程序占用，请先手动清理后再试:\n$port_usage"
    return 1
}

install_smartdns_binary() {
    local is_update=$1
    if [ "$is_update" != "true" ] && command -v smartdns &> /dev/null; then return 0; fi
    
    if [ "$is_update" = "true" ]; then
        print_info "正在升级并重新编译 SmartDNS 二进制程序..."
        rc-service smartdns stop 2>/dev/null || true
    else
        print_info "正在获取并编译安装 SmartDNS 核心..."
    fi

    local arch=$(detect_arch)
    local asset_arch=$([ "$arch" = "amd64" ] && echo "x86_64" || echo "aarch64")
    local download_url=$(curl -s https://api.github.com/repos/pymumu/smartdns/releases/latest | grep "browser_download_url" | grep "$asset_arch-linux-all.tar.gz" | head -n 1 | cut -d '"' -f 4)
    
    cd /tmp && wget -q --show-progress "${download_url}" -O smartdns.tar.gz
    tar -xzf smartdns.tar.gz && cd smartdns && chmod +x ./install
    
    # 自动识别 Alpine 环境并完美生成 OpenRC 初始化脚本
    ./install -i
    
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

    # ==================== 🌐 动态自动获取公网 IPv4 ====================
    print_info "正在自动获取中转端公网 IPv4 地址..."
    local public_ip=""
    public_ip=$(curl -s4 --max-time 3 api.ipify.org || curl -s4 --max-time 3 ifconfig.me || curl -s4 --max-time 3 ip4.icanhazip.com)
    public_ip=$(echo "${public_ip}" | tr -d '[:space:]')

    if [ -z "${public_ip}" ]; then
        print_warning "未能自动获取到公网 IP，将 fallback 降级使用 127.0.0.1"
        public_ip="127.0.0.1"
    else
        print_success "成功获取中转端公网 IP: ${public_ip}"
    fi
    # ===========================================================================

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

    # 完全清洗行尾和异常空格，并将所有的分流劫持统一指向刚才动态获取的公网 IP
    awk -v ip="${public_ip}" '/^[^#[:space:]]/ {gsub(/[[:space:]\r]/, ""); if($0!="") print "address /" $0 "/" ip}' "${TEMP_DOMAIN_FILE}" >> "${OUTPUT_FILE}"

    rm -f "${TEMP_DOMAIN_FILE}"

    mkdir -p /etc/smartdns
    [ -f /etc/smartdns/smartdns.conf ] && cp /etc/smartdns/smartdns.conf /etc/smartdns/smartdns.conf.bak
    cp "${OUTPUT_FILE}" /etc/smartdns/smartdns.conf
    rm -f "${OUTPUT_FILE}"

    rc-service smartdns restart
    sleep 1
    if rc-service smartdns status | grep -q "started"; then
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
    echo -e "${GREEN}◈  流媒体解锁服务 实时运行日志 (Alpine)  ◈${NC}"
    echo -e "${GREEN}=============================================${NC}"
    print_info "正在读取服务状态与系统日志快照:"
    echo -e "${YELLOW}--- 服务活性检测状态 ---${NC}"
    rc-service smartdns status
    rc-service sniproxy status
    echo -e "\n${YELLOW}--- 系统最新消息输出 (来自 /var/log/messages) ---${NC}"
    if [ -f /var/log/messages ]; then
        tail -n 30 /var/log/messages
    else
        echo "未检测到系统内置 syslog 文件（部分极简 Alpine 环境默认未配置 syslog 记录）。"
    fi
    echo -e "${GREEN}=============================================${NC}"
}

uninstall_all_services() {
    ensure_root
    print_warning "正在全面卸载并从 Alpine 中净化本服务组件..."
    
    rc-service sniproxy stop 2>/dev/null || true
    rc-update del sniproxy default 2>/dev/null || true
    rc-service smartdns stop 2>/dev/null || true
    rc-update del smartdns default 2>/dev/null || true
    
    clear_client_allowlist >/dev/null 2>&1
    rm -f /etc/init.d/sniproxy
    rm -rf "$SNI_BASE_DIR"
    rm -rf /etc/smartdns
    rm -f /etc/init.d/smartdns
    rm -f /usr/sbin/smartdns /usr/bin/smartdns
    
    print_success "系统环境已彻底净化，恢复至初始状态。"
}

# ==================== 主控控制面板 ====================
main() {
    local my_ip
    my_ip=$(get_public_ip)
    
    local remote_sni_ver=$(get_remote_sni_version)
    local remote_sdns_ver=$(get_remote_smartdns_version)

    local sni_installed="false"
    local smartdns_installed="false"
    local current_sni_ver="${RED}未装载${NC}"
    local current_sdns_ver="${RED}未装载${NC}"

    refresh_local_status() {
        sni_installed="false"
        if [ -f "/etc/init.d/sniproxy" ]; then
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
        if [ -f "/etc/init.d/smartdns" ] || command -v smartdns &> /dev/null; then
            smartdns_installed="true"
            local raw_ver=$(smartdns -v 2>&1 | head -n 1)
            local main_ver=$(echo "$raw_ver" | awk '{print $2}' | cut -d'-' -f1)
            if [ -n "$main_ver" ]; then
                current_sdns_ver="${main_ver}"
            else
                current_sdns_ver="已装载"
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
            if rc-service sniproxy status | grep -q "started"; then
                sni_status_view="${GREEN}运行中${NC} ${YELLOW}(端口: ${LISTEN_PORT})${NC}"
            else
                sni_status_view="${YELLOW}已停止${NC}"
            fi
        fi

        local smartdns_status_view="${RED}未安装${NC}"
        if [ "$smartdns_installed" = "true" ]; then
            if rc-service smartdns status | grep -q "started"; then
                smartdns_status_view="${GREEN}运行中${NC} ${YELLOW}(端口: 53)${NC}"
            else
                smartdns_status_view="${YELLOW}已停止${NC}"
            fi
        fi

        local whitelist_view="${YELLOW}公开解锁(任意设备改DNS即可解锁)${NC}"
        if [ -f "$ALLOWLIST_FILE" ] && [ -s "$ALLOWLIST_FILE" ]; then
            local count=$(grep -v '^[[:space:]]*#' "$ALLOWLIST_FILE" | sed '/^[[:space:]]*$/d' | wc -l)
            whitelist_view="${YELLOW}安全模式(允许已授权的 ${count} 个IP)${NC}"
        fi

        echo -e "${GREEN}=============================================${NC}"
        echo -e "${GREEN}        ◈    流媒体 DNS 解锁面板 (Alpine)    ◈         ${NC}"
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
        choice=$(echo "$choice" | tr -d '[:space:]')

        case "$choice" in
            1)
                install_sniproxy "false"
                configure_smartdns_rules "false"
                refresh_local_status
                echo -e "\n${GREEN}==================================================${NC}"
                print_success "Alpine 中转端部署完全就绪！"
                echo -e "现在，你其他的【落地机】不需要装任何东西，直接执行这三行命令即可解锁："
                echo -e "${YELLOW}chattr -i /etc/resolv.conf 2>/dev/null || true${NC}"
                echo -e "${YELLOW}echo \"nameserver ${my_ip}\" > /etc/resolv.conf${NC}"
                echo -e "${YELLOW}chattr +i /etc/resolv.conf 2>/dev/null${NC}"
                echo -e "${GREEN}==================================================${NC}"
                echo -n "按回车键返回面板..."; read -r _ ;;
            2) 
                install_sniproxy "true"
                configure_smartdns_rules "true"
                refresh_local_status
                print_success "SNIProxy 和 SmartDNS 核心程序以及分流规则已全部升级成功！"
                echo -n "按回车键返回面板..."; read -r _ ;;
            3) 
                uninstall_all_services
                refresh_local_status
                echo -n "按回车键返回面板..."; read -r _ ;;
            4) 
                manage_client_allowlist
                echo -n "按回车键返回面板..."; read -r _ ;;
            5) rc-service sniproxy start 2>/dev/null; rc-service smartdns start 2>/dev/null; print_success "服务已完成启动指令。"; sleep 1.5 ;;
            6) rc-service sniproxy stop 2>/dev/null; rc-service smartdns stop 2>/dev/null; print_success "服务已完成停止指令。"; sleep 1.5 ;;
            7) rc-service sniproxy restart 2>/dev/null; rc-service smartdns restart 2>/dev/null; print_success "核心组件已全部重启。"; sleep 1.5 ;;
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
            *) print_error "无效选项: '$choice'，请重新输入. "; sleep 1.5 ;;
        esac
    done
}

main "$@"
