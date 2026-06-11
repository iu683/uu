#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# 检查权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 权限运行此脚本！${RESET}"
    exit 1
fi

# 检查并安装依赖（如 jq 或 curl）
if ! command -v curl &> /dev/null; then
    echo -e "${YELLOW}正在安装必要组件 curl...${RESET}"
    apt-get update && apt-get install -y curl || yum install -y curl
fi


get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        # 强制获取 IPv4
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        # 强制获取 IPv6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        # auto 模式：双栈环境优先获取 IPv4 (更适合大众网络)，纯 v6 环境自动fallback到 v6
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        # 如果获取 v4 失败，说明可能是纯 v6 机器，尝试获取 v6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    # 兜底处理：所有接口都失败时，直接输出 127.0.0.1，不报错
    echo "127.0.0.1" && return 0
}


# 获取状态、版本和端口的函数
get_info() {
    # 1. 检测状态
    if systemctl is-active --quiet clicd; then
        status="${GREEN}运行中 (Active)${RESET}"
        
        # 2. 如果运行中，通过本地 API 动态获取版本号
        # 使用 grep 和 sed 兼容没有安装 jq 的系统
        api_res=$(curl -s --max-time 2 http://127.0.0.1:8999/api/version)
        if [[ $api_res == *"\"success\":true"* ]]; then
            version=$(echo "$api_res" | grep -o '"version":"[^"]*' | grep -o '[^"]*$')
        else
            version="获取失败 (API无响应)"
        fi
    else
        status="${RED}未运行 (Stopped)${RESET}"
        version="未知 (服务未运行)"
    fi

    # 3. 默认端口
    port_show="8999"
}

# 主菜单
main_menu() {
    while true; do
        clear
        get_info
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}   ◈  CLICD 轻量虚拟化面板  ◈    ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}状态   :${RESET} $status"
        echo -e "${GREEN}版本   :${RESET} ${YELLOW}v${version}${RESET}"
        echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1. 安装 CLICD 面板${RESET}"
        echo -e "${GREEN} 2. 卸载 CLICD 面板${RESET}"
        echo -e "${GREEN} 3. 启动 CLICD 服务${RESET}"
        echo -e "${GREEN} 4. 停止 CLICD 服务${RESET}"
        echo -e "${GREEN} 5. 重启 CLICD 服务${RESET}"
        echo -e "${GREEN} 6. 查看服务状态 (Detail)${RESET}"
        echo -e "${GREEN} 7. 查看运行日志 (100行)${RESET}"
        echo -e "${GREEN} 0. 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"
        
        read -p "请输入选项 [0-7]: " choice
        case $choice in
            1)
                echo -e "${YELLOW}正在安装 CLICD 面板...${RESET}"
                curl -fsSL https://raw.githubusercontent.com/MengMengCode/CLICD/main/install.sh | sudo sh
                SERVER_IP=$(get_public_ip)
                echo -e "${GREEN}安装完成！请尝试访问 http://${SERVER_IP}:8999${RESET}"
                read -p "按回车键返回菜单..."
                ;;
            2)
                read -p "确定要卸载 CLICD 吗？(y/n): " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    echo -e "${YELLOW}正在卸载 CLICD 面板...${RESET}"
                    curl -fsSL https://raw.githubusercontent.com/MengMengCode/CLICD/main/install.sh | sudo sh -s -- uninstall
                    echo -e "${GREEN}卸载完成！${RESET}"
                else
                    echo -e "${YELLOW}已取消卸载。${RESET}"
                fi
                read -p "按回车键返回菜单..."
                ;;
            3)
                echo -e "${YELLOW}正在启动 CLICD 服务...${RESET}"
                systemctl start clicd
                echo -e "${GREEN}启动指令已发送。${RESET}"
                sleep 1.5
                ;;
            4)
                echo -e "${YELLOW}正在停止 CLICD 服务...${RESET}"
                systemctl stop clicd
                echo -e "${GREEN}停止指令已发送。${RESET}"
                sleep 1
                ;;
            5)
                echo -e "${YELLOW}正在重启 CLICD 服务...${RESET}"
                systemctl restart clicd
                echo -e "${GREEN}重启指令已发送。${RESET}"
                sleep 1.5
                ;;
            6)
                echo -e "${YELLOW}--- 服务详细状态 ---${RESET}"
                systemctl status clicd
                echo -e "${YELLOW}--------------------${RESET}"
                read -p "按回车键返回菜单..."
                ;;
            7)
                echo -e "${YELLOW}--- CLICD 最近100行日志 ---${RESET}"
                journalctl -u clicd -n 100 --no-pager
                echo -e "${YELLOW}---------------------------${RESET}"
                read -p "按回车键返回菜单..."
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入！${RESET}"
                sleep 1
                ;;
        esac
    done
}

# 运行主菜单
main_menu
