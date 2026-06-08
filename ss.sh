#!/bin/bash
set -e

#================================================================================
# 常量和全局变量定义
#================================================================================
REDSOCKS_CONF="/etc/redsocks.conf"
IPTABLES_RULES="/etc/redsocks.rules"

# 颜色高亮定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
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

#================================================================================
# Iptables 规则洗净与恢复
#================================================================================
cleanup_iptables() {
    step "正在清理 redsocks 残留的 iptables 规则..."
    
    if iptables -t nat -S OUTPUT 2>/dev/null | grep -q "REDSOCKS"; then
        iptables -t nat -D OUTPUT -p tcp -j REDSOCKS 2>/dev/null || true
    fi
    
    iptables -t nat -F REDSOCKS 2>/dev/null || true
    iptables -t nat -X REDSOCKS 2>/dev/null || true
    
    success "iptables 代理规则全面洗净，原网已恢复。"
}

#================================================================================
# 核心配置交互与文件写入（支持自定义Redsocks本地端口）
#================================================================================
write_config_file() {
    local current_local_port="12345"
    local current_addr="" current_port="" current_user="" current_pass=""
    
    # 从现有配置中提取旧数据（如果存在）
    if [ -f "$REDSOCKS_CONF" ]; then
        current_local_port=$(grep -E '^[[:space:]]*local_port[[:space:]]*=' "$REDSOCKS_CONF" | head -n1 | awk -F'=' '{print $2}' | tr -d " ';\"")
        current_addr=$(grep -E '^[[:space:]]*ip[[:space:]]*=' "$REDSOCKS_CONF" | head -n1 | awk -F'=' '{print $2}' | tr -d " ';\"")
        current_port=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$REDSOCKS_CONF" | head -n1 | awk -F'=' '{print $2}' | tr -d " ';\"")
        current_user=$(grep -E '^[[:space:]]*login[[:space:]]*=' "$REDSOCKS_CONF" | head -n1 | awk -F'=' '{print $2}' | tr -d " ';\"")
        current_pass=$(grep -E '^[[:space:]]*password[[:space:]]*=' "$REDSOCKS_CONF" | head -n1 | awk -F'=' '{print $2}' | tr -d " ';\"")
    fi

    [ -z "$current_local_port" ] && current_local_port="12345"

    echo -e "${CYAN}请输入您的代理节点及本地转发参数：${RESET}"
    echo "--------------------------------------------------------"

    # 1. 自定义 Redsocks 本地监听端口
    local input_local_port
    while true; do
        read -r -p "请输入 Redsocks 本地监听端口 [$current_local_port]: " input_local_port
        [ -z "$input_local_port" ] && input_local_port=$current_local_port
        if [[ "$input_local_port" =~ ^[0-9]+$ ]] && [ "$input_local_port" -ge 1 ] && [ "$input_local_port" -le 65535 ]; then
            break
        else
            error "无效的端口号，请输入 1 到 65535 之间的数字。"
        fi
    done

    # 2. 远端 Socks5 节点地址
    local input_addr
    while true; do
        if [ -n "$current_addr" ]; then
            read -r -p "请输入 Socks5 服务器地址 [$current_addr]: " input_addr
            [ -z "$input_addr" ] && input_addr=$current_addr
        else
            read -r -p "请输入 Socks5 服务器地址 (建议使用纯IP): " input_addr
        fi
        if [ -n "$input_addr" ]; then break; else error "服务器地址不能为空。"; fi
    done

    # 3. 远端 Socks5 节点端口
    local input_port
    while true; do
        if [ -n "$current_port" ]; then
            read -r -p "请输入 Socks5 服务器端口 [$current_port]: " input_port
            [ -z "$input_port" ] && input_port=$current_port
        else
            read -r -p "请输入 Socks5 服务器端口 (1-65535): " input_port
        fi
        if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
            break
        else
            error "无效的端口号，请输入 1 到 65535 之间的数字。"
        fi
    done

    # 4. 用户名
    local input_user
    if [ -n "$current_user" ]; then
        read -r -p "请输入用户名 (回车保持现状, 彻底清空请输入 none) [$current_user]: " input_user
        [ -z "$input_user" ] && input_user=$current_user
        [ "$input_user" = "none" ] && input_user=""
    else
        read -r -p "请输入用户名 (可选，无验证直接留空回车): " input_user
    fi

    # 5. 密码
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

    input_local_port=$(echo "$input_local_port" | tr -d '\r')
    input_addr=$(echo "$input_addr" | tr -d '\r')
    input_port=$(echo "$input_port" | tr -d '\r')
    input_user=$(echo "$input_user" | tr -d '\r')
    input_pass=$(echo "$input_pass" | tr -d '\r')

    step "正在渲染生成配置文件 $REDSOCKS_CONF ..."
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
    local_port = $input_local_port;

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

    step "正在动态渲染 iptables 规则 (目标劫持端口: $input_local_port) ..."
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

# 将其余一切公网 TCP 流量重定向到 Redsocks 自定义本地转发端口
-A REDSOCKS -p tcp -j REDIRECT --to-ports $input_local_port
COMMIT
EOF
}

#================================================================================
# 流程 1：一键安装流程（包含完整的依赖安装、配置录入、启动拉起全套工作）
#================================================================================
install_redsocks_env() {
    cleanup_iptables

    step "[1/4] 从软件源检查并安装 redsocks 核心组件..."
    if ! command -v redsocks &>/dev/null; then
        apt-get update && apt-get install -y redsocks iptables curl || {
            error "安装 redsocks 基础包失败，请检查系统网络或 apt 源！"
            return 1
        }
    fi

    # 彻底关闭系统默认自带的旧服务启动行为，防止冲突
    systemctl stop redsocks 2>/dev/null || true
    systemctl disable redsocks 2>/dev/null || true

    step "[2/4] 进入节点配置录入阶段..."
    write_config_file

    step "[3/4] 正在向系统注册自定义守护服务 (redsocks.service)..."
    local SERVICE_FILE="/etc/systemd/system/redsocks.service"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Redsocks Transparent Proxy Service
After=network.target

[Service]
Type=forking
PIDFile=/run/redsocks.pid
ExecStartPre=-/bin/rm -f /run/redsocks.pid
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
    
    step "[4/4] 正在自动激活服务并开启全局透明代理..."
    systemctl start redsocks.service && iptables-restore < "$IPTABLES_RULES" || {
        error "自动启动代理失败，请检查配置参数。"
        return 1
    }

    success "Redsocks 全套环境安装、配置并成功拉起运行！"
}

#================================================================================
# 流程 4：修改/初始化 Socks5 及本地端口配置（完全独立）
#================================================================================
change_config() {
    info "开始单独修改全局代理配置："
    write_config_file
    success "节点配置文件与 Iptables 联动规则更新成功！"
    
    if systemctl is-active --quiet redsocks.service; then
        step "检测到服务正在后台运行，正在自动重启服务以应用新配置与端口..."
        systemctl restart redsocks.service
        iptables-restore < "$IPTABLES_RULES"
        success "新端口和新配置已无缝生效。"
    else
        info "提示：配置已就绪，当前服务处于停止状态。请在主菜单选择【选项 5】手动启动。"
    fi
}

uninstall_redsocks_env() {
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
    success "Redsocks 透明代理环境已彻底从系统卸载干净。"
}

get_status() {
    if systemctl is-active --quiet redsocks.service; then
        status_show="${GREEN}已启动 (运行中)${RESET}"
    else
        status_show="${RED}已停止 (未运行)${RESET}"
    fi

    if command -v redsocks &>/dev/null; then
        local version_raw
        version_raw=$(redsocks -v 2>&1 | grep -oE '[0-9]+\.[0-9.]+' | head -n1)
        if [ -n "$version_raw" ]; then
            version_show="${YELLOW}v${version_raw}${RESET}"
        else
            version_show="${YELLOW}已安装${RESET}"
        fi
    else
        version_show="${RED}未安装${RESET}"
    fi

    if [ -f "$REDSOCKS_CONF" ]; then
        local port addr local_port
        local_port=$(grep -E '^[[:space:]]*local_port[[:space:]]*=' "$REDSOCKS_CONF" | head -n1 | awk -F'=' '{print $2}' | tr -d " ';\"")
        addr=$(grep -E '^[[:space:]]*ip[[:space:]]*=' "$REDSOCKS_CONF" | head -n1 | awk -F'=' '{print $2}' | tr -d " ';\"")
        port=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$REDSOCKS_CONF" | head -n1 | awk -F'=' '{print $2}' | tr -d " ';\"")
        port_show="${YELLOW}${addr}:${port} ${NC}->${CYAN} 本地监听:${local_port}${RESET}"
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
        success "测试成功！防火墙劫持及 Redsocks 转发全局畅通。"
    else
        error "获取失败。请执行选项 8 查看运行日志。"
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
        echo -e "${GREEN} 1. 安装 Redsocks${RESET}"
        echo -e "${GREEN} 2. 卸载 Redsocks${RESET}"
        echo -e "${GREEN} 3. 修改配置${RESET}"
        echo -e "${GREEN} 4. 启动 Redsocks${RESET}"
        echo -e "${GREEN} 5. 停止 Redsocks${RESET}"
        echo -e "${GREEN} 6. 重启 Redsocks${RESET}"
        echo -e "${GREEN} 7. 查看系统日志${RESET}"
        echo -e "${GREEN} 8. 测试当前出口IP${RESET}"
        echo -e "${GREEN} 0. 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"
        
        read -p $'\e[32m请输入数字: \e[0m' num
        case "$num" in
            1) install_redsocks_env ;;
            2) uninstall_redsocks_env ;;
            3) change_config ;;
            4)
                step "正在唤醒后台代理并加载 iptables NAT 转发规则..."
                if [ ! -f "$REDSOCKS_CONF" ] || [ ! -f "$IPTABLES_RULES" ]; then
                    error "未发现有效配置，请先执行【选项 1】或【选项 4】！"
                else
                    systemctl start redsocks.service && iptables-restore < "$IPTABLES_RULES" && success "全局代理已全力运转。" || error "启动失败。"
                fi
                ;;
            5)
                step "正在关闭后台服务并清空劫持规则，物理网络复原中..."
                systemctl stop redsocks.service && cleanup_iptables && success "代理已安全关闭，网络已彻底复原。" || error "停用失败。"
                ;;
            6)
                step "正在强制重启 Redsocks 进程并刷新规则..."
                systemctl restart redsocks.service && success "重启并应用成功。" || error "重启失败。"
                ;;
            7)
                step "加载最近 30 行代理运行日志："
                echo "--------------------------------------------------------"
                journalctl -u redsocks.service -n 30 --no-pager || tail -n 30 /var/log/syslog
                ;;
            8) test_exit_ip ;;
            0) exit 0 ;;
            *) error "非法数字，请输入菜单内提供的值！" ;;
        esac
        echo -ne "${YELLOW}按任意键返回主菜单...${RESET}"
        read -r
    done
}

# 正式拉起主控制台
panel_menu
