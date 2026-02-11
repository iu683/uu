#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

LOCAL_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/beifen.sh"
REMOTE_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/rsynctd.sh"

run_script() {
    url=$1
    name=$2

    echo -e "${GREEN}正在执行 ${name}...${RESET}"
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
    echo -e "${GREEN}     VPS 系统备份管理       ${RESET}"
    echo -e "${GREEN}============================${RESET}"
    echo -e "${GREEN} 1) 本地备份（打包到本机）${RESET}"
    echo -e "${GREEN} 2) 远程备份（rsync同步）${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    echo
    read -p $'\033[32m请选择: \033[0m' choice

    case $choice in
        1) run_script "$LOCAL_URL" "本地备份" ;;
        2) run_script "$REMOTE_URL" "远程备份" ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
