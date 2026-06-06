#!/bin/bash
# ==========================================
# 一键重装系统脚本
# ==========================================

green="\033[32m"
red="\033[31m"
yellow="\033[33m"
purple="\033[1;35m"
re="\033[0m"

# 定义基础 URL 和代理 URL
BASE_URL="https://raw.githubusercontent.com/LloydAsp/OsMutation/main/OsMutation.sh"
PROXY_URL="https://v6.gh-proxy.org/https://raw.githubusercontent.com/LloydAsp/OsMutation/main/OsMutation.sh"
FINAL_URL=""

# 主菜单函数示例
main_menu() {
    # 这里可以调用你原来的菜单函数
    # 比如：./your_menu.sh
    exit 0
}

# 网络检查与URL选择函数（默认直连，失败切代理）
check_network() {

    # 1. 尝试直连 (设置 5 秒超时)
    if curl -s --connect-timeout 5 --head "$BASE_URL" | head -n 1 | grep -qE "200|301|302"; then
        FINAL_URL="$BASE_URL"
    # 2. 直连失败，尝试代理
    else
        echo -e "${yellow}直连超时或失败，正在尝试通过代理加载...${re}"
        if curl -s --connect-timeout 5 --head "$PROXY_URL" | head -n 1 | grep -qE "200|301|302"; then
            echo -e "${green}代理节点连接成功！${re}"
            FINAL_URL="$PROXY_URL"
        else
            echo -e "${red}网络连接失败：直连与代理均无法访问，请检查网络后重试${re}"
            main_menu
        fi
    fi
}

# 重装系统函数
reinstall_os() {
    clear
    echo -e "${yellow}重装系统将无法恢复数据，请提前做好备份${re}"
    echo -e "${yellow}注意：NAT重装后SSH端口密码保持原端口密码不变${re}"
    
    while true; do
        read -p $'\033[1;35m确定要重装吗？(y/n): \033[0m' confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            # 执行网络检查并确定可用链接
            check_network
            
            echo -e "${yellow}正在下载并执行重装...${re}"
            sleep 1
            
            # 使用筛选出的 FINAL_URL 下载
            curl -so OsMutation.sh "$FINAL_URL"
            if [ $? -ne 0 ] || [ ! -s OsMutation.sh ]; then
                echo -e "${red}失败，请检查写入权限或网络！${re}"
                main_menu
            fi
            
            chmod +x OsMutation.sh
            ./OsMutation.sh
            break
        elif [[ $confirm =~ ^[Nn]$ ]]; then
            main_menu
        else
            echo -e "${red}无效输入，请输入 y 或 n${re}"
        fi
    done
}

# 调用重装函数
reinstall_os
