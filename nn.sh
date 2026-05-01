#!/bin/bash
# ========================================
# nodeget 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="nodeget"
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
        echo -e "${GREEN}=== NodeGet(PostgreSQL) 管理菜单 ===${RESET}"
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

    mkdir -p "$APP_DIR/data/postgres"
    mkdir -p "$APP_DIR/data/config"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}
    check_port "$PORT" || return

    UUID_FILE="$APP_DIR/uuid"

    if [ -f "$UUID_FILE" ]; then
        UUID=$(cat "$UUID_FILE")
    else
        UUID=$(cat /proc/sys/kernel/random/uuid)
        echo "$UUID" > "$UUID_FILE"
    fi

    cat > "$COMPOSE_FILE" <<EOF
services:
  postgres:
    image: postgres:17-alpine
    container_name: nodeget-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: nodeget
      POSTGRES_USER: nodeget
      POSTGRES_PASSWORD: nodeget
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U nodeget -d nodeget"]
      interval: 5s
      timeout: 5s
      retries: 20

  nodeget:
    image: genshinmc/nodeget:latest
    container_name: nodeget
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      NODEGET_CONFIG_FROM_ENV: "true"
      NODEGET_PORT: "${PORT}"
      NODEGET_SERVER_UUID: "${UUID}"
      NODEGET_LOG_FILTER: "info"
      NODEGET_DATABASE_URL: "postgres://nodeget:nodeget@postgres:5432/nodeget"
    ports:
      - "${PORT}:${PORT}"
    volumes:
      - ./data/config:/etc/nodeget
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${YELLOW}⏳ 等待系统初始化（获取 Token）...${RESET}"

    timeout=60
    elapsed=0

    while [ $elapsed -lt $timeout ]; do
        LOGS=$(docker logs nodeget --tail 50 2>&1)

        SUPERTOKEN=$(echo "$LOGS" | grep -oP 'Super Token:\s*\K.*')
        ROOTPASS=$(echo "$LOGS" | grep -oP 'Root Password:\s*\K.*')

        if [[ -n "$SUPERTOKEN" && -n "$ROOTPASS" ]]; then
            break
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo
    echo -e "${GREEN}✅ nodeget 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🆔 UUID: ${UUID}${RESET}"
    echo -e "${YELLOW}🌐 主控地址: wss://127.0.0.1:${PORT}${RESET}"

    if [[ -n "$SUPERTOKEN" ]]; then
        echo -e "${YELLOW}🔑 Token:${RESET} ${SUPERTOKEN}"
    else
        echo -e "${RED}❌ 未获取到Token（可查看日志）${RESET}"
    fi

    if [[ -n "$ROOTPASS" ]]; then
        echo -e "${YELLOW}🔐 Root密码:${RESET} ${ROOTPASS}"
    else
        echo -e "${RED}❌ 未获取到 Root密码${RESET}"
    fi

    cat > "$APP_DIR/token.txt" <<EOF
访问地址: http://127.0.0.1:${PORT}
UUID: ${UUID}

SuperToken:
${SUPERTOKEN}

RootPassword:
${ROOTPASS}
EOF

    echo -e "${YELLOW}📄 已保存到: $APP_DIR/token.txt${RESET}"

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
    docker restart nodeget
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f nodeget
}

check_status() {
    docker ps | grep nodeget
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
