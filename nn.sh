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

install_warp() {
    read -rp "请输入 Socks5 端口 (如 40000): " port

    info "安装 WARP..."
    apt update
    apt install -y gnupg curl lsb-release

    curl -s https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor > /usr/share/keyrings/cloudflare-warp.gpg

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp.gpg] \
https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/cloudflare-client.list

    apt update
    apt install -y cloudflare-warp

    info "注册账户..."
    warp-cli registration new --accept-tos

    info "设置 Proxy 模式..."
    warp-cli mode proxy

    info "设置端口: $port"
    warp-cli proxy port "$port"
    echo "$port" > "$PORT_FILE"

    info "使用 MASQUE 协议..."
    warp-cli tunnel protocol set MASQUE

    info "连接 WARP..."
    warp-cli connect

    info "完成 ✔"
    socks5://127.0.0.1:$port
}

status_warp() {
    warp-cli status
}

test_proxy() {
    if [[ ! -f "$PORT_FILE" ]]; then
        error "未找到端口"
        return
    fi
    port=$(cat "$PORT_FILE")
    info "测试代理端口: $port"
    curl -s --proxy socks5://127.0.0.1:$port ifconfig.me || error "失败"
}

change_port() {
    read -rp "新端口: " port
    warp-cli proxy port "$port"
    echo "$port" > "$PORT_FILE"
    info "端口已修改"
}

uninstall_warp() {
    warn "正在卸载 WARP..."

    warp-cli disconnect 2>/dev/null || true

    apt remove -y cloudflare-warp
    apt autoremove -y

    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp.gpg
    rm -f "$PORT_FILE"

    info "卸载完成 ✔"
}

menu() {
    clear
    echo -e "${GREEN}==== WARP 管理 ====${RESET}"
    echo "1) 安装并配置"
    echo "2) 查看状态"
    echo "3) 测试代理"
    echo "4) 修改端口"
    echo "5) 卸载 WARP"
    echo "0) 退出"
    echo
    read -rp "请选择: " num

    case $num in
        1) install_warp ;;
        2) status_warp ;;
        3) test_proxy ;;
        4) change_port ;;
        5) uninstall_warp ;;
        0) exit 0 ;;
        *) warn "无效选项" ;;
    esac

    pause
}

while true; do
    menu
done
