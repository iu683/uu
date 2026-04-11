#!/bin/bash
# ========================================
# FOAM 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="foam"
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
        echo -e "${GREEN}=== FOAM 管理菜单 ===${RESET}"
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

    read -p "请输入 FOAM API 映射端口 [默认:8080]: " input_api_port
    API_PORT=${input_api_port:-8080}
    check_port "$API_PORT" || return

    read -p "请输入 FOAM 前端映射端口 [默认:8081]: " input_web_port
    WEB_PORT=${input_web_port:-8081}
    check_port "$WEB_PORT" || return

    read -p "请输入 MySQL 映射端口 [默认:3306]: " input_mysql_port
    MYSQL_PORT=${input_mysql_port:-3306}
    check_port "$MYSQL_PORT" || return

    read -p "请输入 MySQL Root 密码 [默认:78FRC#5BqnOk0ppk]: " input_mysql_pwd
    MYSQL_ROOT_PASSWORD=${input_mysql_pwd:-78FRC#5BqnOk0ppk}

    read -p "请输入 Redis 密码 [默认:123456]: " input_redis_pwd
    REDIS_PASSWORD=${input_redis_pwd:-123456}

    read -p "请输入 TMDB API Token: " TMDB_APITOKEN
    read -p "请输入 TMDB API Key: " TMDB_APIKEY
    read -p "请输入 EMBY_HUB_SEARCH_URL [可留空]: " EMBY_HUB_SEARCH_URL

    read -p "是否启用 HTTP 代理 [true/false，默认:false]: " input_proxy_enabled
    HTTP_PROXY_ENABLED=${input_proxy_enabled:-false}

    HTTP_PROXY=""
    HTTPS_PROXY=""
    if [ "$HTTP_PROXY_ENABLED" = "true" ]; then
        read -p "请输入 HTTP_PROXY 地址 (如 http://ip:port): " HTTP_PROXY
        read -p "请输入 HTTPS_PROXY 地址 (如 http://ip:port): " HTTPS_PROXY
    else
        HTTP_PROXY="http://ip:port"
        HTTPS_PROXY="http://ip:port"
    fi

    mkdir -p "$APP_DIR/data" "$APP_DIR/mysql-data" "$APP_DIR/redis-data"

    cat > "$COMPOSE_FILE" <<EOF
services:
  foam-api:
    image: ciwei123321/foam-api:latest
    privileged: true
    ports:
      - "${API_PORT}:8080"
    volumes:
      - ./data:/data
      - /etc/hosts:/etc/hosts
    container_name: foam-api
    restart: always
    environment:
      - SPRING_DATASOURCE_URL=jdbc:mysql://db:3306/foam-api?useUnicode=true&characterEncoding=utf8&useSSL=false&serverTimezone=GMT%2B8&allowPublicKeyRetrieval=true
      - SPRING_DATASOURCE_USERNAME=root
      - SPRING_DATASOURCE_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - TMDB_APITOKEN=${TMDB_APITOKEN}
      - TMDB_APIKEY=${TMDB_APIKEY}
      - TMDB_IMAGE_URL=https://image.tmdb.org/t/p/original
      - TZ=Asia/Shanghai
      - HTTP_PROXY_ENABLED=${HTTP_PROXY_ENABLED}
      - HTTP_PROXY=${HTTP_PROXY}
      - HTTPS_PROXY=${HTTPS_PROXY}
      - NO_PROXY=172.17.0.1,127.0.0.1,localhost,foam-api-search,selenium-chrome
      - LICENSE_FILE=/data/license.dat
      - EMBY_HUB_SEARCH_URL=${EMBY_HUB_SEARCH_URL}
      - SELENIUM_REMOTE_URL=http://selenium-chrome:4444/wd/hub
      - REDIS_HOST=redis
      - REDIS_PORT=6379
      - REDIS_PWD=${REDIS_PASSWORD}
      - REDIS_DB=0
    networks:
      - foam-network
    links:
      - db
      - selenium-chrome
      - redis
    depends_on:
      - db
      - selenium-chrome
      - redis

  db:
    image: mysql:8.4.6
    container_name: mysql_container
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: foam-api
      TZ: "Asia/Shanghai"
      LANG: en_US.UTF-8
    command:
      - mysqld
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --group_concat_max_len=102400
    ports:
      - "${MYSQL_PORT}:3306"
    volumes:
      - ./mysql-data:/var/lib/mysql
    restart: always
    networks:
      - foam-network

  foam:
    image: ciwei123321/foam:latest
    container_name: foam
    restart: always
    ports:
      - "127.0.0.1:${WEB_PORT}:80"
    environment:
      API_BASE_URL: "http://foam-api:8080"
      TZ: Asia/Shanghai
      IMAGE_URL: https://image.tmdb.org/t/p/
    networks:
      - foam-network
    links:
      - foam-api
    depends_on:
      - foam-api
        
  selenium-chrome:
    image: selenium/standalone-chrome:latest
    platform: linux/amd64
    shm_size: "2gb"
    environment:
      - SE_NODE_MAX_SESSIONS=4
    networks:
      - foam-network
      
  redis:
    image: redis:7.4
    container_name: redis_container
    restart: always
    command:
      - redis-server
      - --appendonly
      - "yes"
      - --save
      - "60"
      - "1"
      - --requirepass
      - "${REDIS_PASSWORD}"
    volumes:
      - ./redis-data:/data
    networks:
      - foam-network

networks:
  foam-network:
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ FOAM 已启动${RESET}"
    echo -e "${YELLOW}🌐 FOAM 前端地址: http://127.0.0.1:${WEB_PORT}${RESET}"
    echo -e "${YELLOW}🔌 FOAM API 地址:  http://127.0.0.1:${API_PORT}${RESET}"
    echo -e "${GREEN}📂 数据目录: ${APP_DIR}/data${RESET}"
    echo -e "${GREEN}📂 MySQL 数据目录: ${APP_DIR}/mysql-data${RESET}"
    echo -e "${GREEN}📂 Redis 数据目录: ${APP_DIR}/redis-data${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ FOAM 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    cd "$APP_DIR" || return
    docker compose restart
    echo -e "${GREEN}✅ FOAM 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    cd "$APP_DIR" || return
    docker compose logs -f
}

check_status() {
    cd "$APP_DIR" || return
    docker compose ps
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ FOAM 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
