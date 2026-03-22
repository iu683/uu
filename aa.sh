#!/bin/bash
# ========================================
# Moments Blog 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="moments-blog"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

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
        echo -e "${GREEN}=== Moments Blog 管理菜单 ===${RESET}"
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
    read -p "请输入访问端口 [默认:3001]: " input_port
    PORT=${input_port:-3001}
    check_port "$PORT" || return

    # 数据目录
    DATA_DIR="$APP_DIR/data"
    mkdir -p "$DATA_DIR"/{postgres,uploads,logs}

    # 随机密码
    DB_PASSWORD=$(openssl rand -hex 16)
    ADMIN_PASSWORD=$(openssl rand -hex 12)
    JWT_SECRET=$(openssl rand -hex 32)

    # env 文件
    cat > "$ENV_FILE" <<EOF
HOST_PORT=$PORT
DB_NAME=moments
DB_USER=moments
DB_PASSWORD=$DB_PASSWORD

ADMIN_USERNAME=admin
ADMIN_PASSWORD=$ADMIN_PASSWORD

JWT_SECRET=$JWT_SECRET
EOF

    # compose
    cat > "$COMPOSE_FILE" <<EOF
services:

  db:
    image: postgres:15-alpine
    container_name: moments-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: \${DB_NAME}
      POSTGRES_USER: \${DB_USER}
      POSTGRES_PASSWORD: \${DB_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - ./data/postgres:/var/lib/postgresql/data/pgdata
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U \${DB_USER} -d \${DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - moments-net

  moments-blog:
    image: koalalove/moments-blog:latest
    container_name: moments-blog
    restart: unless-stopped
    ports:
      - "\${HOST_PORT}:80"
    volumes:
      - ./data/uploads:/data/uploads
      - ./data/logs:/data/logs
    environment:
      JWT_SECRET: \${JWT_SECRET}
      ADMIN_USERNAME: \${ADMIN_USERNAME}
      ADMIN_PASSWORD: \${ADMIN_PASSWORD}
      DATABASE_URL: postgresql://\${DB_USER}:\${DB_PASSWORD}@db:5432/\${DB_NAME}
      NODE_ENV: production
      PORT: 3001
      UPLOAD_DIR: /data/uploads
      INTERNAL_API_URL: http://localhost:3001
    depends_on:
      db:
        condition: service_healthy
    networks:
      - moments-net

networks:
  moments-net:
    driver: bridge
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置${RESET}"
        return
    fi

    echo
    echo -e "${GREEN}✅ Moments Blog 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://服务器IP:${PORT}${RESET}"
    echo -e "${GREEN}👤 后台账号: admin${RESET}"
    echo -e "${GREEN}🔑 后台密码: ${ADMIN_PASSWORD}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Moments Blog 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart moments-blog
    echo -e "${GREEN}✅ Moments Blog 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f moments-blog
}

check_status() {
    docker ps | grep moments-blog
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Moments Blog 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
