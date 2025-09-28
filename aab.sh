#!/bin/bash
# ========================================
# LRC API 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="lrcapi"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== LRC API 管理菜单 ===${RESET}"
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

# 生成随机 API_AUTH Key
function gen_api_key() {
    # 16 位随机字符串
    tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

function install_app() {
    read -p "请输入 Web 端口 [默认:28883]: " input_port
    PORT=${input_port:-28883}

    # 随机生成 API_AUTH
    API_AUTH=$(gen_api_key)

    # 创建统一文件夹
    mkdir -p "$APP_DIR/music"

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  lrcapi:
    image: hisatri/lrcapi:latest
    container_name: lrcapi
    restart: unless-stopped
    ports:
      - "127.0.0.1:$PORT:28883"
    environment:
      - API_AUTH=$API_AUTH
    volumes:
      - $APP_DIR/music:/music
EOF

    # 保存配置
    echo "PORT=$PORT" > "$CONFIG_FILE"
    echo "API_AUTH=$API_AUTH" >> "$CONFIG_FILE"

    # 启动服务
    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ LRC API 已启动${RESET}"
    echo -e "${GREEN}🌐 Web API 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}🔑 API_AUTH Key: $API_AUTH${RESET}"
    echo -e "${GREEN}📂 音乐目录: $APP_DIR/music${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    source "$CONFIG_FILE"
    echo -e "${GREEN}✅ LRC API 已更新并重启完成${RESET}"
    echo -e "${GREEN}🌐 Web API 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}🔑 API_AUTH Key: $API_AUTH${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ LRC API 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f lrcapi
    read -p "按回车返回菜单..."
    menu
}

menu
