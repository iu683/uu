#!/usr/bin/env bash

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
RESET='\033[0m'

SCRIPT_URL="https://v6.gh-proxy.org/https://raw.githubusercontent.com/hkfires/onekey-tun2socks/main/onekey-tun2socks.sh"
SCRIPT_NAME="onekey-tun2socks.sh"

info()  { echo -e "${GREEN}[信息] $1${RESET}"; }
error() { echo -e "${RED}[错误] $1${RESET}"; }

download_script() {
    curl -L "$SCRIPT_URL" -o "$SCRIPT_NAME" || {
        error "脚本下载失败"
        exit 1
    }
    chmod +x "$SCRIPT_NAME"
}

install_tun2socks() {
    info "开始安装 tun2socks..."
    download_script
    sudo ./"$SCRIPT_NAME" -i custom
}

remove_tun2socks() {
    info "开始卸载 tun2socks..."
    download_script
    sudo ./"$SCRIPT_NAME" -r
}

start_service() {
    info "启动服务..."
    systemctl start tun2socks.service
}

stop_service() {
    info "停止服务..."
    systemctl stop tun2socks.service
}

restart_service() {
    info "重启服务..."
    systemctl restart tun2socks.service
}

status_service() {
    info "服务状态："
    systemctl status tun2socks.service
}

logs_service() {
    info "查看日志（按 q 退出）"
    journalctl -u tun2socks.service -e
}

menu() {
    clear
    echo -e "${GREEN}"
    echo "=============================="
    echo "   tun2socks 管理菜单"
    echo "=============================="
    echo "1. 安装 tun2socks"
    echo "2. 卸载 tun2socks"
    echo "------------------------------"
    echo "3. 启动服务"
    echo "4. 停止服务"
    echo "5. 重启服务"
    echo "------------------------------"
    echo "6. 查看服务状态"
    echo "7. 查看日志"
    echo "------------------------------"
    echo "0. 退出"
    echo "=============================="
    echo -e "${RESET}"
}

while true; do
    menu
    read -rp "$(echo -e ${GREEN}请输入选项: ${RESET})" choice

    case "$choice" in
        1) install_tun2socks ;;
        2) remove_tun2socks ;;
        3) start_service ;;
        4) stop_service ;;
        5) restart_service ;;
        6) status_service ;;
        7) logs_service ;;
        0) exit 0 ;;
        *) error "无效选项" ;;
    esac

    echo
    read -rp "按回车继续..."
done
