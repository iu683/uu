#!/bin/bash
# ============================================
# Komari 管理脚本（统一文件夹 + 支持自定义端口）
# ============================================

set -e

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

APP_DIR="/opt/komari-dashboard"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/komari_config.env"
DATA_DIR="$APP_DIR/data"
CONTAINER_NAME="komari"

menu() {
    clear
    echo -e "${GREEN}=== Komari 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装部署${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 重启${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_komari ;;
        2) update_komari ;;
        3) uninstall_komari ;;
        4) view_logs ;;
        5) restart_komari ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择！${RESET}" && sleep 1 && menu ;;
    esac
}

restart_komari() {
    load_config
    if [ -z "$PORT" ]; then
        PORT=25774
    fi
    echo -e "${GREEN}=== 正在重启 Komari ===${RESET}"
    (cd "$APP_DIR" && docker compose restart)
    echo -e "${GREEN}✅ Komari 已重启！${RESET}"
    read -p "按回车返回菜单..." && menu
}


load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

install_komari() {
    echo -e "${GREEN}=== 开始安装 Komari ===${RESET}"

    mkdir -p "$APP_DIR" "$DATA_DIR"

    read -p "请输入管理员用户名 (默认: admin): " ADMIN_USERNAME
    ADMIN_USERNAME=${ADMIN_USERNAME:-admin}

    read -p "请输入管理员密码 (默认: admin123): " ADMIN_PASSWORD
    ADMIN_PASSWORD=${ADMIN_PASSWORD:-admin123}

    read -p "请输入 Komari 端口 (默认: 25774): " PORT
    PORT=${PORT:-25774}

    # 保存配置
    cat > "$CONFIG_FILE" <<EOF
ADMIN_USERNAME="$ADMIN_USERNAME"
ADMIN_PASSWORD="$ADMIN_PASSWORD"
PORT="$PORT"
EOF

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  komari:
    image: ghcr.io/komari-monitor/komari:latest
    container_name: $CONTAINER_NAME
    ports:
      - "127.0.0.1:$PORT:25774"
    volumes:
      - $DATA_DIR:/app/data
    env_file:
      - $CONFIG_FILE
    restart: unless-stopped
EOF

    (cd "$APP_DIR" && docker compose up -d)

    echo -e "${GREEN}✅ 部署完成！访问地址:  http://127.0.0.1:$PORT${RESET}"
    echo -e "${YELLOW}用户名: $ADMIN_USERNAME  密码: $ADMIN_PASSWORD${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR${RESET}"
    read -p "按回车返回菜单..." && menu
}

update_komari() {
    load_config
    echo -e "${GREEN}=== 更新 Komari ===${RESET}"
    (cd "$APP_DIR" && docker compose pull && docker compose up -d)
    echo -e "${GREEN}✅ 更新完成！${RESET}"
    read -p "按回车返回菜单..." && menu
}

uninstall_komari() {
    echo -e "${RED} 即将卸载 Komari，并删除相关数据！${RESET}"
    read -p "确认卸载? (y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        (cd "$APP_DIR" && docker compose down -v)
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ 卸载完成${RESET}"
    else
        echo -e "${YELLOW}已取消${RESET}"
    fi
    read -p "按回车返回菜单..." && menu
}

view_logs() {
    echo -e "${GREEN}=== 查看 Komari 日志 ===${RESET}"
    docker logs -f $CONTAINER_NAME
    read -p "按回车返回菜单..." && menu
}

menu
