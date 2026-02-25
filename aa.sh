#!/bin/bash
# ========================================
# ClawBot 一键管理脚本（彩色状态图标版）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

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
    # 假设 openclaw pairing list 返回已连接的 telegram
    if [[ $INSTALLED -eq 1 ]] && openclaw pairing list | grep -q "telegram"; then
        TG_CONNECTED=1
    else
        TG_CONNECTED=0
    fi
}

# ==============================
# 菜单显示
# ==============================
show_menu() {
    clear
    check_installed
    check_telegram_connected

    STATUS_INSTALL=$([ $INSTALLED -eq 1 ] && echo -e "${GREEN}✅ 已安装${RESET}" || echo -e "${RED}❌ 未安装${RESET}")
    STATUS_TG=$([ $TG_CONNECTED -eq 1 ] && echo -e "${GREEN}✅ 已连接${RESET}" || echo -e "${RED}❌ 未连接${RESET}")

    echo -e "${BLUE}==============================================${RESET}"
    echo -e "${GREEN}          ClawBot 管理菜单          ${RESET}"
    echo -e "${BLUE}==============================================${RESET}"
    echo -e "${YELLOW}1.${RESET} 安装 ClawBot${RESET}"              
    echo -e "${YELLOW}2.${RESET} 连接 Telegram${RESET}"          
    echo -e "${YELLOW}3.${RESET} 修改配置${RESET}"               
    echo -e "${YELLOW}4.${RESET} 重启 ClawBot${RESET}"             
    echo -e "${YELLOW}5.${RESET} 卸载 ClawBot${RESET}"    
    echo -e "${YELLOW}0.${RESET} 退出${RESET}"
    read -p "${GREEN}请选择操作: ${RESET} " choice
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
    if [[ $INSTALLED -eq 0 ]]; then
        echo -e "${RED}ClawBot 未安装，无法连接 Telegram.${RESET}"
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
        0) echo -e "${BLUE}退出${RESET}"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择${RESET}"; read -p "${GREEN}按回车继续...${RESET}" ;;
    esac
done
