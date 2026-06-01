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

# 备用 DNS64 服务器（用于纯 IPv6 环境下代理/解析 GitHub）
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

# 生成或更新 Systemd 服务脚本
generate_service_file() {
    local MAIN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    local MAIN_IP6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    local RULE_ADD_V4="" RULE_DEL_V4="" RULE_ADD_V6="" RULE_DEL_V6=""
    
    [ -n "$MAIN_IP" ] && RULE_ADD_V4="ExecStartPost=/sbin/ip rule add from $MAIN_IP lookup main pref 15" && RULE_DEL_V4="ExecStop=/sbin/ip rule del from $MAIN_IP lookup main pref 15"
    [ -n "$MAIN_IP6" ] && RULE_ADD_V6="ExecStartPost=/sbin/ip -6 rule add from $MAIN_IP6 lookup main pref 15" && RULE_DEL_V6="ExecStop=/sbin/ip -6 rule del from $MAIN_IP6 lookup main pref 15"

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
}

# 自动读取并修改配置
modify_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        error "配置文件未找到 ($CONFIG_FILE)，请先选择 1 安装。"
        return 1
    fi

    step "正在读取当前配置..."
    local current_address=$(grep -oP '^\s*address:\s*'\''?\K[^'\''\s]+' "$CONFIG_FILE" | head -n 1)
    local current_port=$(grep -oP '^\s*port:\s*\K[0-9]+' "$CONFIG_FILE" | head -n 1)
    local current_username=$(grep -oP '^\s*username:\s*'\''?\K[^'\''\s]+' "$CONFIG_FILE" | head -n 1)
    local current_password=$(grep -oP '^\s*password:\s*'\''?\K[^'\''\s]+' "$CONFIG_FILE" | head -n 1)

    echo -e "${CYAN}------------------------------------------------${NC}"
    echo -e "提示: 直接按 ${YELLOW}回车 (Enter)${NC} 将保持当前默认值"
    echo -e "${CYAN}------------------------------------------------${NC}"

    local address
    read -r -p "Socks5 服务器地址 [$current_address]: " address
    [ -z "$address" ] && address=$current_address

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

    local username
    read -r -p "Socks5 用户名 (可选) [$current_username]: " username
    [ -z "$username" ] && username=$current_username

    local password
    read -r -p "Socks5 密码 (可选) [$current_password]: " password
    [ -z "$password" ] && password=$current_password

    # 如果服务存在，先停止
    if [ -f "$SERVICE_FILE" ]; then
        systemctl stop tun2socks.service 2>/dev/null || true
    fi

    # 写入配置
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

    # 如果服务文件存在，顺便重启服务
    if [ -f "$SERVICE_FILE" ]; then
        step "正在重启 tun2socks 服务..."
        systemctl restart tun2socks.service 2>/dev/null || systemctl start tun2socks.service
        success "配置修改成功并已应用！"
    fi
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
    if [ -f "$BINARY_PATH" ] && [ -f "$SERVICE_FILE" ]; then
        warning "检测到已经安装过 tun2socks。"
        read -r -p "是否覆盖安装？(y/N): " re_inst
        if [[ ! "$re_inst" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            info "已取消安装。"
            return 0
        fi
    fi

    cleanup_ip_rules
    
    # 1. 下载核心二进制文件
    step "正在获取 tun2socks 最新内核..."
    mkdir -p "/etc/tun2socks"
    local REPO="heiher/hev-socks5-tunnel"
    local DOWNLOAD_URL=""
    
    # 尝试直接通过常规网络获取
    DOWNLOAD_URL=$(curl -s --connect-timeout 5 https://api.github.com/repos/$REPO/releases/latest | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)
    
    # 如果常规网络失败（纯 v6 环境无法直接请求 GitHub v4 地址），切换 DNS64 试错法
    if [ -z "$DOWNLOAD_URL" ]; then
        warning "常规连接失败，检测到可能处于纯 IPv6 环境，正在尝试轮询 DNS64 备用服务器..."
        for dns64 in "${ALTERNATE_DNS64_SERVERS[@]}"; do
            info "尝试通过 DNS64 [$dns64] 获取资源..."
            DOWNLOAD_URL=$(curl -s --connect-timeout 5 --dns-servers "$dns64" https://api.github.com/repos/$REPO/releases/latest | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)
            if [ -n "$DOWNLOAD_URL" ]; then
                success "成功通过 DNS64 服务器 [$dns64] 获取到下载链接。"
                # 记录当前有效的 dns64 服务供后续下载使用
                local active_dns64="$dns64"
                break
            fi
        done
    fi

    if [ -z "$DOWNLOAD_URL" ]; then
        error "无法获取下载链接。请检查网络或确认 DNS64 备用服务器是否可用。"
        return 1
    fi

    info "开始下载: $DOWNLOAD_URL"
    
    # 根据是否使用了 DNS64 决定 curl 的参数
    if [ -n "$active_dns64" ]; then
        if ! curl -L --dns-servers "$active_dns64" -o "$BINARY_PATH" "$DOWNLOAD_URL"; then
            error "通过 DNS64 下载核心文件失败。"
            return 1
        fi
    else
        if ! curl -L -o "$BINARY_PATH" "$DOWNLOAD_URL"; then
            error "下载核心文件失败，请检查网络。"
            return 1
        fi
    fi
    chmod +x "$BINARY_PATH"

    # 2. 初始化一个默认配置文件（供随后的修改逻辑读取默认值）
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
tunnel:
  name: tun0
socks5:
  port: 1080
  address: '127.0.0.1'
EOF
    fi

    # 3. 引导用户输入节点数据并写入 config.yaml
    modify_config

    # 4. 先生成服务环境，再启动，防止出现 Unit not found
    step "正在构建系统服务环境..."
    generate_service_file

    step "正在启动 tun2socks 服务..."
    systemctl start tun2socks.service
    success "tun2socks 安装且启动成功！"
}

#================================================================================
# 交互式面板渲染
#================================================================================
show_menu() {
    clear
    # 1. 动态获取状态
    if [ -f "$SERVICE_FILE" ] && systemctl is-active --quiet tun2socks.service; then
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
    echo -e "${GREEN} 2. 修改 节点配置${NC}"
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
        read -r -p "请选择操作: " choice
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
                if [ -f "$SERVICE_FILE" ]; then
                    systemctl start tun2socks.service && success "启动成功。" || error "启动失败。"
                else
                    error "服务未安装，请先选择 1。"
                fi
                ;;
            5)
                step "正在停止服务..."
                if [ -f "$SERVICE_FILE" ]; then
                    systemctl stop tun2socks.service && success "停止成功。" || error "停止失败。"
                else
                    error "服务未安装。"
                fi
                ;;
            6)
                step "正在重启服务..."
                if [ -f "$SERVICE_FILE" ]; then
                    systemctl restart tun2socks.service && success "重启成功。" || error "重启失败。"
                else
                    error "服务未安装。"
                fi
                ;;
            7)
                if [ -f "$SERVICE_FILE" ]; then
                    step "显示最近20条服务日志 (按 q 退出)："
                    journalctl -u tun2socks.service -n 20 --no-pager
                else
                    error "没有日志，服务尚未安装。"
                fi
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
