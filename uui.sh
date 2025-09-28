#!/bin/bash
# ========================================
# SPlayer 一键管理脚本（更新自动复用安装端口和目录）
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="SPlayer"
CONTAINER_NAME="SPlayer"
DEFAULT_PORT=25884
DEFAULT_DATA_DIR="$HOME/SPlayer/data"
CONFIG_FILE="$HOME/SPlayer/splayer.conf"

function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "your-ip"
}

function menu() {
    clear
    echo -e "${GREEN}=== SPlayer 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载 (含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}=======================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    mkdir -p "$HOME/SPlayer"

    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        read -p "请输入映射端口 [默认:${DEFAULT_PORT}]: " input_port
        PORT=${input_port:-$DEFAULT_PORT}

        read -p "请输入数据目录 [默认:${DEFAULT_DATA_DIR}]: " input_data
        DATA_DIR=${input_data:-$DEFAULT_DATA_DIR}

        mkdir -p "$DATA_DIR"

        echo "PORT=$PORT" > "$CONFIG_FILE"
        echo "DATA_DIR=$DATA_DIR" >> "$CONFIG_FILE"
    fi

    docker pull imsyy/splayer:latest
    docker stop "$CONTAINER_NAME" 2>/dev/null
    docker rm "$CONTAINER_NAME" 2>/dev/null

    docker run -d --name "$CONTAINER_NAME" -p 127.0.0.1:${PORT}:25884 \
        -v "${DATA_DIR}:/app/data" \
        --restart unless-stopped \
        imsyy/splayer:latest

    echo -e "${GREEN}✅ SPlayer 已启动${RESET}"
    echo -e "${GREEN}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 数据目录: $DATA_DIR${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${GREEN}⚠️ 未检测到安装记录，请先执行安装${RESET}"
        sleep 2
        menu
    fi
    source "$CONFIG_FILE"
    echo -e "${GREEN}🔄 拉取最新镜像并重装 SPlayer${RESET}"
    install_app
}

function uninstall_app() {
    docker stop "$CONTAINER_NAME" 2>/dev/null
    docker rm "$CONTAINER_NAME" 2>/dev/null
    read -p "是否同时删除数据目录? [y/N]: " deldata
    if [[ "$deldata" =~ ^[Yy]$ ]]; then
        source "$CONFIG_FILE"
        rm -rf "$DATA_DIR"
        echo -e "${GREEN}✅ 数据目录已删除${RESET}"
    fi
    rm -f "$CONFIG_FILE"
    echo -e "${GREEN}✅ SPlayer 已卸载${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f "$CONTAINER_NAME"
    read -p "按回车返回菜单..."
    menu
}

menu
