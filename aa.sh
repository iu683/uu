#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

MASTER_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/master/install_master.sh"
AGENT_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/core/install.sh"
UNINSTALL_SCRIPT="/opt/ip_sentinel/core/uninstall.sh"

install_master() {
    echo -e "${GREEN}正在部署 IP-Sentinel Master...${RESET}"
    bash <(curl -sL $MASTER_URL)
    pause
}

install_agent() {
    echo -e "${GREEN}正在部署 IP-Sentinel Agent...${RESET}"
    bash <(curl -sL $AGENT_URL)
    pause
}

uninstall_agent() {
    if [ -f "$UNINSTALL_SCRIPT" ]; then
        echo -e "${GREEN}正在卸载 IP-Sentinel Agent...${RESET}"
        bash $UNINSTALL_SCRIPT
    else
        echo -e "${RED}未检测到 Agent 安装${RESET}"
    fi
    pause
}

pause() {
    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

menu() {
    clear
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN}        IP-Sentinel 管理        ${RESET}"
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN} 1) 部署 Master${RESET}"
    echo -e "${GREEN} 2) 部署 Agent${RESET}"
    echo -e "${GREEN} 3) 卸载 Agent${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    read -p $'\033[32m 请选择: \033[0m' choice

    case $choice in
        1) install_master ;;
        2) install_agent ;;
        3) uninstall_agent ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
