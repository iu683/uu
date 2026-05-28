#!/bin/bash
# ========================================
# MediaStation-Go 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
RESET="\033[0m"

APP_NAME="mediastation-go"
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

check_port() {
    if ss -tln | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== MediaStation-Go 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker

    mkdir -p "$APP_DIR"/{data,cache}

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read -r confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:18080]: " input_port
    PORT=${input_port:-18080}
    check_port "$PORT" || return

    read -p "请输入媒体目录 [默认:/opt/mediastation-go/media]: " input_media
    MEDIA_DIR=${input_media:-/opt/mediastation-go/media}

    mkdir -p "$MEDIA_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  mediastation-go:
    image: ghcr.io/shukebta/mediastation-go:latest
    container_name: mediastation-go
    restart: unless-stopped
    pull_policy: always

    ports:
      - "127.0.0.1:${PORT}:8080"

    volumes:
      - ./data:/data
      - ./cache:/cache
      - ${MEDIA_DIR}:/media:ro

    environment:
      TZ: Asia/Shanghai
      PUID: 1000
      PGID: 1000

      MEDIASTATION_APP_HOST: 0.0.0.0
      MEDIASTATION_APP_PORT: 8080
      MEDIASTATION_APP_DATA_DIR: /data
      MEDIASTATION_APP_WEB_DIR: /app/web/dist

      MEDIASTATION_DATABASE_DB_PATH: /data/mediastation.db
      MEDIASTATION_CACHE_CACHE_DIR: /cache
      MEDIASTATION_LOGGING_LEVEL: info
      MEDIASTATION_TRANSCODER_MAX_HEIGHT: 1080

    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8080/api/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 40s

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

    cd "$APP_DIR" || exit
    docker compose pull
    docker compose up -d

    echo
    echo -e "${GREEN}✅ MediaStation-Go 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🌐 默认账号：admin / admin123${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}🎬 媒体目录: $MEDIA_DIR${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart mediastation-go >/dev/null 2>&1
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f mediastation-go
}

check_status() {
    docker ps | grep mediastation-go
    read -p "按回车返回菜单..."
}


uninstall_app() {

    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"

    echo -e "${GREEN}✅ 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
