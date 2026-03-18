#!/bin/bash
# ========================================
# Sublink Worker + Redis 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="sublink-worker"
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
        echo -e "${GREEN}=== Sublink Worker 管理菜单 ===${RESET}"
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

    # Worker 镜像
    read -p "请输入 Worker 镜像 [默认:ghcr.io/7sageer/sublink-worker:latest]: " input_image
    WORKER_IMAGE=${input_image:-ghcr.io/7sageer/sublink-worker:latest}

    # Worker 端口
    read -p "请输入 Worker 访问端口 [默认:8787]: " input_port
    PORT=${input_port:-8787}
    check_port "$PORT" || return

    # Redis 数据目录
    read -p "请输入 Redis 数据目录 [默认:$APP_DIR/redis-data]: " input_redis
    REDIS_DIR=${input_redis:-$APP_DIR/redis-data}
    mkdir -p "$REDIS_DIR"

    # Redis 配置文件
    read -p "请输入 redis.conf 路径 [默认:$APP_DIR/redis.conf]: " input_conf
    REDIS_CONF=${input_conf:-$APP_DIR/redis.conf}
    if [ ! -f "$REDIS_CONF" ]; then
        cat > "$REDIS_CONF" <<EOF
bind 0.0.0.0
protected-mode no
dir /data
EOF
    fi

    # docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  worker:
    image: ${WORKER_IMAGE}
    container_name: worker
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:8787"
    environment:
      REDIS_HOST: redis
      REDIS_PORT: 6379
      REDIS_KEY_PREFIX: sublink
      CONFIG_TTL_SECONDS: 2592000
    depends_on:
      - redis

  redis:
    image: redis:7-alpine
    command: ["redis-server", "/usr/local/etc/redis/redis.conf"]
    volumes:
      - ${REDIS_DIR}:/data
      - ${REDIS_CONF}:/usr/local/etc/redis/redis.conf:ro
    restart: unless-stopped

volumes:
  redis-data:
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置${RESET}"
        return
    fi

    echo
    echo -e "${GREEN}✅ Sublink Worker + Redis 已启动${RESET}"
    echo -e "${YELLOW}🌐 Worker 访问端口: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 Redis 数据目录: ${REDIS_DIR}${RESET}"
    echo -e "${GREEN}📂 Redis 配置文件: ${REDIS_CONF}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Sublink Worker 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart worker redis
    echo -e "${GREEN}✅ Worker + Redis 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f worker
}

check_status() {
    docker ps | grep -E "worker|redis"
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Sublink Worker + Redis 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
