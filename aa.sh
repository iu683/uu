#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

menu() {
    clear
    echo -e "${GREEN}=== DD飞牛管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装必要工具${RESET}"
    echo -e "${GREEN}2) DD飞牛系统${RESET}"
    echo -e "${GREEN}3) 重启系统${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p $'\033[32m请选择操作: \033[0m' choice
    case $choice in
        1)
            echo -e "${GREEN}正在下载重装系统脚本...${RESET}"
            curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh || wget -O reinstall.sh https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh
            chmod +x reinstall.sh
            echo -e "${GREEN}✅ 脚本已下载完成，可以执行 DD 飞牛系统${RESET}"
            pause
            ;;
        2)
            if [ ! -f "reinstall.sh" ]; then
                echo -e "${RED}❌ 未找到 reinstall.sh，请先执行 [1 安装重装系统脚本]${RESET}"
            else
                echo -e "${YELLOW}重要提示：执行 DD 飞牛系统会重装系统并清空所有数据！${RESET}"
                echo -e "${YELLOW}此操作不可逆，请谨慎选择！${RESET}"
                read -p $'\033[31m是否继续？(y/N): \033[0m' confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    echo -e "${GREEN}🚀 正在执行 DD 飞牛系统...${RESET}"
                    bash reinstall.sh fnos
                else
                    echo -e "${RED}已取消操作${RESET}"
                fi
            fi
            pause
            ;;
        3)
            reboot
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
