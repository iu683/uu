#!/bin/bash

GREEN='\033[0;32m'
LIGHT_GREEN='\033[1;32m'
YELLOW="\033[33m"
RED="\033[31m"
NC='\033[0;0m' # 无颜色

# 菜单主循环
while true; do
    clear
    # 检测安装状态
    if [ -d "/opt/nexora-panel" ]; then
        STATUS="${YELLOW}[已安装]${NC}"
    else
        STATUS="${RED}[未安装]${NC}"
    fi

    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN}    ◈  Nexora-VPN 管理菜单  ◈   ${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN} 当前状态: ${STATUS}"
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN} 1. 安装 Nexora-VPN${NC}"
    echo -e "${GREEN} 2. 卸载 Nexora-VPN${NC}"
    echo -e "${GREEN} 0. 退出${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e -n "${GREEN} 请输入选项: ${NC}"
    read -r opt

    case $opt in
        1)
            echo -e "\n${GREEN}开始安装 Nexora-VPN...${NC}\n"
            bash <(curl -fsSL https://raw.githubusercontent.com/nexora-vpn/panel/main/install.sh)
            echo -e "\n${GREEN}安装完成${NC}"
            echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        2)
            echo -e "\n${GREEN}开始卸载 Nexora-VPN...${NC}\n"
            bash <(curl -fsSL https://raw.githubusercontent.com/nexora-vpn/panel/main/install.sh) --uninstall
            echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "\n${GREEN}无效选项，请重新输入${NC}"
            sleep 2
            ;;
    esac
done
