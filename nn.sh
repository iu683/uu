#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

SCRIPT_URL="https://v6.gh-proxy.org/https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh"

enable_bbr() {
    echo -e "${GREEN}正在启用 BBR + TCP 优化...${RESET}"
    bash <(curl -sL $SCRIPT_URL)
    pause
}

disable_bbr() {
    echo -e "${GREEN}正在卸载优化，恢复默认...${RESET}"
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
    echo -e "${GREEN}      BBR + TCP 优化管理        ${RESET}"
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN} 1) 启用 BBR + TCP 优化${RESET}"
    echo -e "${GREEN} 2) 卸载优化 (恢复默认)${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    read -p $'\033[32m 请选择: \033[0m' choice

    case $choice in
        1) enable_bbr ;;
        2) disable_bbr ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
