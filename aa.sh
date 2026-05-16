#!/bin/bash

GREEN="\033[32m"
ORANGE='\033[38;5;208m'
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

menu() {
    clear
    echo -e "${ORANGE}=== 监控管理菜单 ===${RESET}"
    echo -e "${YELLOW}1) NodeGet监控安装${RESET}"
    echo -e "${YELLOW}2) 哪吒监控安装${RESET}"
    echo -e "${YELLOW}3) Komari监控安装${RESET}"
    echo -e "${YELLOW}4) 哪吒关闭SSH${RESET}"
    echo -e "${YELLOW}5) 哪吒Agent管理${RESET}"
    echo -e "${YELLOW}6) KomariAgent管理${RESET}"
    echo -e "${YELLOW}7) NodeGetAgent管理${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p $'\033[32m请选择操作: \033[0m' choice
    case $choice in
        1)
            echo -e "${GREEN}正在安装 NodeGet 监控...${RESET}"
            bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/NodeGetgl.sh)
            pause
            ;;
        2)
            echo -e "${GREEN}正在安装哪吒监控...${RESET}"
            bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/aznezha.sh)
            pause
            ;;
        3)
            echo -e "${GREEN}正在安装 Komari 监控...${RESET}"
            bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/komarigl.sh)
            pause
            ;;
        4)
            echo -e "${GREEN} 哪吒关闭SSH ...${RESET}"
            bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/nezhassh.sh)
            pause
            ;;
        5)
            echo -e "${GREEN}正在安装哪吒 Agent管理...${RESET}"
            bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/NezhaAgent.sh)
            pause
            ;;
        6)
            echo -e "${GREEN}正在安装 Komari Agent管理...${RESET}"
            bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/KomariAgent.sh)
            pause
            ;;
        7)
            echo -e "${GREEN}正在安装 NodeGet Agent管理...${RESET}"
            bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/NodeGetAgent.sh)
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
