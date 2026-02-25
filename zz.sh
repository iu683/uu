#!/bin/bash

# ==========================================
# OpenClaw 一键菜单管理脚本
# ==========================================

# ===== 颜色 =====
GREEN="\033[32m"
YELLOW="\033[33m"
GRAY="\033[90m"
RESET="\033[0m"

APP_NAME="Clawbot"
CONFIG_FILE="$HOME/.openclaw/openclaw.json"

# ==========================================
# 状态检测
# ==========================================

get_install_status() {
    if command -v openclaw >/dev/null 2>&1; then
        echo -e "${GREEN}已安装${RESET}"
    else
        echo -e "${GRAY}未安装${RESET}"
    fi
}

get_running_status() {
    if pgrep -f openclaw-gateway >/dev/null 2>&1; then
        echo -e "${GREEN}运行中${RESET}"
    else
        echo -e "${GRAY}未运行${RESET}"
    fi
}


# ==========================================
# 菜单
# ==========================================

show_menu() {
    clear
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN}        ${APP_NAME} 管理菜单${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${YELLOW}安装状态 : $(get_install_status)${RESET}"
    echo -e "${YELLOW}运行状态 : $(get_running_status)${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN} 1. 安装${RESET}"
    echo -e "${GREEN} 2. 启动${RESET}"
    echo -e "${GREEN} 3. 停止${RESET}"
    echo -e "${GREEN} 4. 查看状态${RESET}"
    echo -e "${GREEN} 5. TG输入连接码${RESET}"
    echo -e "${GREEN} 6. 编辑配置文件${RESET}"
    echo -e "${GREEN} 7. 初始化向导${RESET}"
    echo -e "${GREEN} 8. 健康检测${RESET}"
    echo -e "${GREEN} 9. 更新${RESET}"
    echo -e "${GREEN}10. 卸载${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    printf "${GREEN} 请输入选项: ${RESET}"
}

# ==========================================
# 控制函数
# ==========================================

restart_gateway() {
    openclaw gateway stop >/dev/null 2>&1
    sleep 1
    openclaw gateway start
    sleep 2
}

install_node() {
    if command -v apt >/dev/null 2>&1; then
        curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
        apt install -y nodejs build-essential
    fi
}

install_app() {
    echo "正在安装 OpenClaw..."
    install_node
    npm install -g openclaw@latest
    openclaw onboard --install-daemon
    restart_gateway
    read -p "完成，回车继续..."
}

start_app() {
    restart_gateway
    read -p "已启动，回车继续..."
}

stop_app() {
    openclaw gateway stop
    read -p "已停止，回车继续..."
}

view_status() {
    openclaw status
    openclaw gateway status
    openclaw logs
    read -p "回车继续..."
}


update_app() {
    npm install -g openclaw@latest
    restart_gateway
    read -p "更新完成，回车继续..."
}

uninstall_app() {
    openclaw uninstall
    npm uninstall -g openclaw
    read -p "卸载完成，回车继续..."
}

# ==========================================
# 主循环
# ==========================================

while true; do
    show_menu
    read choice
    case $choice in
        1) install_app ;;
        2) start_app ;;
        3) stop_app ;;
        4) view_status ;;
        5) read -p "TG连接码: " code && openclaw pairing approve telegram "$code" ;;
        6) nano "$CONFIG_FILE" && restart_gateway ;;
        7) openclaw onboard --install-daemon ;;
        8) openclaw doctor --fix ;;
        9) update_app ;;
        10) uninstall_app ;;
        0) exit ;;
    esac
done
