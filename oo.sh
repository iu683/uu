#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 代理前缀
PROXY="https://v6.gh-proxy.org/"

# 基础工具函数：暂停等待
pause() {
    echo ""
    read -r -p $'\033[32m按回车键返回菜单...\033[0m'
}

# 核心下载与执行函数（完美修复 bash <(curl) 的容灾切换 Bug）
fetch_and_run() {
    local script_url="$1"
    local script_content=""
    
    # 先把内容存入变量，这样可以准确捕捉 curl 的状态码
    if script_content=$(curl -fsSL "$script_url") && [ -n "$script_content" ]; then
        bash <(echo "$script_content")
        return 0
    fi
    
    if script_content=$(curl -fsSL "${PROXY}${script_url}") && [ -n "$script_content" ]; then
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
        echo -e "${GREEN}=== 网络工具菜单 ===${RESET}"
        echo -e "${GREEN}1) 网络测速 speedtest${RESET}"
        echo -e "${GREEN}2) 路由追踪 nexttrace${RESET}"
        echo -e "${GREEN}3) 网络性能测试 iperf3${RESET}"
        echo -e "${GREEN}4) 网络诊断工具 MTR${RESET}"
        echo -e "${GREEN}5) 大小包诊断工具${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        echo -e "${GREEN}====================${RESET}"
        
        read -r -p $'\033[32m请选择操作: \033[0m' choice
        case $choice in
            1)
                echo -e "${GREEN}\n正在运行 speedtest 网络测速...${RESET}"
                fetch_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/Speedtest.sh"
                pause
                ;;
            2)
                echo -e "${GREEN}\n正在运行 nexttrace 路由追踪...${RESET}"
                fetch_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/NextTrace.sh"
                pause
                ;;
            3)
                echo -e "${GREEN}\n正在运行 网络性能测试 iperf3...${RESET}"
                fetch_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/iperf3.sh"
                pause
                ;;
            4)
                echo -e "${GREEN}\n正在运行 网络诊断工具 MTR...${RESET}"
                fetch_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/mtr.sh"
                pause
                ;;
            5)
                echo -e "${GREEN}\n正在运行 大小包诊断工具...${RESET}"
                fetch_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/DXbao.sh"
                pause
                ;;
            0)
                echo -e "${GREEN}感谢使用，再见！${RESET}"
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
