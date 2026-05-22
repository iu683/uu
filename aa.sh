#!/bin/bash
# ========================================
# DeepSeek-TUI 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

APP_NAME="deepseek-tui"

# ==============================
# 检查 root
# ==============================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}请使用 root 用户运行${RESET}"
        exit 1
    fi
}

# ==============================
# 检测系统
# ==============================
detect_os() {
    if [[ -f /etc/debian_version ]]; then
        OS="debian"
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
    else
        echo -e "${RED}暂不支持当前系统${RESET}"
        exit 1
    fi
}

# ==============================
# 安装 Node.js
# ==============================
install_node() {

    if command -v node &>/dev/null && command -v npm &>/dev/null; then
        echo -e "${GREEN}Node.js 已安装${RESET}"
        node -v
        npm -v
        return
    fi

    echo -e "${GREEN}正在安装 Node.js LTS...${RESET}"

    detect_os

    if [[ "$OS" == "debian" ]]; then

        apt update -y
        apt install -y curl ca-certificates gnupg

        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -

        apt install -y nodejs

    elif [[ "$OS" == "centos" ]]; then

        yum install -y epel-release
        yum install -y curl

        curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash -

        yum install -y nodejs

    fi

    if command -v node &>/dev/null; then
        echo -e "${GREEN}Node.js 安装成功${RESET}"
        node -v
        npm -v
    else
        echo -e "${RED}Node.js 安装失败${RESET}"
        exit 1
    fi
}

# ==============================
# 检查是否已安装 DeepSeek
# ==============================
is_installed() {
    command -v deepseek &>/dev/null
}

# ==============================
# 安装 DeepSeek-TUI
# ==============================
install_app() {

    install_node

    if is_installed; then
        echo -e "${YELLOW}DeepSeek-TUI 已安装${RESET}"
        return
    fi

    echo -e "${GREEN}正在安装 DeepSeek-TUI...${RESET}"

    npm install -g deepseek-tui

    if is_installed; then
        echo -e "${GREEN}安装成功${RESET}"
        deepseek --version
    else
        echo -e "${RED}安装失败${RESET}"
    fi
}

# ==============================
# 卸载
# ==============================
uninstall_app() {

    if ! is_installed; then
        echo -e "${YELLOW}DeepSeek-TUI 未安装${RESET}"
        return
    fi

    echo -e "${RED}正在卸载 DeepSeek-TUI...${RESET}"

    npm uninstall -g deepseek-tui

    echo -e "${GREEN}卸载完成${RESET}"
}

# ==============================
# 更新
# ==============================
update_app() {

    install_node

    if ! is_installed; then
        echo -e "${YELLOW}未安装 DeepSeek-TUI${RESET}"
        return
    fi

    echo -e "${GREEN}正在更新 DeepSeek-TUI...${RESET}"

    npm install -g deepseek-tui@latest

    echo -e "${GREEN}更新完成${RESET}"

    deepseek --version
}

# ==============================
# 启动
# ==============================
start_app() {

    if ! is_installed; then
        echo -e "${RED}请先安装 DeepSeek-TUI${RESET}"
        return
    fi

    deepseek
}

# ==============================
# 配置 API
# ==============================
set_auth() {

    if ! is_installed; then
        echo -e "${RED}请先安装 DeepSeek-TUI${RESET}"
        return
    fi

    deepseek auth set --provider deepseek
}

# ==============================
# Doctor
# ==============================
doctor_app() {

    if ! is_installed; then
        echo -e "${RED}请先安装 DeepSeek-TUI${RESET}"
        return
    fi

    deepseek doctor
}

# ==============================
# 查看版本
# ==============================
show_version() {

    if is_installed; then
        deepseek --version
    else
        echo -e "${YELLOW}未安装${RESET}"
    fi
}

# ==============================
# 菜单
# ==============================
menu() {

    clear

    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN}      DeepSeek-TUI 管理菜单${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN}1. 安装 DeepSeek-TUI${RESET}"
    echo -e "${GREEN}2. 卸载 DeepSeek-TUI${RESET}"
    echo -e "${GREEN}3. 更新 DeepSeek-TUI${RESET}"
    echo -e "${GREEN}4. 启动 DeepSeek TUI${RESET}"
    echo -e "${GREEN}5. 配置 API Key${RESET}"
    echo -e "${GREEN}6. Doctor 检查${RESET}"
    echo -e "${GREEN}7. 查看版本${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"

    echo -ne "${GREEN}请输入选项: ${RESET}"
    read CHOICE

    case "$CHOICE" in
        1)
            install_app
            ;;
        2)
            uninstall_app
            ;;
        3)
            update_app
            ;;
        4)
            start_app
            ;;
        5)
            set_auth
            ;;
        6)
            doctor_app
            ;;
        7)
            show_version
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项${RESET}"
            ;;
    esac

    echo
    read -n 1 -s -r -p "按任意键返回菜单..."
}

# ==============================
# 主循环
# ==============================
check_root

while true; do
    menu
done
