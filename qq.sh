#!/bin/bash
# ========================================
# ClawBot 一键管理脚本（增强版）- 无检测版
# ========================================

# ====== 颜色定义 ======
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

# ==============================
# 菜单显示函数
# ==============================
show_menu() {
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ClawBot 管理菜单          ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 ClawBot${RESET}"              
    echo -e "${GREEN}2. 连接 Telegram${RESET}"          
    echo -e "${GREEN}3. 修改配置${RESET}"               
    echo -e "${GREEN}4. 重启 ClawBot${RESET}"             
    echo -e "${GREEN}5. 卸载 ClawBot${RESET}"    
    echo -e "${GREEN}6. 暂停网关${RESET}"
    echo -e "${GREEN}7. 启动网关${RESET}"
    echo -e "${GREEN}8. 查看当前状态${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    read -p $'\033[32m请选择: \033[0m' choice
}

# ==============================
# 功能函数（不再检测安装状态）
# ==============================
stop_gateway() {
    echo -e "${GREEN}正在暂停 ClawBot 网关...${RESET}"
    clawdbot gateway stop
    echo -e "${GREEN}网关已暂停！${RESET}"
    read -p "按回车返回菜单..."
}

start_gateway() {
    echo -e "${GREEN}正在启动 ClawBot 网关...${RESET}"
    clawdbot gateway
    echo -e "${GREEN}网关已启动！${RESET}"
    read -p "按回车返回菜单..."
}

view_status() {
    echo -e "${GREEN}当前 ClawBot 状态:${RESET}"
    openclaw status
    read -p "按回车返回菜单..."
}

install_clawbot() {
    echo -e "${GREEN}正在安装 ClawBot...${RESET}"
    curl -fsSL https://openclaw.ai/install.sh | bash
    echo -e "${GREEN}安装完成！${RESET}"
    read -p "按回车返回菜单..."
}

connect_telegram() {
    read -p "请输入 Telegram pairing code: " code
    echo -e "${GREEN}正在连接 Telegram...${RESET}"
    openclaw pairing approve telegram "$code"
    echo -e "${GREEN}已连接 Telegram！${RESET}"
    read -p "按回车返回菜单..."
}

configure_clawbot() {
    echo -e "${GREEN}打开 ClawBot 配置界面...${RESET}"
    openclaw configure
    echo -e "${GREEN}配置完成！${RESET}"
    read -p "按回车返回菜单..."
}

restart_clawbot() {
    echo -e "${GREEN}正在重启 ClawBot...${RESET}"
    openclaw daemon restart
    echo -e "${GREEN}ClawBot 已重启！${RESET}"
    read -p "按回车返回菜单..."
}

uninstall_clawbot() {
    echo -e "${RED}正在卸载 ClawBot...${RESET}"
    openclaw uninstall
    echo -e "${RED}ClawBot 已卸载！${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 主循环
# ==============================
while true; do
    show_menu
    case "$choice" in
        1) install_clawbot ;;
        2) connect_telegram ;;
        3) configure_clawbot ;;
        4) restart_clawbot ;;
        5) uninstall_clawbot ;;
        6) stop_gateway ;;
        7) start_gateway ;;
        8) view_status ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择${RESET}"; read -p "按回车继续..." ;;
    esac
done
