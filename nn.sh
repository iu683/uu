#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

BASE_DIR="/opt/flux-panel"

# ==============================
# 初始化目录
# ==============================
init_dir() {
    mkdir -p "$BASE_DIR"
    cd "$BASE_DIR" || exit 1
}

# ==============================
# 暂停
# ==============================
pause() {
    read -p $'\033[32m按回车键返回菜单...\033[0m'
    menu
}

# ==============================
# 面板安装
# ==============================
install_panel() {
    init_dir
    echo -e "${GREEN}正在安装面板管理...${RESET}"

    rm -f panel_install.sh
    curl -fsSL -o panel_install.sh \
        https://raw.githubusercontent.com/bqlpfy/flux-panel/refs/heads/main/panel_install.sh

    chmod +x panel_install.sh
    bash panel_install.sh
}

# ==============================
# 节点安装
# ==============================
install_node() {
    init_dir
    echo -e "${GREEN}正在安装节点管理...${RESET}"

    rm -f install.sh
    curl -fsSL -o install.sh \
        https://raw.githubusercontent.com/bqlpfy/flux-panel/refs/heads/main/install.sh

    chmod +x install.sh
    bash install.sh
}

# ==============================
# 主菜单
# ==============================
menu() {
    clear
    echo -e "${GREEN}=== 哆啦A梦面板管理菜单 ===${RESET}"
    echo -e "${GREEN}安装目录: $BASE_DIR${RESET}"
    echo -e "${GREEN}1) 面板管理${RESET}"
    echo -e "${GREEN}2) 节点管理${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p $'\033[32m请选择操作: \033[0m' choice

    case $choice in
        1) install_panel; pause ;;
        2) install_node; pause ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}无效选择，请重新输入${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
