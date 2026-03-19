#!/bin/bash
# ========================================
# Halo 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="halo"
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
        echo -e "${GREEN}=== Halo 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    # 端口
    read -p "请输入访问端口 [默认:8090]: " input_port
    PORT=${input_port:-8090}
    check_port "$PORT" || return

    # 数据目录
    read -p "Halo 数据目录 [默认:$APP_DIR/halo2]: " input_halo
    HALO_DIR=${input_halo:-$APP_DIR/halo2}

    read -p "数据库目录 [默认:$APP_DIR/db]: " input_db
    DB_DIR=${input_db:-$APP_DIR/db}

    mkdir -p "$HALO_DIR"
    mkdir -p "$DB_DIR"

    # 数据库密码
    DB_PASSWORD=$(openssl rand -hex 12)

    # external-url
    read -p "请输入外部访问地址 [默认:http://127.0.0.1:${PORT}]: " input_url
    EXTERNAL_URL=${input_url:-http://127.0.0.1:${PORT}}

    cat > "$COMPOSE_FILE" <<EOF
services:
  halo:
    image: registry.fit2cloud.com/halo/halo-pro:2.23
    container_name: halo
    restart: on-failure:3
    depends_on:
      halodb:
        condition: service_healthy
    networks:
      - halo_network
    volumes:
      - ${HALO_DIR}:/root/.halo2
    ports:
      - "127.0.0.1:${PORT}:8090"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8090/actuator/health/readiness"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
    environment:
      - JVM_OPTS=-Xmx256m -Xms256m
    command:
      - --spring.r2dbc.url=r2dbc:pool:postgresql://halodb/halo
      - --spring.r2dbc.username=halo
      - --spring.r2dbc.password=${DB_PASSWORD}
      - --spring.sql.init.platform=postgresql
      - --halo.external-url=${EXTERNAL_URL}

  halodb:
    image: postgres:15.4
    container_name: halo-db
    restart: on-failure:3
    networks:
      - halo_network
    volumes:
      - ${DB_DIR}:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready"]
      interval: 10s
      timeout: 5s
      retries: 5
    environment:
      - POSTGRES_PASSWORD=${DB_PASSWORD}
      - POSTGRES_USER=halo
      - POSTGRES_DB=halo
      - PGUSER=halo

networks:
  halo_network:
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置${RESET}"
        return
    fi

    echo
    echo -e "${GREEN}✅ Halo 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: ${EXTERNAL_URL}${RESET}"
    echo -e "${GREEN}🗄 数据库密码: ${DB_PASSWORD}${RESET}"
    echo -e "${GREEN}📂 Halo 目录: ${HALO_DIR}${RESET}"
    echo -e "${GREEN}📂 数据库目录: ${DB_DIR}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Halo 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart halo halo-db
    echo -e "${GREEN}✅ Halo 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f halo
}

check_status() {
    docker ps | grep -E "halo"
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Halo 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
