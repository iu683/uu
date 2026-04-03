#!/bin/bash
# ========================================
# Xiaoju Survey 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="xiaoju-survey"
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
        echo -e "${GREEN}=== Xiaoju Survey 管理菜单 ===${RESET}"
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

    read -p "请输入访问端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}
    check_port "$PORT" || return

    read -p "Mongo 用户名 [默认:root]: " input_user
    MONGO_USER=${input_user:-root}

    read -p "Mongo 密码 [默认:123456]: " input_pass
    MONGO_PASS=${input_pass:-123456}
    
    cat > "$COMPOSE_FILE" <<EOF
services:
  mongo:
    image: mongo:4
    container_name: xiaoju-survey-mongo
    restart: always
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${MONGO_USER}
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_PASS}
    volumes:
      - ./data/mongo:/data/db
    networks:
      - xiaoju-survey

  xiaoju-survey:
    image: xiaojusurvey/xiaoju-survey:1.3.4-slim
    container_name: xiaoju-survey
    restart: always
    ports:
      - "127.0.0.1:${PORT}:8080"
    environment:
      XIAOJU_SURVEY_MONGO_URL: mongodb://${MONGO_USER}:${MONGO_PASS}@mongo:27017/?authSource=admin
    depends_on:
      - mongo
    networks:
      - xiaoju-survey

networks:
  xiaoju-survey:
    driver: bridge
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ Xiaoju Survey 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Xiaoju Survey 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart xiaoju-survey
    echo -e "${GREEN}✅ Xiaoju Survey 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f xiaoju-survey
}

check_status() {
    docker ps | grep xiaoju-survey
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Xiaoju Survey 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
