#!/bin/bash
# ========================================
# EasyNode 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="easynode"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

menu() {
    clear
    echo -e "${GREEN}=== EasyNode 管理菜单 ===${RESET}"
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

install_app() {
    mkdir -p "$APP_DIR"

    read -p "请输入 Web 端口 [默认:8082]: " input_port
    PORT=${input_port:-8082}

    read -p "请输入数据目录 [默认:/root/easynode/db]: " input_db
    DB_DIR=${input_db:-/root/easynode/db}

    mkdir -p "$DB_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  easynode:
    image: docker.cnb.cool/chaoszhu/easynode:latest
    container_name: easynode
    restart: always
    ports:
      - "127.0.0.1:${PORT}:8082"
    volumes:
      - \${DB_DIR}:/easynode/app/db
    environment:
      - TZ=Asia/Shanghai
      - DEBUG=true
      - GUACD_HOST=easynode-guacd
      - GUACD_PORT=4822
    depends_on:
      easynode-guacd:
        condition: service_healthy
    networks:
      - easynode-network
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  easynode-guacd:
    image: docker.cnb.cool/chaoszhu/docker-sync-manual/guacamole-guacd:latest_amd64
    container_name: easynode-guacd
    restart: always
    expose:
      - "4822"
    healthcheck:
      test: ["CMD", "sh", "-c", "nc -z 127.0.0.1 4822"]
      interval: 5s
      timeout: 2s
      retries: 10
    networks:
      - easynode-network
    labels:
      - "com.centurylinklabs.watchtower.enable=false"

  watchtower:
    image: docker.cnb.cool/chaoszhu/docker-sync-manual/containrrr-watchtower:latest_amd64
    container_name: easynode-watchtower
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    command: --schedule "0 */5 * * * *" --label-enable
    environment:
      - TZ=Asia/Shanghai

networks:
  easynode-network:
    driver: bridge
EOF

    cd "$APP_DIR" || exit
    PORT="$PORT" DB_DIR="$DB_DIR" docker compose up -d

    echo -e "${GREEN}✅ EasyNode 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $DB_DIR${RESET}"
    echo -e "${GREEN}🔄 Watchtower: 每 5 分钟自动检查更新${RESET}"
    read -p "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ EasyNode 已更新完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ EasyNode 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    echo -e "${YELLOW}📜 正在查看 easynode 日志 (Ctrl+C 退出)${RESET}"
    docker logs -f easynode
    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ EasyNode 已卸载（数据库未删除）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
