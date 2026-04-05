#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

menu() {
    clear
    echo -e "${GREEN}=== 1Panel 面板管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装 1Panel${RESET}"
    echo -e "${GREEN}2) 1Panel 菜单管理${RESET}"
    echo -e "${GREEN}3) 卸载 1Panel${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p $'\033[32m请选择操作: \033[0m' choice
    case $choice in
        1)
            echo -e "${GREEN}正在安装 1Panel...${RESET}"
            bash -c "$(curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)"
            pause
            ;;
        2)
            echo -e "${GREEN}1Panel 菜单管理...${RESET}"
            bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Panel/1PanelCD.sh)
            pause
            ;;
        3)
            echo -e "${GREEN}正在卸载 1Panel...${RESET}"
            1pctl uninstall
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
