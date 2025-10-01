#!/bin/bash
# ======================================
# yt-dlp-web 一键管理脚本 (端口映射模式)
# ======================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="yt-dlp-web"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

menu() {
    clear
    echo -e "${GREEN}=== yt-dlp-web 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
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
    mkdir -p "$APP_DIR/downloads" "$APP_DIR/cache"

    # 设置下载/缓存目录权限，容器用户 1000:1000 可访问
    chown -R 1000:1000 "$APP_DIR/downloads" "$APP_DIR/cache"
    chmod -R 755 "$APP_DIR/downloads" "$APP_DIR/cache"

    read -rp "请输入要绑定的端口 [默认 3000]: " port
    port=${port:-3000}
    read -rp "是否启用访问保护 (y/N): " protect

    ENV_FILE="$APP_DIR/.env"
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    cat > "$COMPOSE_FILE" <<EOF
services:
  yt-dlp-web:
    image: sooros5132/yt-dlp-web:latest
    container_name: yt-dlp-web
    user: 1000:1000
    env_file:
      - .env
    volumes:
      - $APP_DIR/downloads:/downloads
      - $APP_DIR/cache:/cache
    ports:
      - "127.0.0.1:${port}:3000"
    restart: unless-stopped
EOF

    if [[ "$protect" =~ ^[Yy]$ ]]; then
        read -rp "AUTH_SECRET (推荐随机40+字符): " AUTH_SECRET
        read -rp "用户名: " CREDENTIAL_USERNAME
        read -rp "密码: " CREDENTIAL_PASSWORD
        cat > "$ENV_FILE" <<EOF
AUTH_SECRET=$AUTH_SECRET
CREDENTIAL_USERNAME=$CREDENTIAL_USERNAME
CREDENTIAL_PASSWORD=$CREDENTIAL_PASSWORD
EOF
    fi

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ yt-dlp-web 已启动${RESET}"
    echo -e "${YELLOW}本地访问地址: http://127.0.0.1:${port}${RESET}"

    if [[ "$protect" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}用户名: $CREDENTIAL_USERNAME${RESET}"
        echo -e "${GREEN}密码: $CREDENTIAL_PASSWORD${RESET}"
    fi

    echo -e "${GREEN}📂 数据目录: $APP_DIR${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ yt-dlp-web 已更新并重启完成${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ yt-dlp-web 已卸载，数据已删除${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f yt-dlp-web
    read -rp "按回车返回菜单..."
    menu
}

check_docker
menu
