#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 权限运行此脚本！${RESET}"
    exit 1
fi

SCRIPT_NAME="install-panel.sh"
# 原始的 GitHub 相对路径
RAW_PATH="VipMaxxxx/payincus/main/scripts/install-panel.sh"

# GitHub 代理节点列表（第一个为空代表直连）
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

# 下载核心脚本的函数（带代理重试机制）
check_and_download() {
    if [ ! -f "$SCRIPT_NAME" ]; then
        # 检查并安装 curl
        if ! command -v curl &> /dev/null; then
            echo -e "${YELLOW}未检测到 curl，正在自动安装...${RESET}"
            if command -v apt &> /dev/null; then
                apt update && apt install curl -y
            elif command -v yum &> /dev/null; then
                yum install curl -y
            fi
        fi

        echo -e "${YELLOW}正在从 GitHub 下载核心安装...${RESET}"
        
        # 遍历代理列表进行下载尝试
        local success=false
        for proxy in "${GITHUB_PROXY[@]}"; do
            # 拼接完整的下载 URL
            local download_url="${proxy}https://raw.githubusercontent.com/${RAW_PATH}"
            
            if [ -z "$proxy" ]; then
                echo -e "${CYAN}正在尝试直连下载...${RESET}"
            else
                echo -e "${CYAN}正在尝试通过代理下载: ${proxy}${RESET}"
            fi

            # 执行下载，设置 15 秒超时防止卡死
            curl -fsSL --connect-timeout 15 "$download_url" -o "$SCRIPT_NAME"
            
            if [ $? -eq 0 ] && [ -s "$SCRIPT_NAME" ]; then
                echo -e "${GREEN}下载成功！${RESET}"
                chmod +x "$SCRIPT_NAME"
                success=true
                break # 下载成功，跳出循环
            else
                echo -e "${YELLOW}当前节点下载失败，正在尝试下一个...${RESET}"
                [ -f "$SCRIPT_NAME" ] && rm -f "$SCRIPT_NAME" # 删除可能下载失败的空文件
            fi
        done

        # 如果所有节点都失败了
        if [ "$success" = false ]; then
            echo -e "${RED}错误：所有 GitHub 代理节点均下载失败，请检查网络！${RESET}"
            exit 1
        fi
    fi
}

# 主菜单循环
while true; do
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}   ◈  PayIncus  管理面板 ◈    ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1. 安装 PayIncus${RESET}"
    echo -e "${GREEN}2. 升级 PayIncus${RESET}"
    echo -e "${GREEN}3. 卸载 PayIncus${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}" 
    
    echo -e -n "${GREEN}请输入选项: ${RESET}"
    read choice
    
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
            echo -e -n "${YELLOW}确定要继续吗？(y/n): ${RESET}"
            read confirm
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
            echo -e "${RED}无效选项，请输入 0 到 3 之间的数字！${RESET}"
            ;;
    esac
    
    echo -e -n "${GREEN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done
