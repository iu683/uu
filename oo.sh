#!/bin/bash
set -e

#================================================================================
# 常量和全局变量定义
#================================================================================
REPO="heiher/hev-socks5-tunnel" # 保留作为 GitHub 测试，但核心更换为 redsocks
REDSOCKS_CONF="/etc/redsocks.conf"
IPTABLES_RULES="/etc/redsocks.rules"

# 颜色高亮定义
RED='\033;31m'
GREEN='\033;32m'
YELLOW='\033;33m'
BLUE='\033;34m'
PURPLE='\033;35m'
CYAN='\033;36m'
NC='\033[0m'
RESET='\033[0m'

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

test_github_access() {
    step "正在测试基础网络访问..."
    if curl -s -I -m 10 https://github.com >/dev/null; then
        success "网络访问测试成功。"
        return 0
    else
        warning "网络访问测试失败，请检查基础网络。"
        return 1
    fi
}

#================================================================================
# Iptables 规则洗净与恢复
#================================================================================
cleanup_iptables() {
    step "正在清理 redsocks 残留的 iptables 规则..."
    
    # 检查 OUTPUT 链中是否存在引用的 REDSOCKS
    if iptables -t nat -S OUTPUT 2>/dev/null | grep -q "REDSOCKS"; then
        iptables -t nat -D OUTPUT -p tcp -j REDSOCKS 2>/dev/null || true
    fi
    
    # 冲刷并删除自定义链
    iptables -t nat -F REDSOCKS 2>/dev/null || true
    iptables -t nat -X REDSOCKS 2>/dev/null || true
    
    success "iptables 代理规则全面洗净，原网已恢复。"
}

#================================================================================
# 配置核心读取与写入逻辑 (Redsocks 格式)
#================================================================================
write_config_file() {
    local current_addr="" current_port="" current_user="" current_pass=""
    
    # 解析现有的 redsocks.conf 提取配置（如果存在）
    if [ -f "$REDSOCKS_CONF" ]; then
        current_addr=$(grep -E '^[[:space:]]*ip[[:space:]]*=' "$REDSOCKS_CONF" | head -n1 | awk -F'=' '{print $2}' | tr -d " ';\"")
        current_port=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$REDSOCKS_CONF" | head -n1 | awk -F'=' '{print $2}' | tr -d " ';\"")
        current_user=$(grep -E '^[[:space:]]*login[[:space:]]*=' "$REDSOCKS_CONF" | head -n1 | awk -F'=' '{print $2}' | tr -d " ';\"")
        current_pass=$(grep -E '^[[:space:]]*password[[:space:]]*=' "$REDSOCKS_CONF" | head -n1 | awk -F'=' '{print $2}' | tr -d " ';\"")
    fi

    # 1. 节点地址
    local input_addr
    while true; do
        if [ -n "$current_addr" ]; then
            read -r -p "请输入Socks5服务器地址 [$current_addr]: " input_addr
            [ -z "$input_addr" ] && input_addr=$current_addr
        else
            read -r -p "请输入Socks5服务器地址 (建议使用纯IP): " input_addr
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

    input_addr=$(echo "$input_addr" | tr -d '\r')
    input_port=$(echo "$input_port" | tr -d '\r')
    input_user=$(echo "$input_user" | tr -d '\r')
    input_pass=$(echo "$input_pass" | tr -d '\r')

    # 生成 redsocks 官方标准的完整配置文件
    step "正在渲染生成 $REDSOCKS_CONF ..."
    cat > "$REDSOCKS_CONF" <<EOF
base {
    log_debug = off;
    log_info = on;
    log = "syslog:daemon";
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;

    ip = $input_addr;
    port = $input_port;
    type = socks5;
EOF

    if [ -n "$input_user" ]; then
        echo "    login = \"$input_user\";" >> "$REDSOCKS_CONF"
    fi
    if [ -n "$input_pass" ]; then
        echo "    password = \"$input_pass\";" >> "$REDSOCKS_CONF"
    fi

    echo "}" >> "$REDSOCKS_CONF"

    # 动态渲染本地生产的 iptables.rules 规则文件 (包含强悍的 SSH 防断网及防死循环逻辑)
    step "正在动态渲染生成防火墙隔离规则 $IPTABLES_RULES ..."
    cat > "$IPTABLES_RULES" <<EOF
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
:REDSOCKS - [0:0]

# 【防断网策略】确保系统的 SSH 22 端口双向流量绝对直连，不进代理
-A OUTPUT -p tcp --dport 22 -j RETURN
-A OUTPUT -p tcp --sport 22 -j RETURN

# 让所有本地发出的 TCP 流量优先经过 REDSOCKS 链判定
-A OUTPUT -p tcp -j REDSOCKS

# 豁免代理服务器本尊的 IP（防止产生内核死循环环路）
-A REDSOCKS -d $input_addr -j RETURN

# 绕过保留地址、本地局域网和组播地址
-A REDSOCKS -d 0.0.0.0/8 -j RETURN
-A REDSOCKS -d 10.0.0.0/8 -j RETURN
-A REDSOCKS -d 127.0.0.0/8 -j RETURN
-A REDSOCKS -d 169.254.0.0/16 -j RETURN
-A REDSOCKS -d 172.16.0.0/12 -j RETURN
-A REDSOCKS -d 192.168.0.0/16 -j RETURN
-A REDSOCKS -d 224.0.0.0/4 -j RETURN
-A REDSOCKS -d 240.0.0.0/4 -j RETURN

# 将其余一切公网 TCP 流量重定向到 Redsocks 本地转发端口 12345
-A REDSOCKS -p tcp -j REDIRECT --to-ports 12345
COMMIT
EOF
}

change_config() {
    info "开始修改 Redsocks 节点配置："
    echo "--------------------------------------------------------"
    write_config_file
    success "节点配置文件更新成功！"
    
    if systemctl is-active --quiet redsocks.service; then
        step "检测到服务正在后台运行，正在重载防火墙与服务..."
        systemctl restart redsocks.service
        iptables-restore < "$IPTABLES_RULES"
        success "新配置已无缝生效。"
    fi
}

#================================================================================
# Redsocks 安装与环境初始化
#================================================================================
install_tun2socks() {
    cleanup_iptables

    step "检查并安装 redsocks 依赖软件..."
    if ! command -v redsocks &>/dev/null; then
        apt-get update && apt-get install -y redsocks iptables curl || {
            error "安装 redsocks 失败，请检查系统 apt 源！"
            return 1
        }
    fi

    # 停止系统可能默认启动的自带旧 redsocks
    systemctl stop redsocks 2>/dev/null || true
    systemctl disable redsocks 2>/dev/null || true

    step "初始化配置参数..."
    write_config_file

    step "正在动态接管并重构系统守护服务 (redsocks.service)..."
    local SERVICE_FILE="/etc/systemd/system/redsocks.service"
    
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Redsocks Transparent Proxy Service
After=network.target

[Service]
Type=forking
PIDFile=/run/redsocks.pid
ExecStartPre=-/bin/rm -f /run/redsocks.pid
# 直接强制读取我们在 /etc 下接管的全新配置文件
ExecStart=/usr/sbin/redsocks -c $REDSOCKS_CONF -p /run/redsocks.pid
ExecStartPost=/sbin/iptables-restore $IPTABLES_RULES
ExecStopPost=/bin/sh -c 'iptables -t nat -D OUTPUT -p tcp -j REDSOCKS 2>/dev/null || true; iptables -t nat -F REDSOCKS 2>/dev/null || true; iptables -t nat -X REDSOCKS 2>/dev/null || true'
TimeoutStartSec=4
Restart=on-failure
LimitNOFILE=524288

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable redsocks.service 2>/dev/null
    
    step "正在自动拉起 Redsocks 全局网络内核代理..."
    systemctl start redsocks.service || { 
        error "自动启动隧道服务失败！请执行 journalctl -u redsocks.service 排查原因。"
        return 1
    }
    
    success "Redsocks + iptables 透明代理环境配置完毕！"
}

uninstall_tun2socks() {
    cleanup_iptables
    local SERVICE_FILE="/etc/systemd/system/redsocks.service"

    step "正在停止并彻底禁用后台 redsocks 服务..."
    systemctl stop redsocks.service 2>/dev/null || true
    systemctl disable redsocks.service 2>/dev/null || true

    step "正在清理系统残留组件文件..."
    [ -f "$SERVICE_FILE" ] && rm -f "$SERVICE_FILE"
    [ -f "$REDSOCKS_CONF" ] && rm -f "$REDSOCKS_CONF"
    [ -f "$IPTABLES_RULES" ] && rm -f "$IPTABLES_RULES"
    
    systemctl daemon-reload
    success "Redsocks 环境已彻底从系统卸载干净。"
}

get_status() {
    if systemctl is-active --quiet redsocks.service; then
        status_show="${GREEN}已启动 (运行中)${RESET}"
    else
        status_show="${RED}已停止 (未运行)${RESET}"
    fi

    if command -v redsocks &>/dev/null; then
        local version_raw
        version_raw=$(redsocks -v 2>&1 | awk '{print $2}')
        version_show="${YELLOW}${version_raw:-已安装}${RESET}"
    else
        version_show="${RED}未安装${RESET}"
    fi

    if [ -f "$REDSOCKS_CONF" ]; then
        local port addr
        addr=$(grep -E '^[[:space:]]*ip[[:space:]]*=' "$REDSOCKS_CONF" | head -n1 | awk -F'=' '{print $2}' | tr -d " ';\"")
        port=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$REDSOCKS_CONF" | head -n1 | awk -F'=' '{print $2}' | tr -d " ';\"")
        port_show="${YELLOW}${addr}:${port}${RESET}"
    else
        port_show="${RED}无配置${RESET}"
    fi
}

test_exit_ip() {
    step "正在通过全局 iptables 转发层查询落地出口 IP..."
    
    local ip_info=""
    local test_urls=(
        "https://api.ipify.org?format=json"
        "https://ipinfo.io/json"
        "https://ifconfig.me/all.json"
    )

    for url in "${test_urls[@]}"; do
        info "正在尝试请求: $url ..."
        # 注意：由于 iptables 作用于整个内核全局，此处不需要再加 --noproxy
        ip_info=$(curl -s -m 6 "$url" 2>/dev/null || echo "")
        if [ -n "$ip_info" ]; then
            break
        fi
    done

    if [ -n "$ip_info" ]; then
        echo -e "${GREEN}----------------------------------------${RESET}"
        if echo "$ip_info" | grep -q "{"; then
            echo "$ip_info" | sed 's/["{}]//g' | sed 's/,/\n/g' | sed 's/^ *//'
        else
            echo -e "当前落地出口 IP: ${YELLOW}$ip_info${RESET}"
        fi
        echo -e "${GREEN}----------------------------------------${RESET}"
        success "测试成功！Netfilter NAT 转发网络畅通。"
    else
        error "获取失败。请检查 Redsocks 服务端握手日志。"
        warning "这通常是因为：1. 您的 Socks5 节点本身不支持 HTTPS 代理；2. 远端外部端口未正常放行。"
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
        echo -e "${GREEN}    Redsocks + Iptables 面板    ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}状态   :${RESET} $status_show"
        echo -e "${GREEN}版本   :${RESET} $version_show"
        echo -e "${GREEN}代理   :${RESET} $port_show"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1. 安装 Redsocks 环境${RESET}"
        echo -e "${GREEN} 2. 占位 (Redsocks 使用系统自带源无需升级)${RESET}"
        echo -e "${GREEN} 3. 卸载 Redsocks 环境${RESET}"
        echo -e "${GREEN} 4. 修改 Socks5 配置${RESET}"
        echo -e "${GREEN} 5. 启动全局代理 (应用规则)${RESET}"
        echo -e "${GREEN} 6. 停止全局代理 (清空规则)${RESET}"
        echo -e "${GREEN} 7. 重启 Redsocks 服务${RESET}"
        echo -e "${GREEN} 8. 查看系统日志${RESET}"
        echo -e "${GREEN} 9. 测试当前出口IP${RESET}"
        echo -e "${GREEN} 0. 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"
        
        read -p $'\e[32m请输入数字: \e[0m' num
        case "$num" in
            1) install_tun2socks ;;
            2) warning "Redsocks 基于系统软件包管理，无需脚本手动更新。" ;;
            3) uninstall_tun2socks ;;
            4) change_config ;;
            5)
                step "正在启动服务并加载 iptables NAT 劫持逻辑..."
                if [ ! -f "$REDSOCKS_CONF" ]; then
                    error "未发现任何节点配置，请先执行选项 1 或 4 ！"
                else
                    systemctl start redsocks.service && iptables-restore < "$IPTABLES_RULES" && success "代理已全力运转。" || error "启动失败。"
                fi
                ;;
            6)
                step "正在安全卸载防火墙劫持链，恢复物理原生网络..."
                systemctl stop redsocks.service && cleanup_iptables && success "代理已关闭，网络已复原。" || error "停用失败。"
                ;;
            7)
                step "正在重启后台守护进程..."
                systemctl restart redsocks.service && success "重启成功。" || error "重启失败。"
                ;;
            8)
                step "加载最近 30 行代理运行日志："
                echo "--------------------------------------------------------"
                journalctl -u redsocks.service -n 30 --no-pager || tail -n 30 /var/log/syslog
                ;;
            9) test_exit_ip ;;
            0) exit 0 ;;
            *) error "非法数字，请输入菜单内提供的值！" ;;
        esac
        echo -ne "${YELLOW}按任意键返回主菜单...${RESET}"
        read -r
    done
}

# 正式拉起主控制台
panel_menu
