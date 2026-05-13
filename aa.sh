#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

SCRIPT_URL="https://install.nodeget.com"

install_agent() {
    echo -e "${GREEN}正在安装 NodeGet Agent...${RESET}"
    bash <(curl -sL $SCRIPT_URL) install-agent
    pause
}

update_agent() {
    echo -e "${GREEN}正在更新 NodeGet Agent...${RESET}"
    bash <(curl -sL $SCRIPT_URL) update-agent
    pause
}

uninstall_agent() {
    echo -e "${GREEN}正在卸载 NodeGet Agent...${RESET}"
    bash <(curl -sL $SCRIPT_URL) uninstall-agent
    pause
}

pause() {
    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

menu() {
    clear
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN}      NodeGet Agent 管理        ${RESET}"
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN} 1) 安装 Agent${RESET}"
    echo -e "${GREEN} 2) 更新 Agent${RESET}"
    echo -e "${GREEN} 3) 查看日志${RESET}"
    echo -e "${GREEN} 4) 卸载 Agent${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    read -p $'\033[32m 请选择: \033[0m' choice

    case $choice in
        1) install_agent ;;
        2) update_agent ;;
        3) cat /var/log/nodeget-agent/app.log ;;
        4) uninstall_agent ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
