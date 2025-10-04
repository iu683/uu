#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

menu() {
    clear
    echo -e "${GREEN}=== 哪吒 SSH 管理 ===${RESET}"
    echo -e "${GREEN}1) V0 关闭 SSH 功能${RESET}"
    echo -e "${GREEN}2) V1 关闭 SSH 功能${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p $'\033[32m请选择操作: \033[0m' choice
    case $choice in
        1)
            echo -e "${GREEN}正在关闭 V0 哪吒 Agent 的 SSH 功能...${RESET}"
            sed -i 's|^ExecStart=.*|& --disable-command-execute --disable-auto-update --disable-force-update|' /etc/systemd/system/nezha-agent.service
            systemctl daemon-reload
            systemctl restart nezha-agent
            echo -e "${GREEN}✅ V0 SSH 功能已关闭${RESET}"
            pause
            ;;
        2)
            echo -e "${GREEN}正在关闭 V1 哪吒 Agent 的 SSH 功能...${RESET}"
            sed -i 's/disable_command_execute: false/disable_command_execute: true/' /opt/nezha/agent/config.yml
            systemctl restart nezha-agent
            echo -e "${GREEN}✅ V1 SSH 功能已关闭${RESET}"
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
