#!/bin/bash

GREEN='\033[0;32m'
LIGHT_GREEN='\033[1;32m'
NC='\033[0;0m' # 无颜色

# 菜单主循环
while true; do
    clear
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN}   ◈  IP-Sentinel 管理菜单  ◈     ${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN} 1. 部署 IP-Sentinel Master(服务端)${NC}"
    echo -e "${GREEN} 2. 部署 IP-Sentinel Agent (客户端)${NC}"
    echo -e "${GREEN} 3. 卸载 IP-Sentinel Agent${NC}"
    echo -e "${GREEN} 0. 退出"
    echo -e "${GREEN}=================================${NC}"
    echo -e -n "${GREEN} 请输入选项: ${NC}"
    read -r opt

    case $opt in
        1)
            echo -e "\n${GREEN}开始部署 IP-Sentinel Master...${NC}\n"
            bash -c "$(curl -fsSL https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/master/install_master.sh)"
            echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        2)
            echo -e "\n${GREEN}开始部署 IP-Sentinel Agent...${NC}\n"
            bash -c "$(curl -fsSL https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/install.sh)"
            echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        3)
            echo -e "\n${GREEN}开始卸载 IP-Sentinel Agent...${NC}\n"
            if [ -f /opt/ip_sentinel/core/uninstall.sh ]; then
                bash /opt/ip_sentinel/core/uninstall.sh
                echo -e "\n${GREEN}Agent 卸载完成${NC}"
            else
                echo -e "\n${GREEN}未检测到Agent，请确认 Agent 是否已安装。${NC}"
            fi
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
