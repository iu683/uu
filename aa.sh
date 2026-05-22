#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

SCRIPT_URL="https://raw.githubusercontent.com/lidebyte/bashshell/refs/heads/main/mosdns-x-manager.sh"

install_dns() {
    echo -e "${GREEN}正在安装 DNS 优化...${RESET}"
    bash <(curl -sL $SCRIPT_URL) install
    pause
}

update_dns() {
    echo -e "${GREEN}正在更新 DNS 优化...${RESET}"
    bash <(curl -sL $SCRIPT_URL) update
    pause
}

status_dns() {
    echo -e "${GREEN}正在查看 DNS 优化状态...${RESET}"
    bash <(curl -sL $SCRIPT_URL) status
    pause
}

uninstall_dns() {
    echo -e "${GREEN}正在卸载 DNS 优化...${RESET}"
    bash <(curl -sL $SCRIPT_URL) uninstall
    pause
}

pause() {
    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

menu() {
    clear
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN}         DNS 优化管理           ${RESET}"
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN} 1) 安装 DNS 优化${RESET}"
    echo -e "${GREEN} 2) 更新 DNS 优化${RESET}"
    echo -e "${GREEN} 3) 查看运行状态${RESET}"
    echo -e "${GREEN} 4) 卸载 DNS 优化${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    read -p $'\033[32m 请选择: \033[0m' choice

    case $choice in
        1) install_dns ;;
        2) update_dns ;;
        3) status_dns ;;
        4) uninstall_dns ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
