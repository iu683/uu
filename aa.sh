#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0;7m' 
RESET='\033[0m'

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 权限运行此脚本！${RESET}"
    exit 1
fi

SCRIPT_NAME="install-panel.sh"
URL="https://raw.githubusercontent.com/VipMaxxxx/payincus/main/scripts/install-panel.sh"

# 下载核心脚本的函数
check_and_download() {
    if [ ! -f "$SCRIPT_NAME" ]; then
        echo -e "${YELLOW}正在从 GitHub 下载核心安装...${RESET}"
        # 检查并安装 curl
        if ! command -v curl &> /dev/null; then
            echo -e "${YELLOW}未检测到 curl，正在自动安装...${RESET}"
            if command -v apt &> /dev/null; then
                apt update && apt install curl -y
            elif command -v yum &> /dev/null; then
                yum install curl -y
            fi
        fi
        
        curl -fsSL "$URL" -o "$SCRIPT_NAME"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}下载成功！${RESET}"
            chmod +x "$SCRIPT_NAME"
        else
            echo -e "${RED}下载失败，请检查网络或 GitHub 连接！${RESET}"
            exit 1
        fi
    fi
}

# 主菜单循环
while true; do
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}   ◈  PayIncus  管理面板 ◈   ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1. 安装 PayIncus${RESET}"
    echo -e "${GREEN}2. 升级 PayIncus${RESET}"
    echo -e "${GREEN}3. 卸载 PayIncus${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}" 
    read -p "$(echo -e "${GREEN}请输入选项: ${RESET}")" choice
    case $choice in
        1)
            echo -e "${GREEN}===> 开始安装 PayIncus...${RESET}"
            check_and_download
            bash "$SCRIPT_NAME"
            ;;
        2)
            echo -e "${YELLOW}===> 开始升级 PayIncus...${RESET}"
            check_and_download
            bash "$SCRIPT_NAME" --upgrade
            ;;
        3)
            echo -e "${RED}===> 警告：即将卸载 PayIncus 面板！${RESET}"
            read -p "确定要继续吗？(y/n): " confirm
            if [[ "$confirm" == [yY] || "$confirm" == [yY][eE][sS] ]]; then
                check_and_download
                bash "$SCRIPT_NAME" --uninstall
            else
                echo -e "${GREEN}已取消卸载。${RESET}"
            fi
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请输入 0 到 4 之间的数字！${RESET}"
            ;;
    esac
    
    read -n 1 -s -r -p "按任意键返回主菜单..."
done
