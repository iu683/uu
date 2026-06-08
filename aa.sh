#!/bin/bash
set -e

#================================================================================
# 常量和全局变量
#================================================================================
VERSION="1.4.0"
REPO="heiher/hev-socks5-tunnel"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
RESET='\033[0m'

# 备用 DNS64 服务器
ALTERNATE_DNS64_SERVERS=(
    "2a00:1098:2b::1"
    "2a01:4f8:c2c:123f::1"
    "2a01:4f9:c010:3f02::1"
    "2001:67c:2b0::4"
    "2001:67c:2b0::6"
)

#================================================================================
# 日志和工具函数
#================================================================================
info() { echo -e "${BLUE}[信息]${NC} $1"; }
success() { echo -e "${GREEN}[成功]${NC} $1"; }
warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
error() { echo -e "${RED}[错误]${NC} $1"; }
step() { echo -e "${PURPLE}[步骤]${NC} $1"; }

require_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 权限运行此脚本，例如: sudo $0"
        exit 1
    fi
}

test_dns64_server() {
    local dns_server=$1
    step "正在测试DNS64服务器 $dns_server 的连通性..."
    if ping6 -c 3 -W 2 "$dns_server" &>/dev/null; then
        info "DNS64服务器 $dns_server 可达。"
        return 0
    else
        warning "DNS64服务器 $dns_server 不可达。"
        return 1
    fi
}

test_github_access() {
    step "正在测试GitHub访问..."
    if curl -s -m 10 https://github.com >/dev/null; then
        success "GitHub访问测试成功。"
        return 0
    else
        warning "GitHub访问测试失败。"
        return 1
    fi
}

restore_dns_config() {
    local resolv_conf=$1
    local resolv_conf_bak=$2
    local was_immutable=$3

    step "恢复原始 DNS 配置..."
    if [ -f "$resolv_conf_bak" ]; then
        mv "$resolv_conf_bak" "$resolv_conf"
        success "DNS 配置已恢复。"
        if [ "$was_immutable" = true ]; then
            info "重新锁定 /etc/resolv.conf..."
            chattr +i "$resolv_conf" || warning "无法重新锁定 /etc/resolv.conf。"
            success "锁定完成。"
        fi
    else
        warning "未找到 DNS 备份文件 ($resolv_conf_bak)，无法自动恢复。"
        if [ "$was_immutable" = true ]; then
             warning "尝试锁定当前的 /etc/resolv.conf..."
             chattr +i "$resolv_conf" || warning "无法锁定 /etc/resolv.conf。"
        fi
    fi
}

set_dns64_servers() {
    local resolv_conf=$1
    local was_immutable=$2
    local resolv_conf_bak=$3
    
    step "设置 DNS64 服务器（用于下载tun2socks）..."
    cat > "$resolv_conf" <<EOF
nameserver 2602:fc59:b0:9e::64
EOF
    
    if test_github_access; then
        return 0
    fi
    
    warning "主DNS64服务器访问GitHub失败，尝试备选DNS64服务器..."
    for dns_server in "${ALTERNATE_DNS64_SERVERS[@]}"; do
        if test_dns64_server "$dns_server"; then
            step "使用备选DNS64服务器: $dns_server"
            cat > "$resolv_conf" <<EOF
nameserver $dns_server
EOF
            if test_github_access; then
                success "使用备选DNS64服务器 $dns_server 成功访问GitHub。"
                return 0
            fi
        fi
    done
    
    error "所有DNS64服务器测试失败，无法访问GitHub。"
    restore_dns_config "$resolv_conf" "$resolv_conf_bak" "$was_immutable"
    return 1
}

cleanup_ip_rules() {
    step "正在清理残留的 IP 规则和路由..."
    ip rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    ip -6 rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    ip route del default dev tun0 table 20 2>/dev/null || true
    ip rule del lookup 20 pref 20 2>/dev/null || true
    ip rule del to 127.0.0.0/8 lookup main pref 16 2>/dev/null || true
    ip rule del to 10.0.0.0/8 lookup main pref 16 2>/dev/null || true
    ip rule del to 172.16.0.0/12 lookup main pref 16 2>/dev/null || true
    ip rule del to 192.168.0.0/16 lookup main pref 16 2>/dev/null || true

    while ip rule del pref 15 2>/dev/null; do true; done
    while ip -6 rule del pref 15 2>/dev/null; do true; done
    while ip rule del pref 5 2>/dev/null; do true; done
    while ip -6 rule del pref 5 2>/dev/null; do true; done

    success "IP 规则和路由清理完成。"
}

#================================================================================
# 配置核心读取与写入逻辑
#================================================================================
write_config_file() {
    local CONFIG_FILE="/etc/tun2socks/config.yaml"
    mkdir -p "/etc/tun2socks"

    local current_addr="" current_port="" current_user="" current_pass=""
    if [ -f "$CONFIG_FILE" ]; then
        current_addr=$(grep -E '^[[:space:]]*address:' "$CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
        current_port=$(grep -E '^[[:space:]]*port:' "$CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
        current_user=$(grep -E '^[[:space:]]*username:' "$CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
        current_pass=$(grep -E '^[[:space:]]*password:' "$CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
    fi

    # 1. 节点地址
    local input_addr
    while true; do
        if [ -n "$current_addr" ]; then
            read -r -p "请输入Socks5服务器地址 [$current_addr]: " input_addr
            [ -z "$input_addr" ] && input_addr=$current_addr
        else
            read -r -p "请输入Socks5服务器地址 (例如: 2001:db8::1): " input_addr
        fi
        if [ -n "$input_addr" ]; then break; else error "服务器地址不能为空。"; fi
    done

    # 2. 节点端口
    local input_port
    while true; do
        if [ -n "$current_port" ]; then
            read -r -p "请输入Socks5服务器端口 [$current_port]: " input_port
            [ -z "$input_port" ] && input_port=$current_port
        else
            read -r -p "请输入Socks5服务器端口 (1-65535): " input_port
        fi
        if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
            break
        else
            error "无效的端口号，请输入 1 到 65535 之间的数字。"
        fi
    done

    # 3. 用户名
    local input_user
    if [ -n "$current_user" ]; then
        read -r -p "请输入用户名 (留空或不改输入 $current_user, 清空请输入 none) [$current_user]: " input_user
        [ -z "$input_user" ] && input_user=$current_user
        [ "$input_user" = "none" ] && input_user=""
    else
        read -r -p "请输入用户名 (可选，留空则不使用): " input_user
    fi

    # 4. 密码
    local input_pass
    if [ -n "$input_user" ]; then
        if [ -n "$current_pass" ]; then
            read -r -p "请输入密码 (留空或不改输入 $current_pass, 清空请输入 none) [$current_pass]: " input_pass
            [ -z "$input_pass" ] && input_pass=$current_pass
            [ "$input_pass" = "none" ] && input_pass=""
        else
            read -r -p "请输入密码 (可选，留空则不使用): " input_pass
        fi
    else
        input_pass=""
    fi

    # 写入文件
    cat > "$CONFIG_FILE" <<EOF
tunnel:
  name: tun0
  mtu: 8500
  multi-queue: true
  ipv4: 198.18.0.1

socks5:
  port: $(echo "$input_port" | tr -d '\r')
  address: '$(echo "$input_addr" | tr -d '\r')'
  udp: 'udp'
$( [ -n "$input_user" ] && echo "  username: '$(echo "$input_user" | tr -d '\r')'" )
$( [ -n "$input_pass" ] && echo "  password: '$(echo "$input_pass" | tr -d '\r')'" )
  mark: 438
EOF
}

# 独立修改配置
change_config() {
    info "开始修改 Socks5 节点配置（直接回车则保持括号内的默认值不变）："
    echo "--------------------------------------------------------"
    write_config_file
    success "节点配置文件修改成功！"
    
    if systemctl is-active --quiet tun2socks.service; then
        step "检测到服务正在运行，正在重启服务以应用新配置..."
        systemctl restart tun2socks.service && success "重启成功，新配置已生效。" || error "重启失败，请检查服务状态。"
    fi
}

#================================================================================
# 独立功能：检查并更新 GitHub 上的核心二进制程序
#================================================================================
update_core_binary() {
    if [ ! -f "/usr/local/bin/tun2socks" ]; then
        error "检测到您尚未安装 Tun2Socks 环境，请先使用选项 1 进行完整安装！"
        return 1
    fi

    step "正在连接 GitHub 检查最新 Release 版本..."
    local latest_release_json=$(curl -s https://api.github.com/repos/$REPO/releases/latest)
    local latest_version=$(echo "$latest_release_json" | grep '"tag_name":' | cut -d '"' -f 4)
    local download_url=$(echo "$latest_release_json" | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)

    if [ -z "$latest_version" ] || [ -z "$download_url" ]; then
        error "无法从 GitHub 获取版本信息，请检查网络。"
        return 1
    fi

    # 获取本地当前核心的版本
    local local_version="未知"
    if /usr/local/bin/tun2socks -v &>/dev/null; then
        local_version=$(/usr/local/bin/tun2socks -v | head -n1 | awk '{print $3}')
    elif /usr/local/bin/tun2socks --version &>/dev/null; then
        local_version=$(/usr/local/bin/tun2socks --version | head -n1 | awk '{print $3}')
    fi

    info "本地核心版本: $local_version"
    info "GitHub最新版本: $latest_version"

    if [ "$local_version" = "$latest_version" ]; then
        success "当前核心程序已是 GitHub 最新版本，无需更新。"
        return 0
    fi

    warning "发现新版本核心程序 ($latest_version)。"
    read -r -p "是否现在升级核心程序？节点配置将保持不变。(y/N): " choice
    if [[ ! "$choice" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        info "已取消核心升级。"
        return 0
    fi

    # 开始执行更新流程
    local RESOLV_CONF="/etc/resolv.conf"
    local RESOLV_CONF_BAK="/etc/resolv.conf.bak"
    local was_immutable=false

    if lsattr -d "$RESOLV_CONF" 2>/dev/null | grep -q -- '-i-'; then
        chattr -i "$RESOLV_CONF" || true
        was_immutable=true
    fi
    cp "$RESOLV_CONF" "$RESOLV_CONF_BAK" || true

    if ! set_dns64_servers "$RESOLV_CONF" "$was_immutable" "$RESOLV_CONF_BAK"; then
        return 1
    fi

    local is_running=false
    if systemctl is-active --quiet tun2socks.service; then
        is_running=true
        step "正在暂停当前全局代理以准备替换核心..."
        systemctl stop tun2socks.service || true
    fi

    step "正在下载最新核心程序..."
    if curl -L -o "/usr/local/bin/tun2socks" "$download_url"; then
        chmod +x "/usr/local/bin/tun2socks"
        success "核心程序已成功更新到 $latest_version ！"
    else
        error "核心程序下载失败。"
    fi

    restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$was_immutable"

    if [ "$is_running" = true ]; then
        step "正在重新拉起全局代理..."
        systemctl start tun2socks.service && success "代理已重新启动！" || error "重启失败，请检查配置。"
    fi
}

#================================================================================
# 安装 Tun2Socks（全配置：包含环境、下载以及节点初始化输入）
#================================================================================
install_tun2socks() {
    cleanup_ip_rules

    step "检查 tun2socks 服务当前状态..."
    if systemctl is-active --quiet tun2socks.service; then
        info "tun2socks 服务正在运行，将在安装前停止它。"
        systemctl stop tun2socks.service || true
    fi

    RESOLV_CONF="/etc/resolv.conf"
    RESOLV_CONF_BAK="/etc/resolv.conf.bak"
    WAS_IMMUTABLE=false

    step "检查 /etc/resolv.conf 锁定状态..."
    if lsattr -d "$RESOLV_CONF" 2>/dev/null | grep -q -- '-i-'; then
        info "/etc/resolv.conf 文件当前被锁定，尝试解锁..."
        chattr -i "$RESOLV_CONF" || { error "无法解锁 /etc/resolv.conf"; exit 1; }
        WAS_IMMUTABLE=true
    fi

    step "备份当前 DNS 配置..."
    cp "$RESOLV_CONF" "$RESOLV_CONF_BAK" || true

    if ! set_dns64_servers "$RESOLV_CONF" "$WAS_IMMUTABLE" "$RESOLV_CONF_BAK"; then
        return 1
    fi

    INSTALL_DIR="/usr/local/bin"
    CONFIG_DIR="/etc/tun2socks"
    SERVICE_FILE="/etc/systemd/system/tun2socks.service"
    BINARY_PATH="$INSTALL_DIR/tun2socks"

    step "从 GitHub 获取最新 Release 版本下载链接..."
    DOWNLOAD_URL=$(curl -s https://api.github.com/repos/$REPO/releases/latest | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)

    if [ -z "$DOWNLOAD_URL" ]; then
        error "未找到适用于 linux-x86_64 的二进制文件下载链接，请检查网络。"
        restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
        return 1
    fi

    step "正在从 GitHub 下载最新核心二进制程序："
    info "$DOWNLOAD_URL"
    cleanup_on_fail() {
        trap - INT TERM EXIT
        restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
        return 1
    }
    trap cleanup_on_fail INT TERM EXIT
    curl -L -o "$BINARY_PATH" "$DOWNLOAD_URL"
    trap - INT TERM EXIT

    restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
    chmod +x "$BINARY_PATH"

    step "配置您的自定义 Socks5 出口节点信息："
    write_config_file

    step "生成并同步底层路由守护服务 (tun2socks.service)..."
    RULE_ADD_FROM_MAIN_IP=""
    RULE_DEL_FROM_MAIN_IP=""
    RULE_ADD_FROM_MAIN_IP6=""
    RULE_DEL_FROM_MAIN_IP6=""

    MAIN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    MAIN_IP6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')

    if [ -n "$MAIN_IP" ]; then
        RULE_ADD_FROM_MAIN_IP="ExecStartPost=/sbin/ip rule add from $MAIN_IP lookup main pref 15"
        RULE_DEL_FROM_MAIN_IP="ExecStop=/sbin/ip rule del from $MAIN_IP lookup main pref 15"
    fi
    if [ -n "$MAIN_IP6" ]; then
        RULE_ADD_FROM_MAIN_IP6="ExecStartPost=/sbin/ip -6 rule add from $MAIN_IP6 lookup main pref 15"
        RULE_DEL_FROM_MAIN_IP6="ExecStop=/sbin/ip -6 rule del from $MAIN_IP6 lookup main pref 15"
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Tun2Socks Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=$BINARY_PATH $CONFIG_DIR/config.yaml
ExecStartPost=/bin/sleep 1

# 【防断网策略】保障 22 端口流量直连不进虚拟网卡
ExecStartPost=/sbin/ip rule add to 0.0.0.0/0 dport 22 lookup main pref 5
ExecStartPost=/sbin/ip rule add to 0.0.0.0/0 sport 22 lookup main pref 5
ExecStartPost=/sbin/ip -6 rule add to ::/0 dport 22 lookup main pref 5
ExecStartPost=/sbin/ip -6 rule add to ::/0 sport 22 lookup main pref 5

ExecStartPost=/sbin/ip rule add fwmark 438 lookup main pref 10
ExecStartPost=/sbin/ip -6 rule add fwmark 438 lookup main pref 10
ExecStartPost=/sbin/ip route add default dev tun0 table 20
ExecStartPost=/sbin/ip rule add lookup 20 pref 20
${RULE_ADD_FROM_MAIN_IP}
${RULE_DEL_FROM_MAIN_IP6}
ExecStartPost=/sbin/ip rule add to 127.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 10.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 172.16.0.0/12 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 192.168.0.0/16 lookup main pref 16

ExecStop=-/sbin/ip rule del to 0.0.0.0/0 dport 22 lookup main pref 5
ExecStop=-/sbin/ip rule del to 0.0.0.0/0 sport 22 lookup main pref 5
ExecStop=-/sbin/ip -6 rule del to ::/0 dport 22 lookup main pref 5
ExecStop=-/sbin/ip -6 rule del to ::/0 sport 22 lookup main pref 5
ExecStop=/sbin/ip rule del fwmark 438 lookup main pref 10
ExecStop=/sbin/ip -6 rule del fwmark 438 lookup main pref 10
ExecStop=/sbin/ip route del default dev tun0 table 20
ExecStop=/sbin/ip rule del lookup 20 pref 20
${RULE_DEL_FROM_MAIN_IP}
${RULE_DEL_FROM_MAIN_IP6}
ExecStop=/sbin/ip rule del to 127.0.0.0/8 lookup main pref 16
ExecStop=/sbin/ip rule del to 10.0.0.0/8 lookup main pref 16
ExecStop=/sbin/ip rule del to 172.16.0.0/12 lookup main pref 16
ExecStop=/sbin/ip rule del to 192.168.0.0/16 lookup main pref 16

Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tun2socks.service 2>/dev/null
    
    step "正在自动拉起全局代理隧道..."
    systemctl start tun2socks.service
    
    success "Tun2Socks 环境及最新程序已全部一键安装并配置完毕！"
}

uninstall_tun2socks() {
    cleanup_ip_rules
    SERVICE_FILE="/etc/systemd/system/tun2socks.service"
    CONFIG_DIR="/etc/tun2socks"
    BINARY_PATH="/usr/local/bin/tun2socks"

    step "正在停止并禁用 tun2socks 服务..."
    if systemctl is-active --quiet tun2socks.service; then
        systemctl stop tun2socks.service
    fi
    systemctl disable tun2socks.service 2>/dev/null || true

    step "正在移除组件..."
    [ -f "$SERVICE_FILE" ] && rm -f "$SERVICE_FILE"
    [ -d "$CONFIG_DIR" ] && rm -rf "$CONFIG_DIR"
    [ -f "$BINARY_PATH" ] && rm -f "$BINARY_PATH"
    
    systemctl daemon-reload
    success "卸载完成。"
}

#================================================================================
# 面板辅助获取状态函数
#================================================================================
get_status() {
    if systemctl is-active --quiet tun2socks.service; then
        status_show="${GREEN}已启动 (运行中)${RESET}"
    else
        status_show="${RED}已停止 (未运行)${RESET}"
    fi

    if [ -f "/usr/local/bin/tun2socks" ]; then
        version_show="${YELLOW}已安装${RESET}"
    else
        version_show="${RED}未安装${RESET}"
    fi

    if [ -f "/etc/tun2socks/config.yaml" ]; then
        local port=$(grep -E '^[[:space:]]*port:' /etc/tun2socks/config.yaml | head -n1 | awk '{print $2}' | tr -d "'\"")
        local addr=$(grep -E '^[[:space:]]*address:' /etc/tun2socks/config.yaml | head -n1 | awk '{print $2}' | tr -d "'\"")
        port_show="${YELLOW}${addr}:${port}${RESET}"
    else
        port_show="${RED}无配置${RESET}"
    fi
}

test_exit_ip() {
    step "正在通过全局代理隧道查询落地出口 IP..."
    local ip_info=""
    ip_info=$(curl -s -m 8 --interface tun0 ipinfo.io 2>/dev/null || echo "")
    if [ -z "$ip_info" ]; then
        ip_info=$(curl -s -m 8 --interface tun0 https://ifconfig.me/all.json 2>/dev/null || echo "")
    fi

    if [ -n "$ip_info" ]; then
        echo -e "${GREEN}----------------------------------------${RESET}"
        echo "$ip_info"
        echo -e "${GREEN}----------------------------------------${RESET}"
        success "测试成功！隧道网络畅通。"
    else
        error "获取失败，可能自定义节点暂时不可用或隧道未就绪。"
    fi
}

#================================================================================
# 自定义主循环控制面板
#================================================================================
panel_menu() {
    require_root
    while true; do
        get_status
        clear
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}   Tun2Socks 独立自定义管理面板  ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}状态   :${RESET} $status_show"
        echo -e "${GREEN}核心   :${RESET} $version_show"
        echo -e "${GREEN}代理   :${RESET} $port_show"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1. 安装全部环境并配置节点 (GitHub最新版)${RESET}"
        echo -e "${GREEN} 2. 单独修改/配置出口节点 (智能读取旧配置)${RESET}"
        echo -e "${GREEN} 3. 卸载 Tun2Socks 环境${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 4. 启动 全局代理${RESET}"
        echo -e "${GREEN} 5. 停止 全局代理${RESET}"
        echo -e "${GREEN} 6. 重启 全局代理${RESET}"
        echo -e "${GREEN} 7. 查看 运行日志${RESET}"
        echo -e "${GREEN} 8. 检查并更新核心程序 (GitHub最新版)${RESET}"
        echo -e "${GREEN} 9. 测试 出口实际 IP${RESET}"
        echo -e "${GREEN} 0. 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"
        
        read -p $'\e[32m请输入数字: \e[0m' num
        case "$num" in
            1) install_tun2socks ;;
            2) change_config ;;
            3) uninstall_tun2socks ;;
            4)
                step "正在启动全局代理隧道..."
                if [ ! -f "/etc/tun2socks/config.yaml" ]; then
                    error "未发现节点配置文件，请先执行选项 1 或 2 进行配置！"
                else
                    systemctl start tun2socks.service && success "启动成功。" || error "启动失败。"
                fi
                ;;
            5)
                step "正在停止全局代理，网络正在复原..."
                systemctl stop tun2socks.service && success "停止成功。" || error "停止失败。"
                ;;
            6)
                step "正在重启核心服务..."
                systemctl restart tun2socks.service && success "重启成功。" || error "重启失败。"
                ;;
            7)
                step "加载最新 30 行隧道运行日志 (按 Q 键退出)："
                journalctl -u tun2socks.service -n 30 --no-pager || error "未捕获到日志。"
                ;;
            8) update_core_binary ;;
            9) test_exit_ip ;;
            0) info "脚本已安全退出。"; exit 0 ;;
            *) error "非法数字，请输入面板指示的数字！" ;;
        esac
        echo -e "\n${YELLOW}按任意键返回主菜单...${RESET}"
        read -n 1
    done
}

# 运行主菜单
panel_menu
