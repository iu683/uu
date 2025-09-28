#!/bin/bash
# ========================================
# MoonTV 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="moontv"
APP_DIR="$HOME/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

# 获取公网IP
get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "127.0.0.1"
}

menu() {
    clear
    echo -e "${GREEN}=== MoonTV 管理菜单 ===${RESET}"
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

install_app() {
    read -p "请输入 Web 端口 [默认:3000]: " input_port
    PORT_WEB=${input_port:-3000}

    read -p "请输入管理员用户名 [默认:admin]: " input_user
    ADMIN_USER=${input_user:-admin}

    read -p "请输入管理员密码 [默认:admin123]: " input_pass
    ADMIN_PASS=${input_pass:-admin123}

    # 创建统一文件夹
    mkdir -p "$APP_DIR/config" "$APP_DIR/data"

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF

services:
  moontv-core:
    image: ghcr.io/moontechlab/lunatv:latest
    container_name: moontv-core
    restart: on-failure
    ports:
      - "127.0.0.1:${PORT_WEB}:3000"
    environment:
      - USERNAME=${ADMIN_USER}
      - PASSWORD=${ADMIN_PASS}
      - NEXT_PUBLIC_STORAGE_TYPE=redis
      - REDIS_URL=redis://moontv-redis:6379
    volumes:
      - $APP_DIR/config:/config
    networks:
      - moontv-network
    depends_on:
      - moontv-redis

  moontv-redis:
    image: redis:alpine
    container_name: moontv-redis
    restart: unless-stopped
    volumes:
      - $APP_DIR/data:/data
    networks:
      - moontv-network

networks:
  moontv-network:
    driver: bridge
EOF

    echo -e "PORT_WEB=$PORT_WEB\nADMIN_USER=$ADMIN_USER\nADMIN_PASS=$ADMIN_PASS" > "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ MoonTV 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:$PORT_WEB${RESET}"
    echo -e "${GREEN}📂 配置目录: $APP_DIR/config${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    read -p "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ MoonTV 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ MoonTV 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f moontv-core
    read -p "按回车返回菜单..."
    menu
}

menu
