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
# 状态
# =============================
status_warp() {
    if ! is_installed; then
        error "未安装 WARP"
        return
    fi

    ensure_warp_service || return

    raw=$(warp-cli status)

    # 状态翻译
    status=$(echo "$raw" | grep "Status update" | awk -F': ' '{print $2}')
    network=$(echo "$raw" | grep "Network" | awk -F': ' '{print $2}')

    case "$status" in
        Connected) status_cn="已连接" ;;
        Connecting) status_cn="连接中" ;;
        Disconnected) status_cn="未连接" ;;
        *) status_cn="$status" ;;
    esac

    case "$network" in
        healthy) network_cn="网络正常" ;;
        degraded) network_cn="网络异常" ;;
        *) network_cn="$network" ;;
    esac

    echo -e "${YELLOW}WARP 状态:${RESET}"
    echo -e "连接状态: ${GREEN}$status_cn${RESET}"
    echo -e "网络状态: ${GREEN}$network_cn${RESET}"
}

# =============================
# 测试
# =============================
test_proxy() {
    if [[ ! -f "$PORT_FILE" ]]; then
        error "未找到端口"
        return
    fi

    port=$(cat "$PORT_FILE")

    info "测试代理端口: $port"

    result=$(curl -s --max-time 10 --proxy socks5://127.0.0.1:$port ifconfig.me)

    if [[ -n "$result" ]]; then
        echo -e "${GREEN}成功 ✅${RESET} 出口IP: ${CYAN}$result${RESET}"
    else
        error "失败"
    fi
}

# =============================
# 改端口
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
# 修复
# =============================
fix_warp() {
    if ! is_installed; then
        error "未安装"
        return
    fi

    warn "尝试修复 WARP..."

    ensure_warp_service || return

    warp-cli disconnect || true
    sleep 1
    warp-cli connect || true

    info "已尝试重连"
}

CRON_JOB="0 * * * * /bin/systemctl restart warp-svc > /dev/null 2>&1"

add_cron() {
    (crontab -l 2>/dev/null | grep -vF "$CRON_JOB" ; echo "$CRON_JOB") | crontab -
    info "已添加定时任务（每小时重启 warp-svc）"
}

remove_cron() {
    crontab -l 2>/dev/null | grep -vF "$CRON_JOB" | crontab -
    info "已移除 warp-svc 定时任务"
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

    remove_cron

    info "卸载完成 ✅"
}

# =============================
# 菜单
# =============================
menu() {
    clear
    echo -e "${GREEN}==== WARP 管理 ====${RESET}"
    echo -e "${GREEN}1) 安装并配置${RESET}"
    echo -e "${GREEN}2) 查看状态${RESET}"
    echo -e "${GREEN}3) 测试代理${RESET}"
    echo -e "${GREEN}4) 修改端口${RESET}"
    echo -e "${GREEN}5) 修复 WARP${RESET}"
    echo -e "${GREEN}6) 定时重启${RESET}"
    echo -e "${GREEN}7) 卸载 WARP${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp $'\033[32m请选择: \033[0m' num

    case $num in
        1) install_warp ;;
        2) status_warp ;;
        3) test_proxy ;;
        4) change_port ;;
        5) fix_warp ;;
        6)
           echo -e "${GREEN}1) 添加 cron${RESET}"
           echo -e "${GREEN}2) 删除 cron${RESET}"
           read -rp $'\033[32m请选择: \033[0m' c

           case $c in
               1) add_cron ;;
               2) remove_cron ;;
               *) warn "无效选项" ;;
           esac
           
           pause  
           ;;
        7) uninstall_warp ;;
        0) exit 0 ;;
        *) warn "无效选项" ;;
    esac

    pause
}

while true; do
    menu
done
