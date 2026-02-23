#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

NGINX_URL="https://raw.githubusercontent.com/bear4f/emby-proxy-toolbox/main/emby-proxy-toolbox.sh"
CADDY_URL="https://raw.githubusercontent.com/AiLi1337/install_caddy_emby/main/install_caddy_emby.sh"

run_script() {
    url=$1
    name=$2
    echo -e "${GREEN}正在启动：${name}...${RESET}"
    bash <(curl -fsSL "$url")
    pause
}

pause() {
    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

menu() {
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}        Emby 反代管理         ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1) Nginx 反向代理${RESET}"
    echo -e "${GREEN} 2) Caddy 反向代理${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    read -p $'\033[32m请选择 (0-2): \033[0m' choice

    case $choice in
        1) run_script "$NGINX_URL" "Nginx 反代部署" ;;
        2) run_script "$CADDY_URL" "Caddy 反代部署" ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
