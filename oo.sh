#!/bin/bash
set -e

#================================================================================
# 常量和全局变量
#================================================================================
VERSION="1.2.0"

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

# 路径定义
CONFIG_DIR="/etc/tun2socks"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
SERVICE_FILE="/etc/systemd/system/tun2socks.service"
BINARY_PATH="/usr/local/bin/tun2socks"
REPO="heiher/hev-socks5-tunnel"

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
    if ping6 -c 2 -W 2 "$dns_server" &>/dev/null; then return 0; else return 1; fi
}

set_dns64_for_download() {
    local resolv_conf="/etc/resolv.conf"
    if lsattr -d "$resolv_conf" 2>/dev/null | grep -q -- '-i-'; then
        chattr -i "$resolv_conf" || true
    fi
    cp "$resolv_conf" "${resolv_conf}.bak" 2>/dev/null || true

    cat > "$resolv_conf" <<EOF
nameserver 2602:fc59:b0:9e::64
EOF
    if curl -s -m 5 https://github.com >/dev/null; then return 0; fi

    for dns_server in "${ALTERNATE_DNS64_SERVERS[@]}"; do
        if test_dns64_server "$dns_server"; then
            cat > "$resolv_conf" <<EOF
nameserver $dns_server
EOF
            if curl -s -m 5 https://github.com >/dev/null; then return 0; fi
        fi
    done
    return 1
}

restore_dns() {
    local resolv_conf="/etc/resolv.conf"
    if [ -f "${resolv_conf}.bak" ]; then
        mv "${resolv_conf}.bak" "$resolv_conf"
    fi
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
}

#================================================================================
# 状态获取
#================================================================================
get_status() {
    if systemctl is-active --quiet tun2socks.service; then
        status_show="${GREEN}已启动 (运行中)${RESET}"
    else
        status_show="${RED}已停止 (未运行)${RESET}"
    fi

    if [ -f "$BINARY_PATH" ]; then
        version_show="${YELLOW}已安装${RESET}"
    else
        version_show="${RED}未安装${RESET}"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        local port=$(grep -E '^[[:space:]]*port:' "$CONFIG_FILE" | awk '{print $2}' | tr -d "'\"")
        local addr=$(grep -E '^[[:space:]]*address:' "$CONFIG_FILE" | awk '{print $2}' | tr -d "'\"")
        port_show="${YELLOW}${addr}:${port}${RESET}"
    else
        port_show="${RED}无配置${RESET}"
    fi
}

#================================================================================
# 业务逻辑
#================================================================================
download_binary() {
    step "正在获取 Tun2Socks 最新下载链接..."
    local url=$(curl -s https://api.github.com/repos/$REPO/releases/latest | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)
    if [ -z "$url" ]; then
        warning "直接获取失败，尝试开启 DNS64 环境获取..."
        set_dns64_for_download || { error "无法访问 GitHub 获取下载链接。"; restore_dns; return 1; }
        url=$(curl -s https://api.github.com/repos/$REPO/releases/latest | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)
    fi

    if [ -z "$url" ]; then
        error "未能获取到有效的二进制文件链接。"
        restore_dns
        return 1
    fi

    step "开始下载最新二进制核心..."
    curl -L -o "$BINARY_PATH" "$url"
    chmod +x "$BINARY_PATH"
    restore_dns
    success "Tun2Socks 核心下载/更新完成。"
    return 0
}

install_tun2socks() {
    if [ -f "$BINARY_PATH" ]; then
        warning "Tun2Socks 已经安装，如需更新请使用选项 2。"
        return
    fi
    download_binary || return

    step "生成默认服务框架 (尚未配置节点)..."
    mkdir -p "$CONFIG_DIR"
    
    MAIN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "")
    MAIN_IP6=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | grep -oP 'src \K\S+' || echo "")
    
    RULE_ADD_4=""; RULE_DEL_4=""
    [ -n "$MAIN_IP" ] && RULE_ADD_4="ExecStartPost=/sbin/ip rule add from $MAIN_IP fwmark 438 lookup main pref 10"
    [ -n "$MAIN_IP" ] && RULE_DEL_4="ExecStopPost=-/sbin/ip rule del from $MAIN_IP fwmark 438 lookup main pref 10"
    
    RULE_ADD_6=""; RULE_DEL_6=""
    [ -n "$MAIN_IP6" ] && RULE_ADD_6="ExecStartPost=/sbin/ip -6 rule add from $MAIN_IP6 fwmark 438 lookup main pref 10"
    [ -n "$MAIN_IP6" ] && RULE_DEL_6="ExecStopPost=-/sbin/ip -6 rule del from $MAIN_IP6 fwmark 438 lookup main pref 10"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=tun2socks Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$BINARY_PATH $CONFIG_FILE
Restart=always
RestartSec=5

ExecStartPost=/sbin/ip link set dev tun0 up
ExecStartPost=/sbin/ip addr add 198.18.0.1/15 dev tun0
ExecStartPost=/sbin/ip route add default dev tun0 table 20
ExecStartPost=/sbin/ip rule add lookup 20 pref 20
ExecStartPost=/sbin/ip rule add to 127.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 10.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 172.16.0.0/12 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 192.168.0.0/16 lookup main pref 16
$RULE_ADD_4
$RULE_ADD_6

ExecStopPost=-/sbin/ip route del default dev tun0 table 20
ExecStopPost=-/sbin/ip rule del lookup 20 pref 20
ExecStopPost=-/sbin/ip rule del to 127.0.0.0/8 lookup main pref 16
ExecStopPost=-/sbin/ip rule del to 10.0.0.0/8 lookup main pref 16
ExecStopPost=-/sbin/ip rule del to 172.16.0.0/12 lookup main pref 16
ExecStopPost=-/sbin/ip rule del to 192.168.0.0/16 lookup main pref 16
$RULE_DEL_4
$RULE_DEL_6

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    success "基础环境安装完成。请继续选择选项 4 填入 Socks5 配置并启动。"
}

modify_config() {
    if [ ! -f "$BINARY_PATH" ]; then
        error "请先选择选项 1 安装 Tun2Socks 基础环境！"
        return
    fi

    local address port username password
    {
        IFS= read -r SOCKS_ADDRESS; IFS= read -r SOCKS_PORT
        IFS= read -r SOCKS_USERNAME; IFS= read -r SOCKS_PASSWORD
        SOCKS_ADDRESS=$(echo "$SOCKS_ADDRESS" | tr -d '\r')
        SOCKS_PORT=$(echo "$SOCKS_PORT" | tr -d '\r')
        SOCKS_USERNAME=$(echo "$SOCKS_USERNAME" | tr -d '\r')
        SOCKS_PASSWORD=$(echo "$SOCKS_PASSWORD" | tr -d '\r')

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
    } < <(
        echo -e "${CYAN}--- 修改 Socks5 出口配置 ---${NC}" >&2
        while true; do
            read -r -p "请输入Socks5服务器地址 (IP或域名): " address
            [ -n "$address" ] && break || error "地址不能为空。" >&2
        done
        while true; do
            read -r -p "请输入Socks5服务器端口: " port
            [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break || error "请输入正确的端口(1-65535)。" >&2
        done
        read -r -p "请输入用户名 (可选，直接回车代表无验证): " username
        if [ -n "$username" ]; then
            read -r -p "请输入密码 (可选): " password
        else
            password=""
        fi
        echo "$address"; echo "$port"; echo "$username"; echo "$password"
    )

    success "配置文件更新成功。"
    if systemctl is-active --quiet tun2socks.service; then
        step "检测到服务正在运行，正在重启以应用新配置..."
        systemctl restart tun2socks.service && success "重启成功！" || error "重启失败。"
    fi
}

update_binary() {
    if [ ! -f "$BINARY_PATH" ]; then
        error "Tun2Socks 未安装，无法执行升级。请先选择选项 1。"
        return
    fi
    step "正在尝试升级 Tun2Socks 核心程序..."
    local running=false
    systemctl is-active --quiet tun2socks.service && running=true
    
    if [ "$running" = true ]; then
        systemctl stop tun2socks.service
    fi

    if download_binary; then
        success "Tun2Socks 核心程序升级成功。"
    else
        error "升级失败，核心未变动。"
    fi

    if [ "$running" = true ]; then
        systemctl start tun2socks.service && info "已重新拉起全局代理服务。"
    fi
}

uninstall_tun2socks() {
    step "正在安全卸载服务..."
    systemctl stop tun2socks.service 2>/dev/null || true
    systemctl disable tun2socks.service 2>/dev/null || true
    cleanup_ip_rules
    rm -f "$SERVICE_FILE"
    rm -rf "$CONFIG_DIR"
    rm -f "$BINARY_PATH"
    systemctl daemon-reload
    success "卸载完成，所有网络策略和核心已干净移除。"
}

test_exit_ip() {
    step "正在绕过本地网卡，通过 tun0 出口测试实际公网 IP..."
    
    # 使用 curl 的 --interface 参数强制指定从 tun0 出口请求
    local ip_info=$(curl -s -m 8 --interface tun0 ipinfo.io 2>/dev/null || echo "")
    
    if [ -z "$ip_info" ]; then
        # 备选接口
        ip_info=$(curl -s -m 8 --interface tun0 https://ifconfig.me/all.json 2>/dev/null || echo "")
    fi

    if [ -n "$ip_info" ]; then
        echo -e "${GREEN}----------------------------------------${RESET}"
        echo -e "${GREEN}当前 Tun2Socks 出口网络环境：${RESET}"
        echo "$ip_info" | grep -E '"(ip|ip_addr|country|region|city|org)"' || echo "$ip_info"
        echo -e "${GREEN}----------------------------------------${RESET}"
        success "测试完毕，出口全局代理工作正常。"
    else
        error "测试失败！未能通过 tun0 接口获取到外网数据，请检查 Socks5 节点是否可用或服务是否正常开启。"
    fi
}

#================================================================================
# 主循环菜单面板
#================================================================================
require_root

while true; do
    get_status
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}       Tun2Socks 管理面板       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status_show"
    echo -e "${GREEN}核心   :${RESET} $version_show"
    echo -e "${GREEN}代理   :${RESET} $port_show"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 Tun2Socks${RESET}"
    echo -e "${GREEN} 2. 更新 Tun2Socks${RESET}"
    echo -e "${GREEN} 3. 卸载 Tun2Socks${RESET}"
    echo -e "${GREEN} 4. 修改 Socks5配置${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 5. 启动 全局代理${RESET}"
    echo -e "${GREEN} 6. 停止 全局代理${RESET}"
    echo -e "${GREEN} 7. 重启 全局代理${RESET}"
    echo -e "${GREEN} 8. 查看 运行日志${RESET}"
    echo -e "${GREEN} 9. 测试 出口实际 IP${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    
    read -p $'\e[32m请输入数字: \e[0m' num
    case "$num" in
        1) install_tun2socks ;;
        2) update_binary ;;
        3) uninstall_tun2socks ;;
        4) modify_config ;;
        5)
            step "正在建立隧道..."
            if [ ! -f "$CONFIG_FILE" ]; then
                error "未发现节点配置，请先执行选项 4 填入 Socks5 配置！"
            else
                systemctl start tun2socks.service && success "服务已成功拉起，网络已接管。" || error "启动失败。"
            fi
            ;;
        6)
            step "正在回收网络策略并停止核心..."
            systemctl stop tun2socks.service && success "服务已停止，网络已还原。" || error "停止失败。"
            ;;
        7)
            step "正在重启服务..."
            systemctl restart tun2socks.service && success "重启成功。" || error "重启失败。"
            ;;
        8)
            step "最新 30 行服务运行日志 (按 Q 键退出)："
            journalctl -u tun2socks.service -n 30 --no-pager || error "暂无日志。"
            ;;
        9) test_exit_ip ;;
        0) exit 0 ;;
        *) error "输入错误，请输入 0-9 之间的数字！" ;;
    esac
    echo -e "\n${YELLOW}按任意键返回主菜单...${RESET}"
    read -n 1
done
