#!/bin/bash
# ========================================
# SaveAny-Bot 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="SaveAny-Bot"
APP_DIR="/opt/saveany-bot"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

menu() {
    while true; do
        clear
        echo -e "${GREEN}== SaveAny-Bot 管理菜单 ====${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 卸载(含数据)${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -rp "请输入编号: " choice
        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) uninstall_app ;;
            4) view_logs ;;
            0) exit 0 ;;
            *) echo -e "${RED}❌ 无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {
    # 创建基础目录
    DOWNLOADS_DIR="$APP_DIR/downloads"
    mkdir -p "$APP_DIR/data" "$APP_DIR/cache" "$DOWNLOADS_DIR"

    # 自定义 Telegram token
    read -rp "请输入 Telegram Bot Token: " tg_token
    TG_TOKEN=${tg_token:-1234567890:ABCDEFGHIJKLMNOPQRSTUVWXYZ}

    # 自定义 Telegram 用户 ID
    read -rp "请输入 Telegram 用户 ID : " tg_id
    TG_ID=${tg_id:-777000}

    # 生成 config.toml
    cat > "$APP_DIR/config.toml" <<EOF
[telegram]
token = "$TG_TOKEN"

[[users]]
# telegram user id
id = $TG_ID
blacklist = true

[[storages]]
name = "本机存储"
type = "local"
enable = true
base_path = "/app/downloads"
EOF

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  saveany-bot:
    image: ghcr.io/krau/saveany-bot:latest
    container_name: saveany-bot
    restart: unless-stopped
    volumes:
      - $APP_DIR/data:/app/data
      - $APP_DIR/config.toml:/app/config.toml
      - $DOWNLOADS_DIR:/app/downloads
      - $APP_DIR/cache:/app/cache
    network_mode: host
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ $APP_NAME 已启动${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR${RESET}"
    echo -e "${GREEN}📂 下载目录: $DOWNLOADS_DIR${RESET}"
    echo -e "${GREEN}📄 config.toml 已生成并写入 token 和用户 ID${RESET}"
    read -rp "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录，请先安装${RESET}"; sleep 1; return; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ $APP_NAME 已更新并重启完成${RESET}"
    read -rp "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录${RESET}"; sleep 1; return; }
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ $APP_NAME 已卸载${RESET}"
    read -rp "按回车返回菜单..."
}

view_logs() {
    docker logs -f saveany-bot
    read -rp "按回车返回菜单..."
}

menu
