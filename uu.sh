#!/bin/bash
# ==========================================
# mtr 一键检测脚本
# 自动安装 + 菜单模式
# ==========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"
ORANGE='\033[38;5;208m'

COUNT=100

# =============================
# 自动检测并安装 mtr
# =============================
install_mtr() {
    if command -v mtr >/dev/null 2>&1; then
        sleep 1
        return
    fi

    echo -e "${YELLOW}未检测到 mtr，正在自动安装...${RESET}"

    if [ -f /etc/debian_version ]; then
        apt update -y >/dev/null 2>&1
        apt install -y mtr >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y mtr >/dev/null 2>&1
    else
        echo -e "${RED}不支持的系统，请手动安装 mtr${RESET}"
        exit 1
    fi

    if command -v mtr >/dev/null 2>&1; then
        echo -e "${GREEN}✔ mtr 安装完成${RESET}"
        sleep 1
    else
        echo -e "${RED}mtr 安装失败${RESET}"
        exit 1
    fi
}

# =============================
# 获取目标 IP
# =============================
get_target() {
    read -p "请输入目标 IP 或域名: " TARGET
    if [ -z "$TARGET" ]; then
        echo -e "${RED}未输入目标${RESET}"
        return 1
    fi
    return 0
}

# =============================
# 实时模式
# =============================
run_live() {
    get_target || return
    echo -e "${GREEN}启动实时模式，按 q 退出...${RESET}"
    mtr $TARGET
}

# =============================
# 报告模式
# =============================
run_report() {
    get_target || return
    echo -e "${GREEN}生成报告模式 (发送 $COUNT 个包)...${RESET}"
    mtr -r -c $COUNT $TARGET
    read -p "按回车返回菜单..."
}

# =============================
# 主菜单
# =============================
menu() {
    while true; do
        clear
        echo -e "${ORANGE}===================================${RESET}"
        echo -e "${ORANGE}           MTR 网络检测工具        ${RESET}"
        echo -e "${ORANGE}===================================${RESET}"
        echo -e " ${GREEN}1) 实时动态检测 (按 q 退出)${RESET}"
        echo -e " ${GREEN}2) 报告模式 (100 包)${RESET}"
        echo -e " ${GREEN}0) 退出${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        read choice

        case "$choice" in
            1) run_live ;;
            2) run_report ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
        esac
    done
}

# =============================
# 启动时自动检测安装
# =============================
install_mtr
menu
