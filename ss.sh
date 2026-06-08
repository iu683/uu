#!/bin/bash
set -e

#================================================================================
# 常量和全局变量定义
#================================================================================
REPO="heiher/hev-socks5-tunnel"

# 颜色高亮定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
RESET='\033[0m'

# 备用 DNS64 服务器（专门解决纯 IPv6/机房环境下载问题）
ALTERNATE_DNS64_SERVERS=(
    "2a00:1098:2b::1"
    "2a01:4f8:c2c:123f::1"
    "2a01:4f9:c010:3f02::1"
    "2001:67c:2b0::4"
    "2001:67c:2b0::6"
)

#================================================================================
# 日志和底层工具函数
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
    
    step "设置 DNS64 服务器（用于无缝下载核心程序）..."
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
    step "正在强行清理底层残留的 IP 规则和旧路由..."
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

    success "IP 基础路由规则全面洗净。"
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
            read -r -p "请输入Socks5服务器地址 (建议使用纯IP，例如 8.220.163.172): " input_addr
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
        read -r -p "请输入用户名 (回车保持现状, 彻底清空请输入 none) [$current_user]: " input_user
        [ -z "$input_user" ] && input_user=$current_user
        [ "$input_user" = "none" ] && input_user=""
    else
        read -r -p "请输入用户名 (可选，无验证直接留空回车): " input_user
    fi

    # 4. 密码
    local input_pass
    if [ -n "$input_user" ]; then
        if [ -n "$current_pass" ]; then
            read -r -p "请输入密码 (回车保持现状, 彻底清空请输入 none) [$current_pass]: " input_pass
            [ -z "$input_pass" ] && input_pass=$current_pass
            [ "$input_pass" = "none" ] && input_pass=""
        else
            read -r -p "请输入密码 (可选，无验证直接留空回车): " input_pass
        fi
    else
        input_pass=""
    fi

    # 正式渲染 YAML
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

change_config() {
    info "开始修改 Socks5 节点配置（直接回车则保持现状不变）："
    echo "--------------------------------------------------------"
    write_config_file
    success "节点配置文件更新成功！"
    
    if systemctl is-active --quiet tun2socks.service; then
        step "检测到服务正在后台运行，正在自动重启以应用新配置..."
        systemctl restart tun2socks.service && success "重启成功，新节点配置已生效。" || error "重启失败，请检查服务状态。"
    fi
}

#================================================================================
# 选项 2：全自动升级核心（去除了手动确认，发现新版本直接更新）
#================================================================================
update_core_binary() {
    if [ ! -f "/usr/local/bin/tun2socks" ]; then
        error "检测到您尚未安装 Tun2Socks 环境，请先使用选项 1 进行初始化安装！"
        return 1
    fi

    step "正在连接 GitHub 检查最新 Release Version..."
    local latest_release_json=$(curl -s https://api.github.com/repos/$REPO/releases/latest)
    local latest_version=$(echo "$latest_release_json" | grep '"tag_name":' | cut -d '"' -f 4)
    local download_url=$(echo "$latest_release_json" | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)

    if [ -z "$latest_version" ] || [ -z "$download_url" ]; then
        error "无法从 GitHub 获取版本信息，网络可能受到干扰。"
        return 1
    fi

    # 【已同步修改】使用与面板一致的精准抓取逻辑，去除开头的字母 v 以便和 GitHub 的纯数字比对
    local local_version="未知"
    if [ -f "/usr/local/bin/tun2socks" ]; then
        local_version=$(/usr/local/bin/tun2socks --version 2>&1 | grep "Version:" | awk '{print $2}')
        [ -z "$local_version" ] && local_version="未知"
    fi

    info "本地核心版本: $local_version"
    info "GitHub最新版本: $latest_version"

    if [ "$local_version" = "$latest_version" ]; then
        success "当前核心程序已是官方最新发布版，无需重复升级。"
        return 0
    fi

    # 更改处：删除用户 read 选择交互，直接进入静默强制升级
    warning "检测到新版本核心程序 ($latest_version)，开始全自动无缝升级..."

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
        step "正在暂停全局代理以准备替换核心二进制..."
        systemctl stop tun2socks.service || true
    fi

    step "正在下载官方最新编译核心..."
    if curl -L -o "/usr/local/bin/tun2socks" "$download_url"; then
        chmod +x "/usr/local/bin/tun2socks"
        success "核心程序成功升级至 $latest_version ！"
    else
        error "下载核心程序失败，请检查网络。"
    fi

    restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$was_immutable"

    if [ "$is_running" = true ]; then
        step "正在恢复并重新启动全局代理..."
        systemctl start tun2socks.service && success "隧道已成功恢复运行！" || error "重启失败。"
    fi
}

install_tun2socks() {
    cleanup_ip_rules

    step "检查 tun2socks 服务当前状态..."
    if systemctl is-active --quiet tun2socks.service; then
        info "检测到 tun2socks 旧进程正在运行，正在将其安全终止..."
        systemctl stop tun2socks.service || true
    fi

    RESOLV_CONF="/etc/resolv.conf"
    RESOLV_CONF_BAK="/etc/resolv.conf.bak"
    WAS_IMMUTABLE=false

    step "检查 /etc/resolv.conf 文件属性状态..."
    if lsattr -d "$RESOLV_CONF" 2>/dev/null | grep -q -- '-i-'; then
        info "/etc/resolv.conf 文件当前被系统锁定，正在临时解除..."
        chattr -i "$RESOLV_CONF" || { error "临时解锁 /etc/resolv.conf 失败"; exit 1; }
        WAS_IMMUTABLE=true
    fi

    step "备份系统当前 DNS 配置..."
    cp "$RESOLV_CONF" "$RESOLV_CONF_BAK" || true

    if ! set_dns64_servers "$RESOLV_CONF" "$WAS_IMMUTABLE" "$RESOLV_CONF_BAK"; then
        return 1
    fi

    INSTALL_DIR="/usr/local/bin"
    CONFIG_DIR="/etc/tun2socks"
    SERVICE_FILE="/etc/systemd/system/tun2socks.service"
    BINARY_PATH="$INSTALL_DIR/tun2socks"

    step "从 GitHub 获取最新 Release 核心下载地址..."
    DOWNLOAD_URL=$(curl -s https://api.github.com/repos/$REPO/releases/latest | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)

    if [ -z "$DOWNLOAD_URL" ]; then
        error "未找到适用于 linux-x86_64 的核心下载链接，请检查网络。"
        restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
        return 1
    fi

    step "正在下载 GitHub 最新发布版官方核心程序..."
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

    step "正在初始化全局出口节点配置信息："
    write_config_file

    step "正在动态计算并生成底层守护服务 (tun2socks.service)..."
    RULE_ADD_FROM_MAIN_IP=""
    RULE_DEL_FROM_MAIN_IP=""
    RULE_ADD_FROM_MAIN_IP6=""
    RULE_DEL_FROM_MAIN_IP6=""

    MAIN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    MAIN_IP6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')

    if [ -n "$MAIN_IP" ]; then
        RULE_ADD_FROM_MAIN_IP="ExecStartPost=-/sbin/ip rule add from $MAIN_IP lookup main pref 15"
        RULE_DEL_FROM_MAIN_IP="ExecStop=-/sbin/ip rule del from $MAIN_IP lookup main pref 15"
    fi
    if [ -n "$MAIN_IP6" ]; then
        RULE_ADD_FROM_MAIN_IP6="ExecStartPost=-/sbin/ip -6 rule add from $MAIN_IP6 lookup main pref 15"
        RULE_DEL_FROM_MAIN_IP6="ExecStop=-/sbin/ip -6 rule del from $MAIN_IP6 lookup main pref 15"
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Tun2Socks Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=$BINARY_PATH $CONFIG_DIR/config.yaml
ExecStartPost=/bin/sleep 1

# 【防断网策略】确保 SSH 22 端口流量直连原生主网卡，绝不进入虚拟网卡
ExecStartPost=-/sbin/ip rule add to 0.0.0.0/0 dport 22 lookup main pref 5
ExecStartPost=-/sbin/ip rule add to 0.0.0.0/0 sport 22 lookup main pref 5
ExecStartPost=-/sbin/ip -6 rule add to ::/0 dport 22 lookup main pref 5
ExecStartPost=-/sbin/ip -6 rule add to ::/0 sport 22 lookup main pref 5

ExecStartPost=-/sbin/ip rule add fwmark 438 lookup main pref 10
ExecStartPost=-/sbin/ip -6 rule add fwmark 438 lookup main pref 10
ExecStartPost=-/sbin/ip route add default dev tun0 table 20
ExecStartPost=-/sbin/ip rule add lookup 20 pref 20
${RULE_ADD_FROM_MAIN_IP}
${RULE_ADD_FROM_MAIN_IP6}
ExecStartPost=-/sbin/ip rule add to 127.0.0.0/8 lookup main pref 16
ExecStartPost=-/sbin/ip rule add to 10.0.0.0/8 lookup main pref 16
ExecStartPost=-/sbin/ip rule add to 172.16.0.0/12 lookup main pref 16
ExecStartPost=-/sbin/ip rule add to 192.168.0.0/16 lookup main pref 16

ExecStop=-/sbin/ip rule del to 0.0.0.0/0 dport 22 lookup main pref 5
ExecStop=-/sbin/ip rule del to 0.0.0.0/0 sport 22 lookup main pref 5
ExecStop=-/sbin/ip -6 rule del to ::/0 dport 22 lookup main pref 5
ExecStop=-/sbin/ip -6 rule del to ::/0 sport 22 lookup main pref 5
ExecStop=-/sbin/ip rule del fwmark 438 lookup main pref 10
ExecStop=-/sbin/ip -6 rule del fwmark 438 lookup main pref 10
ExecStop=-/sbin/ip route del default dev tun0 table 20
ExecStop=-/sbin/ip rule del lookup 20 pref 20
${RULE_DEL_FROM_MAIN_IP}
${RULE_DEL_FROM_MAIN_IP6}
ExecStop=-/sbin/ip rule del to 127.0.0.0/8 lookup main pref 16
ExecStop=-/sbin/ip rule del to 10.0.0.0/8 lookup main pref 16
ExecStop=-/sbin/ip rule del to 172.16.0.0/12 lookup main pref 16
ExecStop=-/sbin/ip rule del to 192.168.0.0/16 lookup main pref 16

Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tun2socks.service 2>/dev/null
    
    step "正在自动拉起全局网络代理隧道..."
    systemctl start tun2socks.service || { 
        error "自动启动隧道服务失败！请查看日志排查原因。"
        return 1
    }
    
    success "Tun2Socks 环境配置完毕！"
}

uninstall_tun2socks() {
    cleanup_ip_rules
    SERVICE_FILE="/etc/systemd/system/tun2socks.service"
    CONFIG_DIR="/etc/tun2socks"
    BINARY_PATH="/usr/local/bin/tun2socks"

    step "正在停止并彻底禁用后台 tun2socks 服务..."
    if systemctl is-active --quiet tun2socks.service; then
        systemctl stop tun2socks.service
    fi
    systemctl disable tun2socks.service 2>/dev/null || true

    step "正在清理系统残留组件文件..."
    [ -f "$SERVICE_FILE" ] && rm -f "$SERVICE_FILE"
    [ -d "$CONFIG_DIR" ] && rm -rf "$CONFIG_DIR"
    [ -f "$BINARY_PATH" ] && rm -f "$BINARY_PATH"
    
    systemctl daemon-reload
    success "Tun2Socks 环境已彻底从系统卸载干净。"
}

get_status() {
    if systemctl is-active --quiet tun2socks.service; then
        status_show="${GREEN}已启动 (运行中)${RESET}"
    else
        status_show="${RED}已停止 (未运行)${RESET}"
    fi

    # 针对 hev-socks5-tunnel 专门优化的版本抓取逻辑
    if [ -f "/usr/local/bin/tun2socks" ]; then
        local version_raw=""
        # 强制使用 --version 参数，并用 grep 和 awk 精准提取数字部分
        version_raw=$(/usr/local/bin/tun2socks --version 2>&1 | grep "Version:" | awk '{print $2}')
        
        if [ -n "$version_raw" ]; then
            version_show="${YELLOW}v${version_raw}${RESET}"
        else
            version_show="${YELLOW}已安装${RESET}"
        fi
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
        success "测试成功！隧道网络双向畅通。"
    else
        error "获取失败，可能自定义节点暂时不可用、账密有误或节点不支持 UDP 转发。"
    fi
}

#================================================================================
# 面板主循环菜单
#================================================================================
panel_menu() {
    require_root
    while true; do
        get_status
        clear
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}    Tun2Socks 全局代理管理面板   ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}状态   :${RESET} $status_show"
        echo -e "${GREEN}版本   :${RESET} $version_show"
        echo -e "${GREEN}代理   :${RESET} $port_show"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1. 安装 Tun2Socks${RESET}"
        echo -e "${GREEN} 2. 更新 Tun2Socks 核心程序${RESET}"
        echo -e "${GREEN} 3. 卸载 Tun2Socks${RESET}"
        echo -e "${GREEN} 4. 修改节点配置${RESET}"
        echo -e "${GREEN} 5. 启动 Tun2Socks${RESET}"
        echo -e "${GREEN} 6. 停止 Tun2Socks${RESET}"
        echo -e "${GREEN} 7. 重启 Tun2Socks${RESET}"
        echo -e "${GREEN} 8. 查看服务运行日志${RESET}"
        echo -e "${GREEN} 9. 测试当前出口IP${RESET}"
        echo -e "${GREEN} 0. 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"
        
        read -p $'\e[32m请输入数字: \e[0m' num
        case "$num" in
            1) install_tun2socks ;;
            2) update_core_binary ;;
            3) uninstall_tun2socks ;;
            4) change_config ;;
            5)
                step "正在唤醒全局代理网络..."
                if [ ! -f "/etc/tun2socks/config.yaml" ]; then
                    error "未发现任何节点配置，请先执行选项 1 或 4 进行配置！"
                else
                    systemctl start tun2socks.service && success "启动成功。" || error "启动失败。"
                fi
                ;;
            6)
                step "正在关闭全局代理，物理网络正在复原..."
                systemctl stop tun2socks.service && success "代理已停用，原网已恢复。" || error "停用失败。"
                ;;
            7)
                step "正在重启核心隧道服务..."
                systemctl restart tun2socks.service && success "重启成功。" || error "重启失败。"
                ;;
            8)
                step "实时加载最后 30 行服务运行日志 (按 Q 键退出)："
                echo "--------------------------------------------------------"
                journalctl -u tun2socks.service -n 30 --no-pager || error "未捕获到系统日志。"
                ;;
            9) test_exit_ip ;;
            0) exit 0 ;;
            *) error "非法数字，请输入菜单内提供的值！" ;;
        esac
        echo -e "${YELLOW}按任意键返回主菜单...${RESET}"
        read -n 1
    done
}

# 正式拉起主控制台
panel_menu
