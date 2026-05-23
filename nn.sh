#!/bin/bash
# ========================================
# Telegram Music Bot 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="telegram-music-bot"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {

    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2，请升级 Docker${RESET}"
        exit 1
    fi
}

menu() {

    while true; do

        clear

        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} Telegram Music Bot 管理菜单${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        echo

        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker

    mkdir -p "$APP_DIR/config"
    mkdir -p "$APP_DIR/secrets"
    mkdir -p "$APP_DIR/data/downloads"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read -r confirm
        [[ "$confirm" != "y" ]] && return
    fi

    echo
    read -p "请输入 Telegram Bot Token: " BOT_TOKEN

    echo
    read -p "请输入音乐 API 地址 [默认:https://music-api.gdstudio.xyz/api.php]: " input_api
    SOURCE_API=${input_api:-https://music-api.gdstudio.xyz/api.php}

    echo
    read -p "最大搜索结果 [默认:5]: " input_results
    MAX_RESULTS=${input_results:-5}

    cat > "$APP_DIR/secrets/telegram-bot-token" <<EOF
${BOT_TOKEN}
EOF

    # 修复权限问题
    chmod 644 "$APP_DIR/secrets/telegram-bot-token"

    cat > "$APP_DIR/config/config.yaml" <<EOF
bot_token_file: /run/secrets/telegram-bot-token
download_dir: /app/data/downloads
max_results: ${MAX_RESULTS}
http_timeout_seconds: 20
http_max_retries: 2
log_level: info

source_api_base_url: ${SOURCE_API}

source_order:
  - netease
  - kuwo
  - joox
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  music-bot:
    image: ghcr.io/skylush/telegram-music-bot:latest
    container_name: telegram-music-bot

    environment:
      CONFIG_FILE: /app/config/config.yaml
      BOT_TOKEN_FILE: /run/secrets/telegram-bot-token

    volumes:
      - ./config/config.yaml:/app/config/config.yaml:ro
      - ./secrets/telegram-bot-token:/run/secrets/telegram-bot-token:ro
      - ./data/downloads:/app/data/downloads

    restart: unless-stopped

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

    cd "$APP_DIR" || exit

    docker compose up -d --force-recreate

    echo
    echo -e "${GREEN}✅ Telegram Music Bot 已启动${RESET}"
    echo -e "${YELLOW}🎵 音乐 API: ${SOURCE_API}${RESET}"
    echo -e "${YELLOW}📂 下载目录: $APP_DIR/data/downloads${RESET}"
    echo -e "${YELLOW}⚙️ 配置文件: $APP_DIR/config/config.yaml${RESET}"
    echo

    read -p "按回车返回菜单..."
}

update_app() {

    cd "$APP_DIR" || return

    docker compose pull
    docker compose up -d --force-recreate

    echo
    echo -e "${GREEN}✅ 更新完成${RESET}"

    read -p "按回车返回菜单..."
}

restart_app() {

    cd "$APP_DIR" || return

    docker compose restart

    echo
    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f telegram-music-bot
}

check_status() {


    docker ps -a | grep telegram-music-bot

    read -p "按回车返回菜单..."
}

uninstall_app() {


    cd "$APP_DIR" 2>/dev/null || true

    docker compose down -v 2>/dev/null
    rm -rf "$APP_DIR"

    echo
    echo -e "${RED}✅ 已彻底卸载${RESET}"

    read -p "按回车返回菜单..."
}

menu
