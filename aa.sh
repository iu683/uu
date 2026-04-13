#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

INSTALL_URL="http://download.bt.cn/install/install_panel.sh"
UNINSTALL_URL="http://download.bt.cn/install/bt-uninstall.sh"

install_panel() {
    echo -e "${GREEN}使用国内镜像安装宝塔面板...${RESET}"
    if command -v curl >/dev/null 2>&1; then
        curl -sS -o install_panel.sh "${INSTALL_URL}"
    else
        wget -q -O install_panel.sh "${INSTALL_URL}"
    fi

    chmod +x install_panel.sh
    bt_category=aliyun bash install_panel.sh ed8484bec
    rm -f install_panel.sh
    pause
}

uninstall_panel() {
    echo -e "${GREEN}正在卸载宝塔面板...${RESET}"
    curl -sS -o bt-uninstall.sh "${UNINSTALL_URL}" || wget -q -O bt-uninstall.sh "${UNINSTALL_URL}"
    chmod +x bt-uninstall.sh
    ./bt-uninstall.sh
    rm -f bt-uninstall.sh
    pause
}

pause() {
    read -p $'\033[32m按回车键返回菜单...\033[0m'
    menu
}

menu() {
    clear
    echo -e "${GREEN}=== 宝塔面板管理菜单（国内镜像） ===${RESET}"
    echo -e "${GREEN}1) 安装宝塔面板（国内）${RESET}"
    echo -e "${GREEN}2) 卸载宝塔面板${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p $'\033[32m请选择操作: \033[0m' choice
    case $choice in
        1) install_panel ;;
        2) uninstall_panel ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择，请重新输入${RESET}"; sleep 1; menu ;;
    esac
}

menu
