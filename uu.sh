#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

menu() {
    clear
    echo -e "${GREEN}=== GOST Panel ===${RESET}"
    echo -e "${GREEN}1) 安装${RESET}"
    echo -e "${GREEN}2) 卸载${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p $'\033[32m请选择操作: \033[0m' choice
    case $choice in
        1)
            echo -e "${GREEN}正在安装...${RESET}"
            curl -fsSL https://raw.githubusercontent.com/AliceNetworks/gost-panel/main/scripts/install.sh | bash
            pause
            ;;
        2)
            echo -e "${GREEN}正在卸载...${RESET}"
            curl -fsSL -o uninstall.sh https://raw.githubusercontent.com/AliceNetworks/gost-panel/main/scripts/uninstall.sh
            bash uninstall.sh
            pause
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择，请重新输入${RESET}"
            sleep 1
            menu
            ;;
    esac
}

pause() {
    read -p $'\033[32m按回车键返回菜单...\033[0m'
    menu
}

menu
