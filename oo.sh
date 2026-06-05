#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 代理前缀
PROXY="https://v6.gh-proxy.org/"
# 脚本基础路径
BASE_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS"

# 基础工具函数：暂停等待
pause() {

    read -r -p $'\033[32m  按回车键返回菜单...\033[0m'
}

# 核心下载与无痕执行函数（完美支持进程替换的容灾切换）
fetch_and_run() {
    local script_name="$1"
    local full_url="${BASE_URL}/${script_name}"
    local script_content=""
    
    # 抓取并验证内容是否为空
    if script_content=$(curl -fsSL "$full_url") && [ -n "$script_content" ]; then
        bash <(echo "$script_content")
        return 0
    fi
    
    if script_content=$(curl -fsSL "${PROXY}${full_url}") && [ -n "$script_content" ]; then
        bash <(echo "$script_content")
        return 0
    fi
    
    echo -e "${RED}错误：直连与代理均失败，请检查网络设置。${RESET}"
    return 1
}

# 主菜单函数
menu() {
    while true; do
        clear
        echo -e "${GREEN}=== 系统监控管理菜单 ===${RESET}"
        echo -e "${GREEN} 1) 查看端口${RESET}"
        echo -e "${GREEN} 2) 释放端口${RESET}"
        echo -e "${GREEN} 3) 查看进程${RESET}"
        echo -e "${GREEN} 4) 删除进程${RESET}"
        echo -e "${GREEN} 5) 查看自启动服务${RESET}"
        echo -e "${GREEN} 6) 自启动服务管理${RESET}"
        echo -e "${GREEN} 7) 国家IP屏蔽${RESET}"
        echo -e "${GREEN} 8) 磁盘占用${RESET}"
        echo -e "${GREEN} 9) 挂载磁盘${RESET}"
        echo -e "${GREEN}10) 安全扫描${RESET}"
        echo -e "${GREEN} 0) 退出${RESET}"
        echo -e "${GREEN}========================${RESET}"
        
        read -r -p $'\033[32m 请选择操作: \033[0m' choice
        case $choice in
            1)
                echo -e "${GREEN}\n正在查看端口...${RESET}"
                fetch_and_run "port.sh"
                pause
                ;;
            2)
                echo -e "${GREEN}\n正在释放端口...${RESET}"
                fetch_and_run "killport.sh"
                pause
                ;;
            3)
                echo -e "${GREEN}\n正在查看进程...${RESET}"
                fetch_and_run "psaux.sh"
                pause
                ;;
            4)
                echo -e "${GREEN}\n正在删除进程...${RESET}"
                fetch_and_run "killprocess.sh"
                pause
                ;;
            5)
                echo -e "${GREEN}\n正在查看自启动服务...${RESET}"
                fetch_and_run "serviceos.sh"
                pause
                ;;
            6)
                echo -e "${GREEN}\n正在管理自启动服务...${RESET}"
                fetch_and_run "killserviceos.sh"
                pause
                ;;
            7)
                echo -e "${GREEN}\n正在国家IP屏蔽...${RESET}"
                fetch_and_run "GeoFirewallos.sh"
                pause
                ;;
            8)
                echo -e "${GREEN}\n正在查看磁盘占用...${RESET}"
                fetch_and_run "DHGL.sh"
                pause
                ;;
            9)
                echo -e "${GREEN}\n正在挂载磁盘...${RESET}"
                fetch_and_run "DISKGL.sh"
                pause
                ;;
            10)
                echo -e "${GREEN}\n正在安全扫描...${RESET}"
                fetch_and_run "Security.sh"
                pause
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入...${RESET}"
                sleep 1
                ;;
        esac
    done
}

# 启动菜单
menu
