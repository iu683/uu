#!/bin/bash
set -e

#================================================================================
# 常量和全局变量
#================================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' 

CONFIG_FILE="/etc/tun2socks/config.yaml"
SERVICE_FILE="/etc/systemd/system/tun2socks.service"
BINARY_PATH="/usr/local/bin/tun2socks"

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
    success "IP 规则和路由清理完成。"
}

#================================================================================
# 核心逻辑函数
#================================================================================

# 自动读取并修改配置的函数
modify_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        error "配置文件未找到 ($CONFIG_FILE)，请先选择 1 安装。"
        return 1
    fi

    step "正在读取当前配置..."
    # 提取当前配置，去除单引号和前后空格
    local current_address=$(grep -oP '^\s*address:\s*'\''?\K[^'\''\s]+' "$CONFIG_FILE" | head -n 1)
    local current_port=$(grep -oP '^\s*port:\s*\K[0-9]+' "$CONFIG_FILE" | head -n 1)
    local current_username=$(grep -oP '^\s*username:\s*'\''?\K[^'\''\s]+' "$CONFIG_FILE" | head -n 1)
    local current_password=$(grep -oP '^\s*password:\s*'\''?\K[^'\''\s]+' "$CONFIG_FILE" | head -n 1)

    echo -e "${CYAN}------------------------------------------------${NC}"
    echo -e "提示: 直接按 ${YELLOW}回车 (Enter)${NC} 将保持当前默认值"
    echo -e "${CYAN}------------------------------------------------${NC}"

    # 1. 服务器地址
    local address
    read -r -p "Socks5 服务器地址 [$current_address]: " address
    [ -z "$address" ] && address=$current_address

    # 2. 服务器端口
    local port
    while true; do
        read -r -p "Socks5 服务器端口 [$current_port]: " port
        [ -z "$port" ] && port=$current_port
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            break
        else
            error "无效的端口号，请输入 1 到 65535 之间的数字。"
        fi
    done

    # 3. 用户名
    local username
    read -r -p "Socks5 用户名 (可选) [$current_username]: " username
    [ -z "$username" ] && username=$current_username

    # 4. 密码
    local password
    read -r -p "Socks5 密码 (可选) [$current_password]: " password
    [ -z "$password" ] && password=$current_password

    step "正在停止 tun2socks 服务以应用新配置..."
    systemctl stop tun2socks.service 2>/dev/null || true

    # 重新写入配置文件
    cat > "$CONFIG_FILE" <<EOF
tunnel:
  name: tun0
  mtu: 8500
  multi-queue: true
  ipv4: 198.18.0.1

socks5:
  port: $port
  address: '$address'
  udp: 'udp'
$( [ -n "$username" ] && echo "  username: '$username'" )
$( [ -n "$password" ] && echo "  password: '$password'" )
  mark: 438
EOF

    step "正在重启 tun2socks 服务..."
    systemctl start tun2socks.service
    success "配置修改成功并已应用！"
}

uninstall_tun2socks() {
    cleanup_ip_rules
    step "正在停止并禁用 tun2socks 服务..."
    systemctl stop tun2socks.service 2>/dev/null || true
    systemctl disable tun2socks.service 2>/dev/null || true

    step "正在移除相关文件..."
    rm -f "$SERVICE_FILE"
    rm -rf "/etc/tun2socks"
    rm -f "$BINARY_PATH"
    systemctl daemon-reload
    systemctl reset-failed tun2socks.service &>/dev/null || true
    success "卸载完成。"
}

install_tun2socks() {
    if [ -f "$BINARY_PATH" ]; then
        warning "检测到已经安装过 tun2socks。"
        read -r -p "是否覆盖安装？(y/N): " re_inst
        if [[ ! "$re_inst" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            info "已取消安装。"
            return 0
        fi
    fi

    cleanup_ip_rules
    systemctl stop tun2socks.service 2>/dev/null || true

    # 创建必要的目录
    mkdir -p "/etc/tun2socks"
    
    # 伪造一个空配置，以便 modify_config 可以顺利读取并写入
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
tunnel:
  name: tun0
socks5:
  port: 1080
  address: '127.0.0.1'
EOF
    fi

    # 直接引导用户配置节点数据
    modify_config

    # 获取系统主网卡IP，生成静态路由
    MAIN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    MAIN_IP6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    [ -n "$MAIN_IP" ] && RULE_ADD_V4="ExecStartPost=/sbin/ip rule add from $MAIN_IP lookup main pref 15" && RULE_DEL_V4="ExecStop=/sbin/ip rule del from $MAIN_IP lookup main pref 15"
    [ -n "$MAIN_IP6" ] && RULE_ADD_V6="ExecStartPost=/sbin/ip -6 rule add from $MAIN_IP6 lookup main pref 15" && RULE_DEL_V6="ExecStop=/sbin/ip -6 rule del from $MAIN_IP6 lookup main pref 15"

    step "生成 systemd 服务文件..."
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
${RULE_ADD_V4}
${RULE_ADD_V6}
ExecStartPost=/sbin/ip rule add to 127.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 10.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 172.16.0.0/12 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 192.168.0.0/16 lookup main pref 16

ExecStop=/sbin/ip rule del fwmark 438 lookup main pref 10
ExecStop=/sbin/ip -6 rule del fwmark 438 lookup main pref 10
ExecStop=/sbin/ip route del default dev tun0 table 20
ExecStop=/sbin/ip rule del lookup 20 pref 20
${RULE_DEL_V4}
${RULE_DEL_V6}
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
    success "tun2socks 安装且启动成功！"
}

#================================================================================
# 交互式面板渲染
#================================================================================
show_menu() {
    clear
    # 1. 动态获取状态
    if systemctl is-active --quiet tun2socks.service; then
        status_line="${GREEN}正在运行${NC}"
    else
        status_line="${RED}未运行${NC}"
    fi

    # 2. 动态获取配置
    if [ -f "$CONFIG_FILE" ]; then
        bind=$(grep -oP '^\s*address:\s*'\''?\K[^'\''\s]+' "$CONFIG_FILE" | head -n 1)
        port=$(grep -oP '^\s*port:\s*\K[0-9]+' "$CONFIG_FILE" | head -n 1)
        mode_val=$(grep -oP '^\s*name:\s*\K\w+' "$CONFIG_FILE" | head -n 1)
        [ -z "$mode_val" ] && mode_val="tun0"
    else
        bind="None"
        port="None"
        mode_val="None"
    fi

    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}       tun2socks 管理面板        ${NC}"
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}状态   :${NC} ${status_line}"
    echo -e "${GREEN}模式   :${NC} ${YELLOW}$mode_val${NC}"
    echo -e "${GREEN}监听   :${NC} ${YELLOW}${bind}:${port}${NC}"
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN} 1. 安装 tun2socks${NC}"
    echo -e "${GREEN} 2. 修改配置${NC}"
    echo -e "${GREEN} 3. 卸载 tun2socks${NC}"
    echo -e "${GREEN} 4. 启动 tun2socks${NC}"
    echo -e "${GREEN} 5. 停止 tun2socks${NC}"
    echo -e "${GREEN} 6. 重启 tun2socks${NC}"
    echo -e "${GREEN} 7. 查看服务日志${NC}"
    echo -e "${GREEN} 0. 退出${NC}"
    echo -e "${GREEN}================================${NC}"
}

#================================================================================
# 主循环逻辑
#================================================================================
main() {
    require_root
    
    while true; do
        show_menu
        read -r -p "请选择操作 [0-7]: " choice
        case "$choice" in
            1)
                install_tun2socks
                ;;
            2)
                modify_config
                ;;
            3)
                uninstall_tun2socks
                ;;
            4)
                step "正在启动服务..."
                systemctl start tun2socks.service && success "启动成功。" || error "启动失败。"
                ;;
            5)
                step "正在停止服务..."
                systemctl stop tun2socks.service && success "停止成功。" || error "停止失败。"
                ;;
            6)
                step "正在重启服务..."
                systemctl restart tun2socks.service && success "重启成功。" || error "重启失败。"
                ;;
            7)
                step "显示最近20条服务日志 (按 q 退出)："
                journalctl -u tun2socks.service -n 20 --no-pager
                ;;
            0)
                exit 0
                ;;
            *)
                error "无效选项，请重新输入。"
                ;;
        esac
        echo
        read -r -p "按回车键返回主菜单..."
    done
}

# 脚本入口点
main "$@"
