#!/bin/bash
set -e

#================================================================================
# 常量和全局变量
#================================================================================
REPO="heiher/hev-socks5-tunnel"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 备用 DNS64 服务器
ALTERNATE_DNS64_SERVERS=(
    "2a00:1098:2b::1"
    "2a01:4f8:c2c:123f::1"
    "2a01:4f9:c010:3f02::1"
    "2001:67c:2b0::4"
    "2001:67c:2b0::6"
)

RESOLV_CONF="/etc/resolv.conf"
RESOLV_CONF_BAK="/etc/resolv.conf.bak"
WAS_IMMUTABLE=false
BINARY_PATH="/usr/local/bin/tun2socks"
CONFIG_DIR="/etc/tun2socks"
CONFIG_FILE="$CONFIG_DIR/config.yaml"

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

unlock_resolv_conf() {
    if lsattr -d "$RESOLV_CONF" 2>/dev/null | grep -q -- '-i-'; then
        info "/etc/resolv.conf 当前被锁定 (immutable)，正在尝试解锁..."
        chattr -i "$RESOLV_CONF" || { error "无法解锁 /etc/resolv.conf"; exit 1; }
        WAS_IMMUTABLE=true
        success "解锁成功。"
    fi
}

lock_resolv_conf() {
    if [ "$WAS_IMMUTABLE" = true ]; then
        info "重新锁定 /etc/resolv.conf..."
        chattr +i "$RESOLV_CONF" || warning "无法重新锁定 /etc/resolv.conf。"
        success "锁定完成。"
    fi
}

restore_dns_config() {
    unlock_resolv_conf
    if [ -f "$RESOLV_CONF_BAK" ]; then
        mv "$RESOLV_CONF_BAK" "$RESOLV_CONF"
        success "DNS 配置已恢复原状。"
        lock_resolv_conf
    fi
}

set_dns64_servers() {
    unlock_resolv_conf
    if [ ! -f "$RESOLV_CONF_BAK" ] && [ -f "$RESOLV_CONF" ]; then
        cp "$RESOLV_CONF" "$RESOLV_CONF_BAK"
    fi

    cat > "$RESOLV_CONF" <<EOF
nameserver 2602:fc59:b0:9e::64
EOF
    
    if test_github_access; then return 0; fi
    
    for dns_server in "${ALTERNATE_DNS64_SERVERS[@]}"; do
        if test_dns64_server "$dns_server"; then
            cat > "$RESOLV_CONF" <<EOF
nameserver $dns_server
EOF
            if test_github_access; then return 0; fi
        fi
    done
    
    error "所有 DNS64 服务器均无法访问 GitHub。"
    restore_dns_config
    return 1
}

# 读取现有配置作为默认值，支持回车不改变
get_custom_server_config() {
    local default_address="" default_port="" default_user="" default_pass=""
    
    # 尝试从现有配置文件中读取数据
    if [ -f "$CONFIG_FILE" ]; then
        default_address=$(grep -oP "address:\s*'\K[^']+" "$CONFIG_FILE" || grep -oP "address:\s*\K[^\s]+" "$CONFIG_FILE" || echo "")
        default_port=$(grep -oP "port:\s*\K[0-9]+" "$CONFIG_FILE" | tail -n 1 || echo "")
        default_user=$(grep -oP "username:\s*'\K[^']+" "$CONFIG_FILE" || grep -oP "username:\s*\K[^\s]+" "$CONFIG_FILE" || echo "")
        default_pass=$(grep -oP "password:\s*'\K[^']+" "$CONFIG_FILE" || grep -oP "password:\s*\K[^\s]+" "$CONFIG_FILE" || echo "")
    fi

    local address port username password
    echo -e "${YELLOW}--- Socks5 出口配置（回车默认不修改） ---${NC}"
    
    # 1. 地址
    while true; do
        if [ -n "$default_address" ]; then
            read -r -p "请输入Socks5服务器地址 [$default_address]: " address
            [ -z "$address" ] && address="$default_address"
        else
            read -r -p "请输入Socks5服务器地址: " address
        fi
        [ -n "$address" ] && break || error "服务器地址不能为空。"
    done

    # 2. 端口
    while true; do
        if [ -n "$default_port" ]; then
            read -r -p "请输入Socks5服务器端口 [$default_port]: " port
            [ -z "$port" ] && port="$default_port"
        else
            read -r -p "请输入Socks5服务器端口: " port
        fi
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then break;
        else error "请输入 1 到 65535 之间的有效数字。"; fi
    done

    # 3. 用户名
    if [ -n "$default_user" ]; then
        read -r -p "请输入用户名 (留空即删除) [$default_user]: " username
        # 如果直接敲回车，保留原用户名；如果输入空格或特定清除符可以按需，这里回车代表保持不变
        # 注意：为了允许用户从“有账号”改成“无账号”，我们规定如果输入 "clear" 则变为空，直接回车是不变
        if [ -z "$username" ]; then
            username="$default_user"
        elif [ "$username" = "clear" ]; then
            username=""
        fi
    else
        read -r -p "请输入用户名 (可选，无则直接回车): " username
    fi

    # 4. 密码
    if [ -n "$username" ]; then
        if [ -n "$default_pass" ]; then
            read -r -p "请输入密码 (留空保持原样) [$default_pass]: " password
            [ -z "$password" ] && password="$default_pass"
        else
            read -r -p "请输入密码 (可选，无则直接回车): " password
        fi
    else
        password=""
    fi

    echo "$address|$port|$username|$password"
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

    while ip rule del pref 15 2>/dev/null; do :; done
    while ip -6 rule del pref 15 2>/dev/null; do :; done
    success "路由规则清理完成。"
}

#================================================================================
# 核心动作
#================================================================================

download_core() {
    set_dns64_servers || { error "网络初始化失败，无法连接外网下载核心"; return 1; }
    
    step "从 GitHub 获取最新的 tun2socks 核心下载链接..."
    local url
    url=$(curl -s https://api.github.com/repos/$REPO/releases/latest | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)
    
    if [ -z "$url" ]; then
        error "未能获取下载链接，请检查网络。"
        restore_dns_config
        return 1
    fi

    step "正在下载最新核心程序..."
    if ! curl -L -o "$BINARY_PATH" "$url"; then
        error "核心程序下载失败。"
        restore_dns_config
        return 1
    fi

    chmod +x "$BINARY_PATH"
    restore_dns_config
    return 0
}

install_tun2socks() {
    cleanup_ip_rules
    if systemctl is-active --quiet tun2socks.service; then
        systemctl stop tun2socks.service
    fi

    download_core || return

    SERVICE_FILE="/etc/systemd/system/tun2socks.service"

    local config_data
    config_data=$(get_custom_server_config)
    IFS='|' read -r SOCKS_ADDRESS SOCKS_PORT SOCKS_USERNAME SOCKS_PASSWORD <<< "$config_data"

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
tunnel:
  name: tun0
  mtu: 8500
  multi-queue: true
  ipv4: 198.18.0.1

socks5:
  port: $SOCKS_PORT
  address: '$SOCKS_ADDRESS'
  udp: 'udp'
$( [ -n "$SOCKS_USERNAME" ] && echo "  username: '$SOCKS_USERNAME'" )
$( [ -n "$SOCKS_PASSWORD" ] && echo "  password: '$SOCKS_PASSWORD'" )
  mark: 438
EOF

    MAIN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}') || ""
    MAIN_IP6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}') || ""

    RULE_ADD_4=""; RULE_DEL_4=""
    RULE_ADD_6=""; RULE_DEL_6=""
    [ -n "$MAIN_IP" ] && RULE_ADD_4="ExecStartPost=/sbin/ip rule add from $MAIN_IP lookup main pref 15" && RULE_DEL_4="ExecStop=/sbin/ip rule del from $MAIN_IP lookup main pref 15"
    [ -n "$MAIN_IP6" ] && RULE_ADD_6="ExecStartPost=/sbin/ip -6 rule add from $MAIN_IP6 lookup main pref 15" && RULE_DEL_6="ExecStop=/sbin/ip -6 rule del from $MAIN_IP6 lookup main pref 15"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Tun2Socks Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=$BINARY_PATH $CONFIG_FILE
ExecStartPost=/bin/sleep 1
ExecStartPost=/sbin/ip rule add fwmark 438 lookup main pref 10
ExecStartPost=/sbin/ip -6 rule add fwmark 438 lookup main pref 10
ExecStartPost=/sbin/ip route add default dev tun0 table 20
ExecStartPost=/sbin/ip rule add lookup 20 pref 20
$RULE_ADD_4
$RULE_ADD_6
ExecStartPost=/sbin/ip rule add to 127.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 10.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 172.16.0.0/12 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 192.168.0.0/16 lookup main pref 16

ExecStop=/sbin/ip rule del fwmark 438 lookup main pref 10
ExecStop=/sbin/ip -6 rule del fwmark 438 lookup main pref 10
ExecStop=/sbin/ip route del default dev tun0 table 20
ExecStop=/sbin/ip rule del lookup 20 pref 20
$RULE_DEL_4
$RULE_DEL_6
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
    systemctl start tun2socks.service
    success "Tun2socks 安装并启动成功！"
}

update_core_binary() {
    if [ ! -f "$BINARY_PATH" ]; then
        error "未检测到系统已安装 Tun2Socks 核心，请先选择选项 1 进行安装。"
        return
    fi
    
    local is_running=false
    if systemctl is-active --quiet tun2socks.service; then
        is_running=true
        step "正在暂时停止服务以进行核心升级..."
        systemctl stop tun2socks.service
    fi

    if download_core; then
        success "Tun2Socks 核心二进制文件已成功升级到最新版本！"
    else
        error "核心升级失败。"
    fi

    if [ "$is_running" = true ]; then
        step "正在重新启动 Tun2Socks 服务..."
        systemctl start tun2socks.service
        success "服务已重新拉起。"
    fi
}

uninstall_tun2socks() {
    cleanup_ip_rules
    if systemctl is-active --quiet tun2socks.service; then systemctl stop tun2socks.service; fi
    systemctl disable tun2socks.service 2>/dev/null || true
    rm -f /etc/systemd/system/tun2socks.service
    rm -rf "$CONFIG_DIR"
    rm -f "$BINARY_PATH"
    systemctl daemon-reload
    success "卸载完成。"
}

modify_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        error "配置文件不存在，请先选择 1 进行安装。"
        return
    fi
    
    local config_data
    config_data=$(get_custom_server_config)
    IFS='|' read -r SOCKS_ADDRESS SOCKS_PORT SOCKS_USERNAME SOCKS_PASSWORD <<< "$config_data"

    cat > "$CONFIG_FILE" <<EOF
tunnel:
  name: tun0
  mtu: 8500
  multi-queue: true
  ipv4: 198.18.0.1

socks5:
  port: $SOCKS_PORT
  address: '$SOCKS_ADDRESS'
  udp: 'udp'
$( [ -n "$SOCKS_USERNAME" ] && echo "  username: '$SOCKS_USERNAME'" )
$( [ -n "$SOCKS_PASSWORD" ] && echo "  password: '$SOCKS_PASSWORD'" )
  mark: 438
EOF
    success "配置修改成功。"
    if systemctl is-active --quiet tun2socks.service; then
        step "正在重启服务以应用新配置..."
        systemctl restart tun2socks.service
        success "服务已重启并生效。"
    fi
}

test_dns_resolution() {
    step "测试全局代理下的双栈 DNS 解析状态..."
    echo -n "IPv4 解析测试 (www.google.com): "
    if curl -4s --connect-timeout 5 https://www.google.com >/dev/null; then echo -e "${GREEN}正常${NC}"; else echo -e "${RED}失败${NC}"; fi
    echo -n "IPv6 解析测试 (www.google.com): "
    if curl -6s --connect-timeout 5 https://www.google.com >/dev/null; then echo -e "${GREEN}正常${NC}"; else echo -e "${RED}失败${NC}"; fi
}

#================================================================================
# 主循环菜单界面
#================================================================================
main_menu() {
    while true; do
        if systemctl is-active --quiet tun2socks.service; then
            status="${GREEN}运行中${NC}"
        else
            status="${RED}未运行${NC}"
        fi

        if [ -f "$CONFIG_FILE" ]; then
            port_show=$(grep -oP 'port:\s*\K[0-9]+' "$CONFIG_FILE" | head -n 1)
            port_show="${YELLOW}${port_show}${NC}"
        else
            port_show="${RED}未配置${NC}"
        fi

        local core_version="未知"
        if [ -f "$BINARY_PATH" ]; then
            core_version=$("$BINARY_PATH" -v 2>&1 | head -n 1 | awk '{print $3}')
            [ -z "$core_version" ] && core_version="已安装"
        fi

        echo -e "${GREEN}================================${NC}"
        echo -e "${GREEN}      Tun2Socks 管理面板        ${NC}"
        echo -e "${GREEN}================================${NC}"
        echo -e "${GREEN}状态   :${NC} $status"
        echo -e "${GREEN}版本   :${NC} ${YELLOW}${core_version}${NC}"
        echo -e "${GREEN}端口   :${NC} ${port_show}"
        echo -e "${GREEN}================================${NC}"
        echo -e "${GREEN} 1. 安装 Tun2Socks 核心与配置${NC}"
        echo -e "${GREEN} 2. 更新 Tun2Socks 核心程序${NC}"
        echo -e "${GREEN} 3. 卸载 Tun2Socks 及其服务${NC}"
        echo -e "${GREEN} 4. 修改出口 Socks5 配置${NC}"
        echo -e "${GREEN} 5. 启动 Tun2Socks 服务${NC}"
        echo -e "${GREEN} 6. 停止 Tun2Socks 服务${NC}"
        echo -e "${GREEN} 7. 重启 Tun2Socks 服务${NC}"
        echo -e "${GREEN} 8. 查看服务运行日志${NC}"
        echo -e "${GREEN} 9. 测试代理与 DNS 连通性${NC}"
        echo -e "${GREEN} 0. 退出管理面板${NC}"
        echo -e "${GREEN}================================${NC}"
        
        read -p $'\e[32m请输入数字: \e[0m' num
        case "$num" in
            1) install_tun2socks ;;
            2) update_core_binary ;;
            3) uninstall_tun2socks ;;
            4) modify_config ;;
            5) systemctl start tun2socks.service && success "服务已启动。" ;;
            6) systemctl stop tun2socks.service && success "服务已停止。" ;;
            7) systemctl restart tun2socks.service && success "服务已重启。" ;;
            8) journalctl -u tun2socks.service -n 50 --no-pager ;;
            9) test_dns_resolution ;;
            0) exit 0 ;;
            *) error "无效输入，请输入正确的数字！" ; sleep 1 ;;
        esac
        echo
        read -n 1 -s -r -p "按任意键返回主菜单..."
        clear
    done
}

# 脚本入口
require_root
clear
main_menu
