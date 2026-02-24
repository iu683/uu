#!/bin/bash
# ==========================================
# NextTrace 一键管理脚本
# 自动安装 + 菜单模式
# ==========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"
ORANGE='\033[38;5;208m'

# =============================
# 自动检测并安装 NextTrace
# =============================
install_nexttrace() {
    if command -v nexttrace >/dev/null 2>&1; then
        echo -e "${GREEN}✔ NextTrace 已安装${RESET}"
        sleep 1
        return
    fi

    echo -e "${YELLOW}未检测到 NextTrace，正在自动安装...${RESET}"
    curl -sL nxtrace.org/nt | bash

    if command -v nexttrace >/dev/null 2>&1; then
        echo -e "${GREEN}✔ NextTrace 安装完成${RESET}"
        sleep 1
    else
        echo -e "${RED}NextTrace 安装失败${RESET}"
        exit 1
    fi
}

# =============================
# 默认测试 1.0.0.1
# =============================
test_default() {
    echo -e "${GREEN}开始测试 1.0.0.1 ...${RESET}"
    nexttrace 1.0.0.1
    read -p "按回车返回菜单..."
}

# =============================
# 自定义 IP
# =============================
test_custom() {
    read -p "请输入目标 IP 或域名: " TARGET
    if [ -z "$TARGET" ]; then
        echo -e "${RED}未输入目标${RESET}"
        sleep 1
        return
    fi

    echo -e "${GREEN}开始测试 $TARGET ...${RESET}"
    nexttrace $TARGET
    read -p "按回车返回菜单..."
}

# =============================
# 主菜单
# =============================
menu() {
    while true; do
        clear
        echo -e "${ORANGE}===================================${RESET}"
        echo -e "${ORANGE}         NextTrace 路由检测        ${RESET}"
        echo -e "${ORANGE}===================================${RESET}"
        echo -e " ${GREEN}1) 测试 1.0.0.1${RESET}"
        echo -e " ${GREEN}2) 自定义 IP/域名${RESET}"
        echo -e " ${GREEN}0) 退出${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        read choice

        case "$choice" in
            1) test_default ;;
            2) test_custom ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
        esac
    done
}

# =============================
# 启动时自动检测安装
# =============================
install_nexttrace
menu
