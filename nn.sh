#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

INSTALL_URL="https://raw.githubusercontent.com/admintors/emby-proxy-alpine-lite/main/install.sh"
UNINSTALL_URL="https://raw.githubusercontent.com/admintors/emby-proxy-alpine-lite/main/uninstall.sh"

install_emby() {
    echo -e "${GREEN}正在安装 Emby 反代 (Alpine)...${RESET}"
    apk add --no-cache curl
    curl -fsSL -o install.sh $INSTALL_URL
    bash install.sh
    pause
}

uninstall_emby() {
    echo -e "${GREEN}正在卸载 Emby 反代 (Alpine)...${RESET}"
    curl -fsSL -o uninstall.sh $UNINSTALL_URL
    bash uninstall.sh
    pause
}

pause() {
    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

menu() {
    clear
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN}     Emby 反代管理 (Alpine)     ${RESET}"
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN} 1) 安装 Emby 反代${RESET}"
    echo -e "${GREEN} 2) 卸载 Emby 反代${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    read -p $'\033[32m 请选择 (0-2): \033[0m' choice

    case $choice in
        1) install_emby ;;
        2) uninstall_emby ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
