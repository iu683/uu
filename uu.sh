#!/bin/bash

GREEN='\033[0;32m'
LIGHT_GREEN='\033[1;32m'
NC='\033[0;0m' # 无颜色

# 菜单主循环
while true; do
    clear
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN}  ◈  mini-sb-agent 管理菜单  ◈   ${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN} 1. 安装 mini-sb-agent"
    echo -e "${GREEN} 2. 卸载 mini-sb-agent"
    echo -e "${GREEN} 0. 退出"
    echo -e "${GREEN}=================================${NC}"
    echo -e -n "${GREEN}请输入选项: ${NC}"
    read -r opt

    case $opt in
        1)
            echo -e "\n${GREEN}[*] 开始安装 mini-sb-agent...${NC}\n"
            curl -fsSL https://raw.githubusercontent.com/ashvvvvv/mini-sb-agent/master/install.sh | sh
            echo -e "\n${GREEN}[+] 安装流程执行完毕。${NC}"
            echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        2)
            echo -e "\n${GREEN}[*] 开始卸载 mini-sb-agent...${NC}\n"
            bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/uninstallminisb.sh)
            echo -e "\n${GREEN}[+] 卸载流程执行完毕。${NC}"
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
