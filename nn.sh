#!/bin/bash
# Nezha Agent 管理脚本（全绿菜单）
# 文件名可以叫 nezha-agent-manager.sh

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

pause() {
    read -p "${YELLOW}按回车返回菜单...${RESET}"
}

show_menu() {
    clear
    echo -e "${GREEN}== Nezha Agent 管理菜单===${GREEN}"
    echo -e "${GREEN}1) 启动${GREEN}"
    echo -e "${GREEN}2) 停止${GREEN}"
    echo -e "${GREEN}3) 重启${GREEN}"
    echo -e "${GREEN}4) 查看状态${GREEN}"
    echo -e "${GREEN}5) 卸载${GREEN}"
    echo -e "${GREEN}0) 退出${RESET}"
}
read_choice() {
    read -p "${GREEN}请输入你的选择 [0-4]: ${RESET}" choice
    case $choice in
        1)
            sudo systemctl start nezha-agent
            echo -e "${GREEN}nezha-agent 已启动${RESET}"
            pause
            ;;
        2)
            sudo systemctl stop nezha-agent
            echo -e "${RED}nezha-agent 已停止${RESET}"
            pause
            ;;
        3)
            sudo systemctl restart nezha-agent
            echo -e "${YELLOW}nezha-agent 已重启${RESET}"
            pause
            ;;
        4)
            sudo systemctl status nezha-agent
            pause
            ;;
        5)
            echo -e "${GREEN}正在卸载哪吒 Agent...${RESET}"
            bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/app-store/main/nzagent.sh)
            pause
            ;;
        0)
            echo -e "${GREEN}退出...${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择，请重新输入${RESET}"
            pause
            ;;
    esac
}

# 主循环
while true; do
    show_menu
    read_choice
done
