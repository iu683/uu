#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

MASTER_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/dockerfleetmaster.sh"
NODE_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/dockerfleetnode.sh"

install_master() {
    echo -e "${GREEN}正在部署 TelegramBot 主控...${RESET}"
    bash <(curl -sL $MASTER_URL)
    pause
}

install_node() {
    echo -e "${GREEN}正在部署 TelegramBot 节点...${RESET}"
    bash <(curl -sL $NODE_URL)
    pause
}

pause() {
    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

menu() {
    clear
    echo -e "${GREEN}========================${RESET}"
    echo -e "${GREEN} ◈ Docker  TGBot管理 ◈  ${RESET}"
    echo -e "${GREEN}========================${RESET}"
    echo -e "${GREEN} 1) 部署主控 (Master)${RESET}"
    echo -e "${GREEN} 2) 部署节点 (Node)${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    echo -e "${GREEN}========================${RESET}"
    read -p $'\033[32m 请选择: \033[0m' choice

    case $choice in
        1) install_master ;;
        2) install_node ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
