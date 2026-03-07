#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

SCRIPT_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/Alpine/APReality.sh"

install_reality() {
    echo -e "${GREEN}正在安装 Reality...${RESET}"
    bash <(curl -sL $SCRIPT_URL)
    pause
}

uninstall_reality() {
    echo -e "${GREEN}正在卸载 Reality...${RESET}"
    bash <(curl -sL $SCRIPT_URL) uninstall
    pause
}

pause() {
    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

menu() {
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}        Reality 管理工具      ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1) 安装 Reality${RESET}"
    echo -e "${GREEN} 2) 卸载 Reality${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    read -p $'\033[32m 请选择: \033[0m' choice

    case $choice in
        1) install_reality ;;
        2) uninstall_reality ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
