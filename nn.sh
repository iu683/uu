#!/bin/bash
# ========================================
# dongguaTV 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="dongguatv"
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
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== dongguaTV 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR/data"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:3600]: " input_port
    PORT=${input_port:-3600}
    check_port "$PORT" || return

    read -p "请输入 TMDB API KEY: " TMDB_API_KEY
    [ -z "$TMDB_API_KEY" ] && echo -e "${RED}必须填写！${RESET}" && return

    read -p "请输入管理员密码 [默认:admin]: " input_pass
    ADMIN_PASSWORD=${input_pass:-admin}

    cat > "$COMPOSE_FILE" <<EOF
services:
  dongguatv:
    image: aexus/dongguatv:latest
    container_name: dongguatv
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:3000"
    volumes:
      - ./data:/app/data
    environment:
      TMDB_API_KEY: ${TMDB_API_KEY}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ dongguaTV 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🌐 管理地址: http://127.0.0.1:${PORT}/admin.html${RESET}"
    echo -e "${YELLOW}🌐 管理密码: ${ADMIN_PASSWORD}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"


    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ dongguaTV 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart dongguatv
    echo -e "${GREEN}✅ dongguaTV 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f dongguatv
}

check_status() {
    docker ps | grep dongguatv
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ dongguaTV 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
