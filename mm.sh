#!/bin/bash
# ========================================
# ClawBot 一键管理脚本（增强版）
# ========================================

# ====== 颜色定义 ======
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

# ====== 状态变量 ======
INSTALLED=0
TG_CONNECTED=0

# ==============================
# 状态检测函数
# ==============================
check_installed() {
    if command -v openclaw &>/dev/null; then
        INSTALLED=1
    else
        INSTALLED=0
    fi
}

check_telegram_connected() {
    if [[ $INSTALLED -eq 1 ]] && openclaw pairing list | grep -q "telegram"; then
        TG_CONNECTED=1
    else
        TG_CONNECTED=0
    fi
}

# ==============================
# 菜单显示函数（增加网关控制和状态查看）
# ==============================
show_menu() {
    check_installed
    check_telegram_connected

    local INSTALL_STATUS="${RED}未安装${RESET}"
    [[ $INSTALLED -eq 1 ]] && INSTALL_STATUS="${GREEN}已安装${RESET}"

    local TG_STATUS="${RED}未连接${RESET}"
    [[ $TG_CONNECTED -eq 1 ]] && TG_STATUS="${GREEN}已连接${RESET}"

    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ClawBot 管理菜单          ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}安装状态: $INSTALL_STATUS    Telegram: $TG_STATUS${RESET}"
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
# 新增功能函数
# ==============================
stop_gateway() {
    check_installed
    if [[ $INSTALLED -eq 0 ]]; then
        echo -e "${RED}ClawBot 未安装，无法暂停网关.${RESET}"
    else
        echo -e "${GREEN}正在暂停 ClawBot 网关...${RESET}"
        clawdbot gateway stop
        echo -e "${GREEN}网关已暂停！${RESET}"
    fi
    read -p "按回车返回菜单..."
}

start_gateway() {
    check_installed
    if [[ $INSTALLED -eq 0 ]]; then
        echo -e "${RED}ClawBot 未安装，无法启动网关.${RESET}"
    else
        echo -e "${GREEN}正在启动 ClawBot 网关...${RESET}"
        clawdbot gateway
        echo -e "${GREEN}网关已启动！${RESET}"
    fi
    read -p "按回车返回菜单..."
}

view_status() {
    check_installed
    if [[ $INSTALLED -eq 0 ]]; then
        echo -e "${RED}ClawBot 未安装，无法查看状态.${RESET}"
    else
        echo -e "${GREEN}当前 ClawBot 状态:${RESET}"
        openclaw status
    fi
    read -p "按回车返回菜单..."
}

# ==============================
# 功能函数
# ==============================
install_clawbot() {
    echo -e "${GREEN}正在安装 ClawBot...${RESET}"
    curl -fsSL https://openclaw.ai/install.sh | bash
    echo -e "${GREEN}安装完成！${RESET}"
    read -p "按回车返回菜单..."
}

connect_telegram() {
    check_installed
    check_telegram_connected

    if [[ $INSTALLED -eq 0 ]]; then
        echo -e "${RED}ClawBot 未安装，无法连接 Telegram.${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    if [[ $TG_CONNECTED -eq 1 ]]; then
        echo -e "${GREEN}Telegram 已连接，无需重复连接${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    read -p "请输入 Telegram pairing code: " code
    echo -e "${GREEN}正在连接 Telegram...${RESET}"
    openclaw pairing approve telegram "$code"
    echo -e "${GREEN}已连接 Telegram！${RESET}"
    read -p "按回车返回菜单..."
}

configure_clawbot() {
    check_installed
    if [[ $INSTALLED -eq 0 ]]; then
        echo -e "${RED}ClawBot 未安装，无法配置.${RESET}"
        read -p "按回车返回菜单..."
        return
    fi
    echo -e "${GREEN}打开 ClawBot 配置界面...${RESET}"
    openclaw configure
    echo -e "${GREEN}配置完成！${RESET}"
    read -p "按回车返回菜单..."
}

restart_clawbot() {
    check_installed
    if [[ $INSTALLED -eq 0 ]]; then
        echo -e "${RED}ClawBot 未安装，无法重启.${RESET}"
        read -p "按回车返回菜单..."
        return
    fi
    echo -e "${GREEN}正在重启 ClawBot...${RESET}"
    openclaw daemon restart
    echo -e "${GREEN}ClawBot 已重启！${RESET}"
    read -p "按回车返回菜单..."
}

uninstall_clawbot() {
    check_installed
    if [[ $INSTALLED -eq 0 ]]; then
        echo -e "${RED}ClawBot 未安装，无法卸载.${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    echo -e "${RED}正在卸载 ClawBot...${RESET}"
    openclaw uninstall
    echo -e "${RED}ClawBot 已卸载！${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 主循环增加新选项
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
        0) echo -e "${BLUE}退出${RESET}"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择${RESET}"; read -p "按回车继续..." ;;
    esac
done
