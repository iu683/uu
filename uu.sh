#!/bin/bash

GREEN="\033[32m"
RESET="\033[0m"

APP_NAME="OCI-Start"
SCRIPT_URL="https://raw.githubusercontent.com/doubleDimple/shell-tools/master/oci-start.sh"
SCRIPT_NAME="oci-start.sh"

# 创建文件夹并下载脚本
setup_script() {
    echo -e "${GREEN}🚀 正在安装应用...${RESET}"
    mkdir -p oci-start && cd oci-start
    wget -O $SCRIPT_NAME $SCRIPT_URL
    chmod +x $SCRIPT_NAME
    ./oci-start.sh start
    read -p "按回车键返回菜单..."
    show_menu
}



# 停止应用
stop_app() {
    oci-start stop
    echo -e "${GREEN}✅ 应用已停止${RESET}"
    read -p "按回车键返回菜单..."
    show_menu
}

# 重启应用
restart_app() {
    oci-start restart
    echo -e "${GREEN}✅ 应用已重启${RESET}"
    read -p "按回车键返回菜单..."
    show_menu
}

# 更新应用
update_app() {
    oci-start update
    echo -e "${GREEN}✅ 应用已更新到最新版本${RESET}"
    read -p "按回车键返回菜单..."
    show_menu
}
# 查看启动状态
status_app() {
    oci-start.sh status
    read -p "按回车键返回菜单..."
    show_menu
}
# 卸载应用
uninstall_app() {
    read -p "⚠️ 确认要完全卸载应用吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        oci-start uninstall
        echo -e "${GREEN}✅ 应用已完全卸载${RESET}"
    else
        echo "❌ 卸载操作已取消"
    fi
    read -p "按回车键返回菜单..."
    show_menu
}

# 显示主菜单
show_menu() {
    clear
    echo -e "${GREEN}=== OCI-Start 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装应用${RESET}"
    echo -e "${GREEN}2) 停止应用${RESET}"
    echo -e "${GREEN}3) 重启应用${RESET}"
    echo -e "${GREEN}4) 更新应用${RESET}"
    echo -e "${GREEN}5) 卸载应用${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}===========================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) setup_script ;;
        2) stop_app ;;
        3) restart_app ;;
        4) update_app ;;
        5) uninstall_app ;;
        0) exit ;;
        *) echo "❌ 无效选择"; sleep 1; show_menu ;;
    esac
}

show_menu
