#!/bin/bash
# ========================================
# QMediaSync 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="qmediasync"
APP_DIR="$HOME/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== QMediaSync 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载 (含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
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
    read -p "请输入 QMediaSync 主端口 [默认:12333]: " input_main
    PORT_MAIN=${input_main:-12333}

    # 创建统一文件夹
    mkdir -p /vol1/1000/docker/qmediasync/config
    mkdir -p "/vol2/1000/网盘"

    # 固定 Web 端口 8095、API 端口 8094
    cat > "$COMPOSE_FILE" <<EOF
version: '3'

services:
  qmediasync:
    image: qicfan/qmediasync:latest
    container_name: qmediasync
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_MAIN}:12333"
      - "8095:8095"
      - "8094:8094"
    volumes:
      - /vol1/1000/docker/qmediasync/config:/app/config
      - /vol2/1000/网盘:/media
    environment:
      - TZ=Asia/Shanghai

networks:
  default:
    name: qmediasync
EOF

    echo "PORT_MAIN=$PORT_MAIN" > "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ QMediaSync 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:${PORT_MAIN}${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ QMediaSync 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    rm -rf /vol1/1000/docker/qmediasync/config
    rm -rf "/vol2/1000/网盘"
    echo -e "${GREEN}✅ QMediaSync 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f qmediasync
    read -p "按回车返回菜单..."
    menu
}

menu
