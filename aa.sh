#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

CHECK_URL="https://tcpquality.ibsgss.uk/run"

run_check() {
    mode=$1
    name=$2

    echo -e "${GREEN}正在执行：${name}...${RESET}"
    if [ -z "$mode" ]; then
        bash <(curl -Ls "$CHECK_URL")
    else
        bash <(curl -Ls "$CHECK_URL") "$mode"
    fi
    pause
}

pause() {
    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

menu() {
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈   TCP重传探测工具   ◈     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1) 双栈检测 (IPv4 + IPv6)${RESET}"
    echo -e "${GREEN} 2) 仅检测 IPv4${RESET}"
    echo -e "${GREEN} 3) 仅检测 IPv6${RESET}"
    echo -e "${GREEN} 4) 仅检测 教育网${RESET}"
    echo -e "${GREEN} 5) 国内测速${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    read -p $'\033[32m 请选择: \033[0m' choice

    case $choice in
        1) run_check "" "双栈检测" ;;
        2) run_check "-v4" "IPv4 检测" ;;
        3) run_check "-v6" "IPv6 检测" ;;
        4) run_check "--cernet" "教育网" ;;
        5) run_check "--only-speedtest" "国内测速" ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
