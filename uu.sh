#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

CHECK_URL="https://Hardware.Check.Place"

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
    echo -e "${GREEN}        硬件质量体检工具        ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1) 标准检测${RESET}"
    echo -e "${GREEN} 2) 硬盘模式${RESET}"
    echo -e "${GREEN} 3) 深度模式${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    read -p $'\033[32m 请选择: \033[0m' choice

    case $choice in
        1) run_check "" "标准检测" ;;
        2) run_check "-D" "硬盘模式" ;;
        3) run_check "-V" "深度模式" ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
