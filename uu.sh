#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 代理前缀
PROXY="https://v6.gh-proxy.org/"

# 脚本 URL 定义
NGINX_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/nginxbackup.sh"
CADDY_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/caadybackup.sh"
ACME_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/acmebackup.sh"

# 基础工具函数：暂停等待
pause() {
    echo ""
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

# 核心下载与无痕执行函数（含自动容灾代理）
run_script() {
    local url=$1
    local name=$2
    local script_content=""
    
    if script_content=$(curl -fsSL "$url") && [ -n "$script_content" ]; then
        bash <(echo "$script_content")
        pause
        return 0
    fi
    
    if script_content=$(curl -fsSL "${PROXY}${url}") && [ -n "$script_content" ]; then
        bash <(echo "$script_content")
        pause
        return 0
    fi
    
    echo -e "${RED}错误：直连与代理均失败，请检查网络设置。${RESET}"
    pause
    return 1
}

# 主菜单函数
menu() {
    while true; do
        clear
        echo -e "${GREEN}============================${RESET}"
        echo -e "${GREEN}    证书备份与恢复管理      ${RESET}"
        echo -e "${GREEN}============================${RESET}"
        echo -e "${GREEN}1) Nginx 证书备份与恢复${RESET}"
        echo -e "${GREEN}2) Caddy 证书备份与恢复${RESET}"
        echo -e "${GREEN}3) ACME 证书备份与恢复${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        echo -e "${GREEN}============================${RESET}"

        read -r -p $'\033[32m请选择: \033[0m' choice

        case $choice in
            1) run_script "$NGINX_URL" "Nginx 证书备份与恢复" ;;
            2) run_script "$CADDY_URL" "Caddy 证书备份与恢复" ;;
            3) run_script "$ACME_URL" "ACME 证书备份与恢复" ;;
            0) 
                echo -e "${GREEN}感谢使用，再见！${RESET}"
                exit 0 
                ;;
            *)
                echo -e "${RED}输入错误，请重新选择...${RESET}"
                sleep 1
                ;;
        esac
    done
}

# 启动菜单
menu
