#!/bin/bash
# Send 管理脚本 (绿色菜单版，含Redis，自定义文件大小)

SERVICE_NAME="send"
INSTALL_DIR="/opt/$SERVICE_NAME"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

# 颜色
GREEN="\e[32m"
RESET="\e[0m"

install() {
    echo -e "${GREEN}>>> 开始安装 Send 服务...${RESET}"

    read -p "请输入映射端口 (默认 1443): " PORT
    PORT=${PORT:-1443}

    read -p "请输入域名 (如 https://send.example.com): " DOMAIN

    read -p "请输入最大文件大小(单位GB, 默认4): " MAX_GB
    MAX_GB=${MAX_GB:-4}
    MAX_FILE_SIZE=$((MAX_GB * 1024 * 1024 * 1024))   # 转换为字节

    mkdir -p "$INSTALL_DIR/uploads"

    cat > $COMPOSE_FILE <<EOF
version: "3.8"

services:
  send:
    image: registry.gitlab.com/timvisee/send:latest
    container_name: $SERVICE_NAME
    depends_on:
      - redis
    ports:
      - "$PORT:1443"
    environment:
      - NODE_ENV=production
      - PORT=1443
      - BASE_URL=$DOMAIN
      - MAX_FILE_SIZE=$MAX_FILE_SIZE
      - REDIS_ENABLED=true
      - REDIS_HOST=redis
      - REDIS_PORT=6379
    volumes:
      - ./uploads:/uploads
    restart: unless-stopped

  redis:
    image: redis:latest
    container_name: ${SERVICE_NAME}_redis
    volumes:
      - redis_data:/data
    restart: unless-stopped

volumes:
  redis_data:
EOF

    cd "$INSTALL_DIR"
    docker compose up -d
    echo -e "${GREEN}>>> Send 服务已安装并运行在端口: $PORT${RESET}"
    echo -e "${GREEN}>>> 最大上传文件大小: ${MAX_GB}GB (${MAX_FILE_SIZE} 字节)${RESET}"

    read -p "按回车返回菜单..."  
    menu
}

start() {
    cd "$INSTALL_DIR" && docker compose up -d
    echo -e "${GREEN}>>> Send 服务已启动${RESET}"
    read -p "按回车返回菜单..."
    menu
}

stop() {
    cd "$INSTALL_DIR" && docker compose down
    echo -e "${GREEN}>>> Send 服务已停止${RESET}"
    read -p "按回车返回菜单..."
    menu
}

restart() {
    stop
    start
}

update() {
    cd "$INSTALL_DIR"
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}>>> Send 服务已更新${RESET}"
    read -p "按回车返回菜单..."
    menu
}

uninstall() {
    stop
    rm -rf "$INSTALL_DIR"
    echo -e "${GREEN}>>> Send 服务已卸载${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu() {
    clear
    echo -e "${GREEN}======================${RESET}"
    echo -e "${GREEN} Send 管理菜单         ${RESET}"
    echo -e "${GREEN}======================${RESET}"
    echo -e "${GREEN}1. 安装${RESET}"
    echo -e "${GREEN}2. 启动${RESET}"
    echo -e "${GREEN}3. 停止${RESET}"
    echo -e "${GREEN}4. 重启${RESET}"
    echo -e "${GREEN}5. 更新${RESET}"
    echo -e "${GREEN}6. 卸载${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}======================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read CHOICE
    case $CHOICE in
        1) install ;;
        2) start ;;
        3) stop ;;
        4) restart ;;
        5) update ;;
        6) uninstall ;;
        0) exit 0 ;;
        *) echo -e "${GREEN}无效选项${RESET}" ; sleep 1 ; menu ;;
    esac
}

menu
