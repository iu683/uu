#!/bin/bash
# ========================================
# Navlink 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="navlink"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

menu() {
    clear
    echo -e "${GREEN}=== Navlink 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) view_logs ;;
        5) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

cat > "$COMPOSE_FILE" <<EOF
services:
  navlink:
    image: ghcr.io/txwebroot/navlink-releases:latest
    container_name: navlink-app
    hostname: navlink-app
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:3001"
    environment:
      - TZ=Asia/Shanghai
      - NODE_ENV=production
      - JWT_SECRET=\${JWT_SECRET}
      - DEFAULT_ADMIN_PASSWORD=\${ADMIN_PASSWORD}
      - SKIP_LICENSE=\${SKIP_LICENSE}
    volumes:
      - ./data:/app/data
      - ./plugins:/app/plugins
      - ./logs:/app/logs
EOF

cat > "$APP_DIR/.env" <<EOF
JWT_SECRET=${JWT_SECRET}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
SKIP_LICENSE=true
EOF

cd "$APP_DIR" || exit
docker compose up -d

    echo -e "${GREEN}✅ Navlink 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}👤 用户名：admin 默认管理员密码: $ADMIN_PASSWORD${RESET}"
    echo -e "${GREEN}🔐 JWT_SECRET: $JWT_SECRET${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    read -p "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Navlink 已更新完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ Navlink 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f navlink-app
    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Navlink 已卸载（包含数据）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
