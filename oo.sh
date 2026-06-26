#!/bin/bash

GREEN='\033[0;32m'
LIGHT_GREEN='\033[1;32m'
NC='\033[0;0m' # 无颜色

# 菜单主循环
while true; do
    clear
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN}    ◈  TrafficCop 管理菜单  ◈     ${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN} 1. 安装 TrafficCop${NC}"
    echo -e "${GREEN} 2. 紧急解除网速限制${NC}"
    echo -e "${GREEN} 3. 卸载 TrafficCop${NC}"
    echo -e "${GREEN} 0. 退出${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e -n "${GREEN} 请输入选项: ${NC}"
    read -r opt

    case $opt in
        1)
            echo -e "\n${GREEN}开始安装 TrafficCop...${NC}\n"
            bash <(curl -sL https://raw.githubusercontent.com/ypq123456789/TrafficCop/main/trafficcop-manager.sh)
            echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        2)
            echo -e "\n${GREEN}开始解除网速限制...${NC}\n"
            sudo curl -sSL https://raw.githubusercontent.com/ypq123456789/TrafficCop/main/remove_traffic_limit.sh | sudo bash
            echo -e "\n${GREEN}解除限制完成${NC}"
            echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        3)
            echo -e "\n${GREEN}开始卸载 TrafficCop...${NC}\n"
            sudo pkill -f traffic_monitor.sh
            sudo rm -rf /root/TrafficCop
            sudo tc qdisc del dev $(ip route | grep default | cut -d ' ' -f 5) root
            echo -e "\n${GREEN}卸载完成${NC}"
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
