#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/vv.sh"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}请使用 root 用户运行！${RESET}"
        exit 1
    fi
}

check_curl() {
    if ! command -v curl &>/dev/null; then
        echo -e "${YELLOW}未检测到 curl，正在安装...${RESET}"
        apt update && apt install -y curl || yum install -y curl
    fi
}

install_SS() {
    echo -e "${GREEN}正在安装 Shadowsocks ...${RESET}"
    bash <(curl -fsSL $SCRIPT_URL)
    pause
}

uninstall_SS() {
    echo -e "${GREEN}正在卸载 Shadowsocks ...${RESET}"
    bash <(curl -fsSL $SCRIPT_URL) uninstall
    pause
}

show_sub() {
    if [[ -f /etc/xray/node.txt ]]; then
        echo -e "${GREEN}订阅链接如下：${RESET}"
        cat /etc/xray/node.txt
    else
        echo -e "${RED}未找到订阅文件！${RESET}"
    fi
    pause
}

pause() {
    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

menu() {
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}   Shadowsocks 管理工具      ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1) 安装 Shadowsocks${RESET}"
    echo -e "${GREEN} 2) 卸载 Shadowsocks${RESET}"
    echo -e "${GREEN} 3) 查看订阅链接${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"

    read -p $'\033[32m 请选择: \033[0m' choice

    case $choice in
        1) install_SS ;;
        2) uninstall_SS ;;
        3) show_sub ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            menu
            ;;
    esac
}

# ====== 执行入口 ======
check_root
check_curl
menu
