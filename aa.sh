#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

PORT_FILE="/etc/warp-port.conf"
CRON_JOB="0 * * * * /bin/systemctl restart warp-svc > /dev/null 2>&1"

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
# 定时任务管理
# =============================
manage_cron() {
    if ! is_installed; then
        error "未安装 WARP，无法设置定时任务"
        return
    fi

    echo -e "1) 开启每小时自动重启 warp-svc"
    echo -e "2) 关闭自动重启"
    read -rp "请选择: " cron_choice

    case $cron_choice in
        1)
            (crontab -l 2>/dev/null | grep -v "restart warp-svc"; echo "$CRON_JOB") | crontab -
            info "定时重启任务已添加 (每小时执行一次)"
            ;;
        2)
            crontab -l 2>/dev/null | grep -v "restart warp-svc" | crontab -
            info "定时重启任务已移除"
            ;;
        *)
            warn "无效选项"
            ;;
    esac
}

# =============================
# 核心功能 (安装/状态/测试/改端口/修复)
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
        if ! check_port "$port" || is_port_used "$port"; then
            error "端口无效或已被占用" >&2
            return 1
        fi
        info "使用自定义端口: $port" >&2
    fi
    echo "$port"
}

install_warp() {
    check_systemd || return
    port=$(get_port_input) || return

    info "安装依赖..."
    apt update && apt install -y gnupg curl lsb-release

    info "写入 WARP 源..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflare-client.list

    apt update && apt install -y cloudflare-warp
    ensure_warp_service || return

    info "注册账户..."
    if ! warp-cli registration show >/dev/null 2>&1; then
        warp-cli registration new --accept-tos || warp-cli registration new
    fi

    warp-cli mode proxy
    warp-cli proxy port "$port"
    echo "$port" > "$PORT_FILE"
    warp-cli tunnel protocol set MASQUE || true
    warp-cli connect
    
    sleep 2
    info "安装完成 ✅ socks5://127.0.0.1:$port"
}

status_warp() {
    if ! is_installed; then error "未安装 WARP"; return; fi
    ensure_warp_service || return
    
    raw=$(warp-cli status)
    status=$(echo "$raw" | grep "Status update" | awk -F': ' '{print $2}')
    
    # 检查是否有定时任务
    cron_status="${RED}未开启${RESET}"
    crontab -l 2>/dev/null | grep -q "restart warp-svc" && cron_status="${GREEN}已开启${RESET}"

    echo -e "${YELLOW}WARP 状态:${RESET}"
    echo -e "连接状态: ${GREEN}${status:-Unknown}${RESET}"
    echo -e "定时重启: $cron_status"
}

test_proxy() {
    [[ ! -f "$PORT_FILE" ]] && { error "未找到端口配置"; return; }
    port=$(cat "$PORT_FILE")
    info "测试代理端口: $port"
    result=$(curl -s --max-time 10 --proxy socks5://127.0.0.1:$port ifconfig.me || true)
    [[ -n "$result" ]] && echo -e "${GREEN}成功 ✅${RESET} 出口IP: ${CYAN}$result${RESET}" || error "测试失败"
}

# =============================
# 卸载 (含清理 Cron)
# =============================
uninstall_warp() {
    warn "正在彻底卸载 WARP..."
    
    # 1. 停止并移除服务
    warp-cli disconnect 2>/dev/null || true
    systemctl stop warp-svc 2>/dev/null || true
    systemctl disable warp-svc 2>/dev/null || true

    # 2. 移除包
    apt remove -y cloudflare-warp
    apt autoremove -y

    # 3. 清理文件
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    rm -f "$PORT_FILE"

    # 4. 清理定时任务
    crontab -l 2>/dev/null | grep -v "restart warp-svc" | crontab -
    
    info "卸载完成 ✅"
}

# =============================
# 菜单
# =============================
menu() {
    clear
    echo -e "${GREEN}==== WARP 管理面板 ====${RESET}"
    echo -e "1) 安装并配置"
    echo -e "2) 查看状态"
    echo -e "3) 测试代理"
    echo -e "4) 修改端口"
    echo -e "5) 修复/重连 WARP"
    echo -e "6) 定时重启任务管理${RESET}"
    echo -e "7) 卸载 WARP${RESET}"
    echo -e "0) 退出"
    echo -e "-----------------------"
    read -rp "请选择: " num

    case $num in
        1) install_warp ;;
        2) status_warp ;;
        3) test_proxy ;;
        4) 
           if is_installed; then
               ensure_warp_service || return
               port=$(get_port_input) || return
               warp-cli proxy port "$port"
               echo "$port" > "$PORT_FILE"
               info "端口已修改: $port"
           else error "未安装"; fi ;;
        5) 
           ensure_warp_service && (warp-cli disconnect; sleep 1; warp-cli connect; info "重连完成") ;;
        6) manage_cron ;;
        7) uninstall_warp ;;
        0) exit 0 ;;
        *) warn "无效选项" ;;
    esac
    pause
}

while true; do
    menu
done
