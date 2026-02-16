#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

NGINX_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/nginxbackup.sh"
CAADY_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/caadybackup.sh"

run_script() {
    url=$1
    name=$2
    echo -e "${GREEN}正在执行：${name}...${RESET}"
    bash <(curl -fsSL "$url")
    pause
}

pause() {
    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

menu() {
    clear
    echo -e "${GREEN}============================${RESET}"
    echo -e "${GREEN}   证书备份与恢复管理      ${RESET}"
    echo -e "${GREEN}============================${RESET}"
    echo -e "${GREEN}1) Nginx 证书备份与恢复${RESET}"
    echo -e "${GREEN}2) Caady 证书备份与恢复${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p $'\033[32m请选择 (0-2): \033[0m' choice
    case $choice in
        1) run_script "$NGINX_URL" "Nginx 证书备份与恢复" ;;
        2) run_script "$CAADY_URL" "Caady 证书备份与恢复" ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
