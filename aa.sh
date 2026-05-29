#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

SCRIPT_URL="https://update.samwaf.com/latest/install_samwaf.sh"

install_samwaf() {
    echo -e "${GREEN}正在安装 SamWaf 网站防火墙...${RESET}"
    curl -sSO $SCRIPT_URL
    bash install_samwaf.sh install
    pause
}

uninstall_samwaf() {
    echo -e "${GREEN}正在卸载 SamWaf 网站防火墙...${RESET}"
    curl -sSO $SCRIPT_URL
    bash install_samwaf.sh uninstall
    pause
}

pause() {
    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

menu() {
    clear
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN}      SamWaf 网站防火墙管理     ${RESET}"
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN} 1) 安装 SamWaf${RESET}"
    echo -e "${GREEN} 2) 卸载 SamWaf${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    echo
    read -p $'\033[32m 请选择: \033[0m' choice

    case $choice in
        1) install_samwaf ;;
        2) uninstall_samwaf ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
