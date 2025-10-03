#!/bin/bash
# Komari Agent 管理脚本（systemd）
# 文件名可以叫 komari-agent-manager.sh

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

pause() {
    read -p "按回车返回菜单..."
}

show_menu() {
    clear
    echo -e "${GREEN}==Komari Agent 管理菜单==${RESET}"
    echo -e "${GREEN}1) 启动${RESET}"
    echo -e "${GREEN}2) 停止${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看${RESET}"
    echo -e "${GREEN}5) 卸载${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo
}

read_choice() {
    read -p "请输入你的选择: " choice
    case $choice in
        1)
            sudo systemctl start komari-agent
            echo -e "${GREEN}komari-agent 已启动${RESET}"
            pause
            ;;
        2)
            sudo systemctl stop komari-agent
            echo -e "${RED}komari-agent 已停止${RESET}"
            pause
            ;;
        3)
            sudo systemctl restart komari-agent
            echo -e "${YELLOW}komari-agent 已重启${RESET}"
            pause
            ;;
        4)
            sudo systemctl status komari-agent
            pause
            ;;
        5)
            echo -e "${RED}正在卸载 komari-agent...${RESET}"
            sudo systemctl stop komari-agent
            sudo systemctl disable komari-agent
            sudo rm -f /etc/systemd/system/komari-agent.service
            sudo systemctl daemon-reload
            sudo rm -rf /opt/komari /var/log/komari
            echo -e "${RED}卸载完成${RESET}"
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
