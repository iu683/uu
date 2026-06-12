#!/bin/bash

# ==========================================
# 颜色定义
# ==========================================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ==========================================
# 代理与 URL 配置
# ==========================================
# 代理列表（包含空字符串代表直连）
GITHUB_PROXIES=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

NGINX_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/Alpine/APNginxbackup.sh"
CADDY_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/Alpine/APCaddybackup.sh"
ACME_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/Alpine/APAcmebackup.sh"

# ==========================================
# 工具函数
# ==========================================
# 暂停等待
pause() {
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

# 核心下载与无痕执行函数（支持多代理自动轮询容灾）
run_script() {
    local url=$1
    local name=$2
    local script_content=""
    local full_url=""

    echo -e "${YELLOW}正在尝试连接并加载 [${name}] ...${RESET}"

    # 遍历代理列表进行尝试
    for proxy in "${GITHUB_PROXIES[@]}"; do
        full_url="${proxy}${url}"
        
        # 打印当前尝试的连接状态
        if [ -z "$proxy" ]; then
            echo
        else
            echo -e "-> 正在尝试代理: ${proxy}"
        fi

        # 发起请求
        if script_content=$(curl -fsSL --connect-timeout 5 "$full_url") && [ -n "$script_content" ]; then
            # 使用 bash 执行脚本内容
            bash <(echo "$script_content")
            pause
            return 0
        fi
    done

    # 所有代理均失败
    echo -e "${RED}错误：所有直连与代理节点均尝试失败，请检查网络设置。${RESET}"
    pause
    return 1
}

# ==========================================
# 主菜单函数
# ==========================================
menu() {
    while true; do
        clear
        echo -e "${GREEN}============================${RESET}"
        echo -e "${GREEN}   ◈  证书备份与恢复管理  ◈   ${RESET}"
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
