#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

PORT_FILE="/etc/warp-port.conf"

info(){ echo -e "${GREEN}[信息] $1${RESET}"; }
warn(){ echo -e "${YELLOW}[警告] $1${RESET}"; }
error(){ echo -e "${RED}[错误] $1${RESET}"; }

pause(){ read -rp "按回车继续..." _; }

# =============================
# 环境检测
# =============================
check_systemd() {
    if [[ "$(ps -p 1 -o comm=)" != "systemd" ]]; then
        error "当前环境不支持 systemd（Docker/LXC/OpenVZ）"
        error "无法使用官方 WARP 客户端"
        return 1
    fi
}

# =============================
# warp-svc 保证运行
# =============================
ensure_warp_service() {
    if ! systemctl is-active --quiet warp-svc; then
        warn "warp-svc 未运行，尝试启动..."
        systemctl daemon-reexec
        systemctl daemon-reload
        systemctl enable warp-svc >/dev/null 2>&1 || true
        systemctl restart warp-svc
        sleep 2
    fi

    if ! systemctl is-active --quiet warp-svc; then
        error "warp-svc 启动失败"
        journalctl -u warp-svc -n 20 --no-pager
        return 1
    fi
}

check_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 && $1 < 65536 ))
}

is_port_used() {
    ss -lnt | awk '{print $4}' | grep -q ":$1$"
}

is_installed() {
    command -v warp-cli >/dev/null 2>&1
}

# =============================
# 随机端口
# =============================
random_port() {
    while true; do
        port=$(shuf -i 10000-60000 -n 1)
        if ! is_port_used "$port"; then
            echo "$port"
            return
        fi
    done
}

get_port_input() {
    read -rp "请输入 Socks5 端口 (回车随机): " port

    if [[ -z "$port" ]]; then
        port=$(random_port)
        info "使用随机端口: $port" >&2
    else
        if ! check_port "$port"; then
            error "端口无效" >&2
            return 1
        fi

        if is_port_used "$port"; then
            error "端口已被占用" >&2
            return 1
        fi

        info "使用自定义端口: $port" >&2
    fi

    echo "$port"
}

# =============================
# 安装
# =============================
install_warp() {
    check_systemd || return
    port=$(get_port_input) || return

    info "安装依赖..."
    apt update
    apt install -y gnupg curl lsb-release

    info "写入 WARP 源..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/cloudflare-client.list

    apt update
    apt install -y cloudflare-warp

    info "启动 WARP 服务..."
    ensure_warp_service || return

    info "注册账户..."
    if warp-cli registration show >/dev/null 2>&1; then
        info "已注册，跳过"
    else
        if warp-cli registration new --help 2>&1 | grep -q accept-tos; then
            warp-cli registration new --accept-tos
        else
            warp-cli registration new
        fi
    fi

    info "设置 Proxy 模式..."
    warp-cli mode proxy
    warp-cli proxy port "$port"
    echo "$port" > "$PORT_FILE"

    info "设置 MASQUE 协议..."
    warp-cli tunnel protocol set MASQUE || true

    info "连接 WARP..."
    warp-cli connect

    sleep 2

    info "完成 ✅"
    echo -e "${CYAN}socks5://127.0.0.1:$port${RESET}"
}

# =============================
# 状态获取 (供面板上方显示使用)
# =============================
get_status_info() {
    if ! is_installed; then
        panel_status="${RED}未安装${RESET}"
        panel_version="${RED}未安装${RESET}"
        panel_port="${RED}未配置${RESET}"
        return
    fi

    # 获取端口
    if [[ -f "$PORT_FILE" ]]; then
        panel_port=$(cat "$PORT_FILE")
    else
        panel_port="未知"
    fi

    # 获取版本
    panel_version=$(warp-cli --version 2>/dev/null | awk '{print $2}' || echo "未知")

    # 获取运行状态
    if ! systemctl is-active --quiet warp-svc; then
        panel_status="${RED}服务未运行${RESET}"
    else
        local raw_status
        raw_status=$(warp-cli status 2>/dev/null | grep "Status update" | awk -F': ' '{print $2}' || true)
        case "$raw_status" in
            Connected) panel_status="${GREEN}已连接 (运行中)${RESET}" ;;
            Connecting) panel_status="${YELLOW}连接中${RESET}" ;;
            Disconnected) panel_status="${YELLOW}未连接 (已停止)${RESET}" ;;
            *) panel_status="${YELLOW}已启动服务${RESET}" ;;
        esac
    fi
}

# =============================
# 测试代理 / 查看节点配置
# =============================
test_proxy() {
    if [[ ! -f "$PORT_FILE" ]]; then
        error "未找到端口"
        return
    fi

    port=$(cat "$PORT_FILE")
    info "当前配置的本地代理: socks5://127.0.0.1:$port"
    info "正在测试代理可用性..."

    result=$(curl -s --max-time 10 --proxy socks5://127.0.0.1:$port ifconfig.me || true)

    if [[ -n "$result" ]]; then
        echo -e "${GREEN}测试成功 ✅${RESET} 出口IP: ${CYAN}$result${RESET}"
    else
        error "测试失败，代理当前无法通网"
    fi
}

# =============================
# 修改配置
# =============================
change_port() {
    if ! is_installed; then
        error "未安装 WARP"
        return
    fi

    ensure_warp_service || return
    port=$(get_port_input) || return

    warp-cli proxy port "$port"
    echo "$port" > "$PORT_FILE"

    info "端口已修改 ✅ -> $port"
}

# =============================
# 查看日志
# =============================
view_logs() {
    info "正在查看最近 30 条日志 (按 q 退出)..."
    journalctl -u warp-svc -n 30 --no-pager
}

# =============================
# 卸载
# =============================
uninstall_warp() {
    warn "正在卸载 WARP..."

    warp-cli disconnect 2>/dev/null || true
    systemctl stop warp-svc 2>/dev/null || true
    systemctl disable warp-svc 2>/dev/null || true

    apt remove -y cloudflare-warp
    apt autoremove -y

    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    rm -f "$PORT_FILE"

    info "卸载完成 ✅"
}

# =============================
# 菜单
# =============================
menu() {
    clear
    # 每次刷新菜单前动态获取一次状态、版本、端口
    get_status_info

    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}         WARP 管理面板          ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $panel_status"
    echo -e "${GREEN}版本 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1. 安装 WARP${RESET}"
    echo -e "${GREEN}2. 更新 WARP${RESET}"
    echo -e "${GREEN}3. 卸载 WARP${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 WARP${RESET}"
    echo -e "${GREEN}6. 停止 WARP${RESET}"
    echo -e "${GREEN}7. 重启 WARP${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    
    read -rp $'\033[32m请选择: \033[0m' num

    case $num in
        1) install_warp ;;
        2) 
            info "检查并更新官方客户端..."
            apt update && apt install --only-upgrade -y cloudflare-warp
            ;;
        3) uninstall_warp ;;
        4) change_port ;;
        5) 
            info "启动服务并连接..."
            systemctl start warp-svc 2>/dev/null || true
            warp-cli connect 2>/dev/null || true
            info "命令已下发"
            ;;
        6) 
            info "断开连接并停止服务..."
            warp-cli disconnect 2>/dev/null || true
            systemctl stop warp-svc 2>/dev/null || true
            info "命令已下发"
            ;;
        7) 
            info "重启服务..."
            systemctl restart warp-svc 2>/dev/null || true
            sleep 1
            warp-cli connect 2>/dev/null || true
            info "重启完成"
            ;;
        8) view_logs ;;
        9) test_proxy ;;
        0) exit 0 ;;
        *) warn "无效选项" ;;
    esac

    pause
}

while true; do
    menu
done
