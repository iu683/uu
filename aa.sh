#!/bin/bash
# ========================================
# Immich 一键管理脚本
# Debian / Ubuntu 兼容
# Docker Compose 部署
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
RED="\033[31m"

APP_NAME="immich"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本${RESET}"
    exit 1
fi

get_public_ip() {
    local ip
    for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
        ip=$(curl -4s --max-time 5 "$url" 2>/dev/null)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo "127.0.0.1"
}

menu() {
    clear
    echo -e "${GREEN}=== Immich 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 查看日志${RESET}"
    echo -e "${GREEN}4) 重启${RESET}"
    echo -e "${GREEN}5) 停止${RESET}"
    echo -e "${GREEN}6) 编辑配置${RESET}"
    echo -e "${GREEN}7) 查看状态${RESET}"
    echo -e "${GREEN}8) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) view_logs ;;
        4) restart_app ;;
        5) stop_app ;;
        6) edit_config ;;
        7) app_status ;;
        8) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

check_requirements() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${RED}未检测到 docker compose 插件，请检查 Docker 安装${RESET}"
        exit 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 curl，正在安装...${RESET}"
        apt update
        apt install -y curl
    fi
}

install_app() {
    check_requirements

    mkdir -p "$APP_DIR"
    cd "$APP_DIR" || exit 1

    echo -e "${GREEN}请填写 Immich 配置${RESET}"

    read -p "PUID [默认: 0]: " PUID
    read -p "PGID [默认: 0]: " PGID
    read -p "时区 [默认: Asia/Shanghai]: " TZ
    read -p "Immich 访问端口 [默认: 8080]: " IMMICH_PORT
    read -p "Redis 映射端口 [默认: 6379]: " REDIS_PORT_MAP
    read -p "Postgres 映射端口 [默认: 8432]: " POSTGRES_PORT_MAP
    read -p "Postgres 主机名 [默认: postgres14]: " DB_HOSTNAME
    read -p "Postgres 用户名 [默认: postgres]: " DB_USERNAME
    read -p "Postgres 密码 [默认: postgres]: " DB_PASSWORD
    read -p "Postgres 数据库名 [默认: immich]: " DB_DATABASE_NAME
    read -p "Redis 主机名 [默认: redis]: " REDIS_HOSTNAME
    read -p "Redis 密码 [可留空]: " REDIS_PASSWORD
    read -p "是否禁用机器学习？[y/N]: " DISABLE_ML
    read -p "是否禁用 Typesense？[y/N]: " DISABLE_TYPESENSE
    read -p "是否启用 CUDA 加速？[y/N]: " CUDA_ACCELERATION
    read -p "配置目录 [默认: /data/immich/config]: " CONFIG_DIR
    read -p "照片目录 [默认: /data/immich/photos]: " PHOTOS_DIR
    read -p "机器学习目录 [默认: /data/immich/machine]: " MACHINE_DIR
    read -p "数据库目录 [默认: /data/immich/db]: " DB_DIR

    PUID=${PUID:-0}
    PGID=${PGID:-0}
    TZ=${TZ:-Asia/Shanghai}
    IMMICH_PORT=${IMMICH_PORT:-8080}
    REDIS_PORT_MAP=${REDIS_PORT_MAP:-6379}
    POSTGRES_PORT_MAP=${POSTGRES_PORT_MAP:-8432}
    DB_HOSTNAME=${DB_HOSTNAME:-postgres14}
    DB_USERNAME=${DB_USERNAME:-postgres}
    DB_PASSWORD=${DB_PASSWORD:-postgres}
    DB_DATABASE_NAME=${DB_DATABASE_NAME:-immich}
    REDIS_HOSTNAME=${REDIS_HOSTNAME:-redis}
    CONFIG_DIR=${CONFIG_DIR:-/data/immich/config}
    PHOTOS_DIR=${PHOTOS_DIR:-/data/immich/photos}
    MACHINE_DIR=${MACHINE_DIR:-/data/immich/machine}
    DB_DIR=${DB_DIR:-/data/immich/db}

    if [[ "$DISABLE_ML" == "y" || "$DISABLE_ML" == "Y" ]]; then
        DISABLE_MACHINE_LEARNING="true"
    else
        DISABLE_MACHINE_LEARNING="false"
    fi

    if [[ "$DISABLE_TYPESENSE" == "y" || "$DISABLE_TYPESENSE" == "Y" ]]; then
        DISABLE_TYPESENSE_VAL="true"
    else
        DISABLE_TYPESENSE_VAL="false"
    fi

    if [[ "$CUDA_ACCELERATION" == "y" || "$CUDA_ACCELERATION" == "Y" ]]; then
        CUDA_ACCELERATION_VAL="true"
    else
        CUDA_ACCELERATION_VAL="false"
    fi

    mkdir -p "$CONFIG_DIR" "$PHOTOS_DIR" "$MACHINE_DIR" "$DB_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  immich:
    image: ghcr.io/imagegenius/immich:latest
    container_name: immich
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - DB_HOSTNAME=${DB_HOSTNAME}
      - DB_USERNAME=${DB_USERNAME}
      - DB_PASSWORD=${DB_PASSWORD}
      - DB_DATABASE_NAME=${DB_DATABASE_NAME}
      - REDIS_HOSTNAME=${REDIS_HOSTNAME}
      - DISABLE_MACHINE_LEARNING=${DISABLE_MACHINE_LEARNING}
      - DISABLE_TYPESENSE=${DISABLE_TYPESENSE_VAL}
      - DB_PORT=5432
      - REDIS_PORT=6379
      - REDIS_PASSWORD=${REDIS_PASSWORD}
      - CUDA_ACCELERATION=${CUDA_ACCELERATION_VAL}
    volumes:
      - ${CONFIG_DIR}:/config
      - ${PHOTOS_DIR}:/photos
      - ${MACHINE_DIR}:/config/machine-learning
    ports:
      - "${IMMICH_PORT}:8080"
    restart: unless-stopped

  redis:
    image: redis
    container_name: redis
    ports:
      - "${REDIS_PORT_MAP}:6379"

  postgres14:
    image: postgres:14
    container_name: postgres14
    environment:
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: ${DB_DATABASE_NAME}
    ports:
      - "${POSTGRES_PORT_MAP}:5432"
    volumes:
      - ${DB_DIR}:/var/lib/postgresql/data
EOF

    docker compose up -d

    SERVER_IP=$(get_public_ip)

    cat > "$APP_DIR/install-info.txt" <<EOF
Immich 地址: http://${SERVER_IP}:${IMMICH_PORT}
本地访问: http://localhost:${IMMICH_PORT}
Redis 端口: ${REDIS_PORT_MAP}
Postgres 端口: ${POSTGRES_PORT_MAP}
配置目录: ${CONFIG_DIR}
照片目录: ${PHOTOS_DIR}
机器学习目录: ${MACHINE_DIR}
数据库目录: ${DB_DIR}
数据库名称: ${DB_DATABASE_NAME}
数据库用户: ${DB_USERNAME}
数据库密码: ${DB_PASSWORD}
EOF

    echo
    echo -e "${GREEN}✅ Immich 已安装并启动${RESET}"
    echo -e "${YELLOW}访问地址: http://${SERVER_IP}:${IMMICH_PORT}${RESET}"
    echo -e "${YELLOW}本地访问: http://localhost:${IMMICH_PORT}${RESET}"
    echo -e "${YELLOW}安装信息已保存到: ${APP_DIR}/install-info.txt${RESET}"

    read -p "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录，请先安装${RESET}"
        sleep 1
        menu
    }

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ Immich 已更新${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    docker compose logs -f
    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
    menu
}

stop_app() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    docker compose down
    echo -e "${GREEN}✅ 已停止${RESET}"

    read -p "按回车返回菜单..."
    menu
}

edit_config() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    nano "$COMPOSE_FILE"
    echo -e "${YELLOW}配置已编辑，正在重新部署...${RESET}"
    docker compose up -d

    echo -e "${GREEN}✅ 配置已生效${RESET}"
    read -p "按回车返回菜单..."
    menu
}

app_status() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    echo -e "${GREEN}容器状态：${RESET}"
    docker compose ps
    echo
    echo -e "${GREEN}端口监听：${RESET}"
    ss -tulnp | grep -E ':8080|:6379|:8432' || true
    echo
    if [ -f "$APP_DIR/install-info.txt" ]; then
        echo -e "${GREEN}安装信息：${RESET}"
        cat "$APP_DIR/install-info.txt"
    fi

    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" && docker compose down
    fi

    rm -rf "$APP_DIR"

    echo -e "${GREEN}✅ Immich 已卸载（包含数据）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
