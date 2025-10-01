#!/bin/bash
# ======================================
# Linkwarden 一键管理脚本
# ======================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="linkwarden"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

menu() {
    clear
    echo -e "${GREEN}=== Linkwarden 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

install_app() {
    mkdir -p "$APP_DIR/data" "$APP_DIR/db"

    read -rp "请输入 Web 端口 [默认:3000]: " port
    port=${port:-3000}
    read -rp "请输入数据库密码 [默认: linkwarden]: " db_pass
    db_pass=${db_pass:-linkwarden}
    read -rp "请输入 NEXTAUTH_SECRET (推荐随机40+字符): " NEXTAUTH_SECRET
    NEXTAUTH_SECRET=${NEXTAUTH_SECRET:-"changeme-secret"}

cat > "$ENV_FILE" <<EOF
NEXTAUTH_URL=http://127.0.0.1:${port}/api/v1/auth
NEXTAUTH_SECRET=${NEXTAUTH_SECRET}
POSTGRES_PASSWORD=${db_pass}
EOF
chmod 600 "$ENV_FILE"

cat > "$COMPOSE_FILE" <<EOF
services:
  linkwarden:
    container_name: linkwarden
    image: linkwarden/linkwarden:latest
    ports:
      - "127.0.0.1:${port}:3000"
    volumes:
      - ./data:/app/data
    environment:
      - DATABASE_URL=postgres://linkwarden:\${POSTGRES_PASSWORD}@db/linkwarden?sslmode=disable
      - NEXTAUTH_URL=\${NEXTAUTH_URL}
      - NEXTAUTH_SECRET=\${NEXTAUTH_SECRET}
    depends_on:
      - db
    restart: unless-stopped

  db:
    container_name: linkwarden_db
    image: postgres:15
    environment:
      - POSTGRES_USER=linkwarden
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=linkwarden
    volumes:
      - ./db:/var/lib/postgresql/data
    restart: unless-stopped
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ Linkwarden 已启动${RESET}"
    echo -e "${YELLOW}访问地址: http://127.0.0.1:${port}${RESET}"
    echo -e "${GREEN}数据库用户: linkwarden${RESET}"
    echo -e "${GREEN}数据库密码: ${db_pass}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Linkwarden 已更新并重启完成${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }

    echo -e "${RED}是否同时删除数据目录？ (y/N)${RESET}"
    read -rp "选择: " confirm
    docker compose down -v

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$APP_DIR"
        echo -e "${RED}✅ Linkwarden 已卸载，数据已删除${RESET}"
    else
        echo -e "${YELLOW}✅ Linkwarden 已卸载，数据目录保留在 $APP_DIR${RESET}"
    fi

    read -rp "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f linkwarden
    read -rp "按回车返回菜单..."
    menu
}

check_docker
menu
