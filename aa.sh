#!/bin/bash
# ========================================
# Baihu 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="baihu"
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
        echo -e "${GREEN}=== 白虎面板 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR/envs"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:8052]: " input_port
    PORT=${input_port:-8052}
    check_port "$PORT" || return

    cat > "$COMPOSE_FILE" <<EOF
services:
  baihu:
    image: ghcr.io/engigu/baihu:latest
    container_name: baihu
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:8052"
    volumes:
      - ./data:/app/data
      - ./envs:/app/envs
    environment:
      TZ: Asia/Shanghai
      BH_SERVER_PORT: 8052
      BH_SERVER_HOST: 0.0.0.0
      BH_DB_TYPE: sqlite
      BH_DB_PATH: /app/data/baihu.db
      BH_DB_TABLE_PREFIX: baihu_
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ Baihu 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Baihu 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart baihu
    echo -e "${GREEN}✅ Baihu 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f baihu
}

check_status() {
    docker ps | grep baihu
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Baihu 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
