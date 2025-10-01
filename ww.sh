#!/bin/bash
# ========================================
# Emby 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="embyserver"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== Emby 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 重启${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        5) restart_app ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    read -p "请输入 Web 端口 [默认:8096]: " input_port
    PORT=${input_port:-8096}

    read -p "请输入媒体目录路径 [默认:/opt/emby/data]: " input_data
    MEDIA_DIR=${input_data:-/opt/emby/data}

    read -p "是否启用硬件转码 (y/n) [默认:n]: " input_hw
    HW_TRANSCODE=${input_hw:-n}

    mkdir -p "$APP_DIR/config"
    mkdir -p "$MEDIA_DIR"

    cat > "$COMPOSE_FILE" <<EOF

services:
  embyserver:
    image: amilys/embyserver_arm64v8
    container_name: amilys_embyserver
    network_mode: bridge
    environment:
      - UID=0
      - GID=0
      - GIDLIST=0
      - TZ=Asia/Shanghai
    volumes:
      - $APP_DIR/config:/config
      - $MEDIA_DIR:/data
    ports:
      - "127.0.0.1:$PORT:8096"
    restart: always
EOF

    if [[ "$HW_TRANSCODE" == "y" || "$HW_TRANSCODE" == "Y" ]]; then
        cat >> "$COMPOSE_FILE" <<EOF
    devices:
      - /dev/dri:/dev/dri
EOF
    fi

    echo "PORT=$PORT" > "$CONFIG_FILE"
    echo "MEDIA_DIR=$MEDIA_DIR" >> "$CONFIG_FILE"
    echo "HW_TRANSCODE=$HW_TRANSCODE" >> "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ Emby 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 配置目录: $APP_DIR/config${RESET}"
    echo -e "${GREEN}🎬 媒体目录: $MEDIA_DIR${RESET}"
    [[ "$HW_TRANSCODE" =~ [yY] ]] && echo -e "${GREEN}⚡ 已启用硬件转码支持${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Emby 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Emby 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ Emby 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f amilys_embyserver
    read -p "按回车返回菜单..."
    menu
}

menu
