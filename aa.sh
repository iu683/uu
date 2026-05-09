#!/bin/bash
# ========================================
# SUI Traffic Reset 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="sui-traffic-reset"
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
        echo -e "${GREEN}=== SUI Traffic Reset 管理菜单 ===${RESET}"
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
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker

    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入 Web 管理端口 [默认:8787]: " input_port
    PORT=${input_port:-8787}
    check_port "$PORT" || return

    read -p "请输入 s-ui 数据库目录 [默认:/usr/local/s-ui/db]: " input_db
    SUI_DB_DIR=${input_db:-/usr/local/s-ui/db}

    if [ ! -f "$SUI_DB_DIR/s-ui.db" ]; then
        echo -e "${RED}❌ 未检测到 s-ui.db:${RESET} $SUI_DB_DIR/s-ui.db"
        read -p "按回车返回菜单..."
        return
    fi

    ADMIN_PASSWORD=$(openssl rand -hex 12)

    cat > "$COMPOSE_FILE" <<EOF
services:
  sui-traffic-reset:
    image: ghcr.io/oldwangnewbe/sui-traffic-reset:latest
    container_name: sui-traffic-reset
    restart: unless-stopped

    environment:
      SUI_DB: /data/s-ui.db
      CHECK_INTERVAL: 60
      TZ: Asia/Shanghai
      RESET_ADMIN_USER: admin
      RESET_ADMIN_PASSWORD: ${ADMIN_PASSWORD}
      RESET_WEB_PORT: 8080

    ports:
      - "127.0.0.1:${PORT}:8080"

    volumes:
      - ${SUI_DB_DIR}:/data
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ SUI Traffic Reset 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址:${RESET} http://127.0.0.1:${PORT}"
    echo -e "${GREEN}👤 用户名:${RESET} admin"
    echo -e "${GREEN}🔑 密码:${RESET} ${ADMIN_PASSWORD}"

    cat > "$APP_DIR/account.txt" <<EOF
访问地址: http://127.0.0.1:${PORT}

用户名:
admin

密码:
${ADMIN_PASSWORD}
EOF

    echo -e "${GREEN}📄 已保存账号信息:${RESET} $APP_DIR/account.txt"

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
    docker restart sui-traffic-reset

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f sui-traffic-reset
}

check_status() {
    docker ps | grep sui-traffic-reset

    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return

    docker compose down -v
    rm -rf "$APP_DIR"

    echo -e "${RED}✅ 已彻底卸载${RESET}"

    read -p "按回车返回菜单..."
}

menu
