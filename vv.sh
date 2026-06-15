#!/bin/sh
# ========================================================
#  SNIProxy & SmartDNS 公共解锁 DNS管理脚本 (Alpine 终极无缝版)
# ========================================================

# ==================== 🛠️ 1. Alpine 基础依赖与防火墙完美初始化 ====================
if [ ! -f /tmp/alpine_dep_ok.flag ]; then
    echo "[INFO] 正在检测 Alpine 系统核心依赖组件..."
    apk update --no-cache >/dev/null 2>&1
    
    if ! command -v bash >/dev/null 2>&1; then
        echo "[INFO] 发现系统缺少 bash，正在自动安装..."
        apk add --no-cache bash >/dev/null 2>&1
    fi
    
    for pkg in curl jq iptables ip6tables wget make gcc g++ musl-dev linux-headers openssl-dev xargs; do
        if ! command -v $pkg >/dev/null 2>&1 && [ "$pkg" != "musl-dev" ] && [ "$pkg" != "linux-headers" ] && [ "$pkg" != "openssl-dev" ]; then
            echo "[INFO] 正在自动补齐核心组件: $pkg..."
            apk add --no-cache $pkg >/dev/null 2>&1
        fi
    done
    
    apk add --no-cache musl-dev linux-headers openssl-dev >/dev/null 2>&1
    
    # 彻底攻克 iptables 拒绝空载启动的系统暗坑
    if [ -f /etc/init.d/iptables ]; then
        rc-update add iptables default >/dev/null 2>&1
        if ! rc-service iptables status | grep -q "started"; then
            echo "[INFO] 检测到防火墙服务未激活，正在注入安全基准规则以破除 Alpine 空载限制..."
            iptables -F INPUT 2>/dev/null || true
            iptables -A INPUT -i lo -j ACCEPT 2>/dev/null
            iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
            iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
            if [ -f /etc/init.d/iptables ]; then
                /etc/init.d/iptables save >/dev/null 2>&1
            fi
            rc-service iptables start >/dev/null 2>&1
        fi
    fi

    touch /tmp/alpine_dep_ok.flag
    echo "[SUCCESS] Alpine 基础运行环境与防火墙状态已完美激活就绪！"
fi

if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

# ==================== 💎 2. 高级 Bash 核心业务逻辑实现 ====================
LISTEN_PORT="443"
BINARY_NAME="sniproxy"
SNI_BASE_DIR="/etc/sniproxy"
ALLOWLIST_FILE="$SNI_BASE_DIR/allowed_client_ips.txt"
VERSION_FILE="$SNI_BASE_DIR/version.txt"

DOMAIN_LIST_URL="https://raw.githubusercontent.com/1-stream/1stream-public-utils/refs/heads/main/stream.text.list"
OUTPUT_FILE="/etc/smartdns/smartdns.conf"
TEMP_DOMAIN_FILE="/tmp/domain_list.txt"

# 颜色定义（修复在某些 Alpine 终端下的乱码问题）
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

persist_firewall_rules() {
    if [ -f /etc/init.d/iptables ]; then
        rc-service iptables save >/dev/null 2>&1 && print_success "防火墙规则已持久化。"
    fi
}

clear_client_allowlist() {
    ensure_root
    print_info "正在清空客户端 IP 白名单..."
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
        iptables -D INPUT -p tcp --dport "$LISTEN_PORT" -j DROP 2>/dev/null || true
        iptables -D INPUT -p udp --dport 53 -j DROP 2>/dev/null || true
    fi
    rm -f "$ALLOWLIST_FILE"
    persist_firewall_rules
}

apply_client_allowlist() {
    local allowed_ips=("$@")
    check_command "iptables"
    
    print_info "正在构建客户端 IP 安全白名单规则..."
    clear_client_allowlist >/dev/null 2>&1

    for ip in "${allowed_ips[@]}"; do
        iptables -A INPUT -p tcp --dport "$LISTEN_PORT" -s "$ip" -j ACCEPT
        iptables -A INPUT -p udp --dport 53 -s "$ip" -j ACCEPT
    done
    
    iptables -A INPUT -p tcp --dport "$LISTEN_PORT" -j DROP
    iptables -A INPUT -p udp --dport 53 -j DROP

    mkdir -p "$SNI_BASE_DIR"
    {
        echo "# 授权访问此公共 DNS 与 解锁中转的落地机 IP"
        printf '%s\n' "${allowed_ips[@]}"
    } > "$ALLOWLIST_FILE"

    persist_firewall_rules
    print_success "安全策略已变更：安全白名单已应用。"
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
                ip=$(echo "$ip" | tr -d '\n\r[[:space:]]')
                [ -z "$ip" ] && continue
                if validate_ip_or_cidr "$ip"; then allowed_ips+=("$ip")
                else print_error "无效的 IP 格式: $ip"; return 1; fi
            done
            
            [ "${#allowed_ips[@]}" -eq 0 ] && { print_warning "未输入有效IP。"; return 0; }
            
            local unique_ips=()
            while IFS= read -r line; do
                [ -n "$line" ] && unique_ips+=("$line")
            done <<EOF
$(printf '%s\n' "${allowed_ips[@]}" | awk '!seen[$0]++')
EOF
            apply_client_allowlist "${unique_ips[@]}"
            ;;
        3) clear_client_allowlist && print_success "已转为公开解锁。";;
        *) return 0 ;;
    esac
}

install_sniproxy() {
    ensure_root
    local is_update=$1
    if [ "$is_update" != "true" ] && [ -f "/etc/init.d/sniproxy" ]; then return 0; fi
    
    local arch=$(detect_arch)
    local version=$(curl -sSL "https://api.github.com/repos/XIU2/SNIProxy/releases/latest" | jq -r '.tag_name')
    [ -z "$version" ] || [ "$version" = "null" ] && version="v1.0.7"
    
    local tar_name="sniproxy_linux_${arch}.tar.gz"
    curl -fL "https://github.com/XIU2/SNIProxy/releases/download/${version}/${tar_name}" -o "/tmp/$tar_name"
    mkdir -p "$SNI_BASE_DIR"
    tar -xzf "/tmp/$tar_name" -C "/tmp"
    mv /tmp/sniproxy "$SNI_BASE_DIR/$BINARY_NAME"
    chmod +x "$SNI_BASE_DIR/$BINARY_NAME"
    rm -f "/tmp/$tar_name"

    echo "$version" > "$VERSION_FILE"

    cat <<EOF > "$SNI_BASE_DIR/config.yaml"
listen_addr: ":$LISTEN_PORT"
allow_all_hosts: true
EOF

    cat <<'EOF' > /etc/init.d/sniproxy
#!/sbin/openrc-run
description="SNI Proxy Service"
pidfile="/run/sniproxy.pid"
command="/etc/sniproxy/sniproxy"
command_args="-c /etc/sniproxy/config.yaml"
command_background="yes"
depend() { need net; after firewall; }
EOF
    chmod +x /etc/init.d/sniproxy
    rc-update add sniproxy default >/dev/null 2>&1
    rc-service sniproxy restart
}

install_smartdns_binary() {
    local is_update=$1
    if [ "$is_update" != "true" ] && command -v smartdns &> /dev/null; then return 0; fi
    
    local arch=$(detect_arch)
    local asset_arch=$([ "$arch" = "amd64" ] && echo "x86_64" || echo "aarch64")
    local download_url=$(curl -s https://api.github.com/repos/pymumu/smartdns/releases/latest | grep "browser_download_url" | grep "$asset_arch-linux-all.tar.gz" | head -n 1 | cut -d '"' -f 4)
    
    cd /tmp && wget -q "${download_url}" -O smartdns.tar.gz
    tar -xzf smartdns.tar.gz && cd smartdns && chmod +x ./install
    ./install -i
    cd /tmp && rm -rf smartdns smartdns.tar.gz
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
    public_ip=$(curl -s4 --max-time 3 api.ipify.org || curl -s4 --max-time 3 ifconfig.me || echo "127.0.0.1")
    public_ip=$(echo "${public_ip}" | tr -d '[:space:]')
    print_success "成功获取中转端公网 IP: ${public_ip}"

    # ==================== 💥 【终极修复逻辑】破除孤儿进程死锁 💥 ====================
    print_info "清理残存的独立 SmartDNS 孤儿进程..."
    rc-service smartdns stop >/dev/null 2>&1 || true
    killall -9 smartdns >/dev/null 2>&1 || true
    pkill -9 smartdns >/dev/null 2>&1 || true
    rm -f /var/run/smartdns.pid /run/smartdns.pid 2>/dev/null
    # ==============================================================================

    print_info "正在从零构建轻量化安全分流规则库..."
    mkdir -p /etc/smartdns

    cat > "${OUTPUT_FILE}" << 'EOF'
# ===== Alpine 专属安全精简配置 =====
bind :53
cache-size 32768
prefetch-domain yes
serve-expired yes

# ===== 上游纯净公共不污染 DNS =====
server 1.1.1.1
server 8.8.8.8

# ===== 自动化流媒体就地劫持拦截区 =====
EOF

    print_info "正在同步全球流媒体解锁域名数据源..."
    curl -s "${DOMAIN_LIST_URL}" -o "${TEMP_DOMAIN_FILE}"
    
    awk -v ip="${public_ip}" '/^[^#[:space:]]/ {gsub(/[[:space:]\r\n]/, ""); if($0!="") print "address /" $0 "/" ip}' "${TEMP_DOMAIN_FILE}" >> "${OUTPUT_FILE}"
    rm -f "${TEMP_DOMAIN_FILE}"

    # 纯净重新拉起 OpenRC 服务
    rc-service smartdns start
    sleep 2
    if rc-service smartdns status | grep -q "started"; then
        print_success "中转端 SmartDNS 完美接管并全线运转成功！"
        print_info "当前已稳定装载流媒体分流拦截规则共: $(grep -c "^address " /etc/smartdns/smartdns.conf) 条"
    else
        print_error "SmartDNS 依旧未能成功拉起。请退出脚本后输入命令查看原始报错原因: smartdns -f -c /etc/smartdns/smartdns.conf"
    fi
}

check_and_fix_port_conflict() {
    local port_usage=""
    if command -v ss &> /dev/null; then port_usage=$(ss -tulnp | grep :53 2>/dev/null); fi
    [ -z "$port_usage" ] && return 0
    if echo "$port_usage" | grep -q "smartdns"; then return 0; fi
    return 1
}

show_logs() {
    ensure_root
    clear
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}◈  流媒体解锁服务 实时运行状态 (Alpine)  ◈${NC}"
    echo -e "${GREEN}=============================================${NC}"
    rc-service smartdns status
    rc-service sniproxy status
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
    rm -f /etc/init.d/sniproxy /etc/init.d/smartdns
    rm -rf "$SNI_BASE_DIR" /etc/smartdns /usr/sbin/smartdns /usr/bin/smartdns
    print_success "系统环境已彻底净化。"
}

# ==================== 主控控制面板 ====================
main() {
    local my_ip=$(get_public_ip)
    local sni_installed="false"
    local smartdns_installed="false"
    local current_sni_ver="${RED}未装载${NC}"
    local current_sdns_ver="${RED}未装载${NC}"

    refresh_local_status() {
        if [ -f "/etc/init.d/sniproxy" ]; then
            sni_installed="true"
            [ -f "$VERSION_FILE" ] && current_sni_ver=$(cat "$VERSION_FILE") || current_sni_ver="v1.0.7"
        else
            current_sni_ver="${RED}未安装${NC}"
        fi

        if [ -f "/etc/init.d/smartdns" ] || command -v smartdns &> /dev/null; then
            smartdns_installed="true"
            local main_ver=$(smartdns -v 2>&1 | head -n 1 | awk '{print $2}' | cut -d'-' -f1)
            current_sdns_ver="${main_ver:-已装载}"
        else
            current_sdns_ver="${RED}未安装${NC}"
        fi
    }

    refresh_local_status

    while true; do
        clear
        local sni_status_view="${RED}未安装${NC}"
        [ "$sni_installed" = "true" ] && (rc-service sniproxy status | grep -q "started" && sni_status_view="${GREEN}运行中${NC} ${YELLOW}(端口: ${LISTEN_PORT})${NC}" || sni_status_view="${YELLOW}已停止${NC}")
        
        local smartdns_status_view="${RED}未安装${NC}"
        [ "$smartdns_installed" = "true" ] && (rc-service smartdns status | grep -q "started" && smartdns_status_view="${GREEN}运行中${NC} ${YELLOW}(端口: 53)${NC}" || smartdns_status_view="${YELLOW}已停止${NC}")

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
        echo -e "${GREEN}  8. 查看状态${NC}"
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
                echo -e "你的【落地机】执行这三行命令即可解锁："
                echo -e "${YELLOW}chattr -i /etc/resolv.conf 2>/dev/null || true${NC}"
                echo -e "${YELLOW}echo \"nameserver ${my_ip}\" > /etc/resolv.conf${NC}"
                echo -e "${YELLOW}chattr +i /etc/resolv.conf 2>/dev/null${NC}"
                echo -e "${GREEN}==================================================${NC}"
                echo -n "按回车键返回面板..."; read -r _ ;;
            2) install_sniproxy "true"; configure_smartdns_rules "true"; refresh_local_status; echo -n "按回车键返回面板..."; read -r _ ;;
            3) uninstall_all_services; refresh_local_status; echo -n "按回车键返回面板..."; read -r _ ;;
            4) manage_client_allowlist; echo -n "按回车键返回面板..."; read -r _ ;;
            5) rc-service sniproxy start 2>/dev/null; rc-service smartdns start 2>/dev/null; print_success "指令完成。"; sleep 1.5 ;;
            6) rc-service sniproxy stop 2>/dev/null; rc-service smartdns stop 2>/dev/null; print_success "指令完成。"; sleep 1.5 ;;
            7) rc-service sniproxy restart 2>/dev/null; rc-service smartdns restart 2>/dev/null; print_success "已重启。"; sleep 1.5 ;;
            8) show_logs; echo -n "按回车键返回面板..."; read -r _ ;;
            0) exit 0 ;;
            *) print_error "无效选项。"; sleep 1.5 ;;
        esac
    done
}

main "$@"
