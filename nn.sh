#!/bin/bash
# ========================================
# Flarum 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="flarum"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/flarum.env"

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
        echo -e "${GREEN}=== Flarum 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}7) 安装中文语言包${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            7) install_chinese ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker

    mkdir -p $APP_DIR/{assets,extensions,logs,nginx,mysql}

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}
    check_port "$PORT" || return

    read -p "论坛域名 (例如 https://forum.example.com): " DOMAIN

    read -p "数据库 root 密码: " DB_ROOT_PASS
    read -p "数据库 flarum 密码: " DB_PASS

    read -p "管理员用户名 [默认:admin]: " input_admin
    ADMIN_USER=${input_admin:-admin}

    read -p "管理员密码 (至少8位): " ADMIN_PASS
    read -p "管理员邮箱: " ADMIN_MAIL

    read -p "论坛标题 [默认:Flarum Forum]: " input_title
    TITLE=${input_title:-Flarum Forum}

    cat > "$ENV_FILE" <<EOF
DEBUG=false
FORUM_URL=$DOMAIN

DB_HOST=mariadb
DB_NAME=flarum
DB_USER=flarum
DB_PASS=$DB_PASS
DB_PREF=flarum_
DB_PORT=3306

FLARUM_ADMIN_USER=$ADMIN_USER
FLARUM_ADMIN_PASS=$ADMIN_PASS
FLARUM_ADMIN_MAIL=$ADMIN_MAIL
FLARUM_TITLE=$TITLE
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:

  flarum:
    image: mondedie/flarum:stable
    container_name: flarum
    restart: unless-stopped
    env_file:
      - ./flarum.env
    volumes:
      - ./assets:/flarum/app/public/assets
      - ./extensions:/flarum/app/extensions
      - ./logs:/flarum/app/storage/logs
      - ./nginx:/etc/nginx/flarum
    ports:
      - 127.0.0.1:${PORT}:8888
    depends_on:
      - mariadb

  mariadb:
    image: mariadb:10.6
    container_name: flarum-db
    restart: unless-stopped
    command: --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASS}
      MYSQL_DATABASE: flarum
      MYSQL_USER: flarum
      MYSQL_PASSWORD: ${DB_PASS}
    volumes:
      - ./mysql:/var/lib/mysql
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ Flarum 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🌐 访问地址: $DOMAIN${RESET}"
    echo -e "${YELLOW}🌐 标题: $TITLE${RESET}"
    echo -e "${YELLOW}🌐 MYSQLHOST: mariadb${RESET}"
    echo -e "${YELLOW}🌐 数据库名: flarum${RESET}"
    echo -e "${YELLOW}🌐 用户名: flarum${RESET}"
    echo -e "${YELLOW}🌐 数据库密码: $DB_PASS${RESET}"
    echo -e "${YELLOW}🌐 账号: $ADMIN_USER${RESET}"
    echo -e "${YELLOW}🌐 邮箱: $ADMIN_MAIL${RESET}"
    echo -e "${YELLOW}🌐 密码: $ADMIN_PASS${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Flarum 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart flarum
    echo -e "${GREEN}✅ Flarum 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f flarum
}

check_status() {
    docker ps | grep flarum
    read -p "按回车返回菜单..."
}

install_chinese() {

    if ! docker ps | grep -q flarum; then
        echo -e "${RED}Flarum 未运行${RESET}"
        read -p "按回车返回..."
        return
    fi

    echo -e "${GREEN}正在安装简体中文语言包...${RESET}"

    docker exec -it flarum sh -c "
    cd /flarum/app &&
    composer require flarum-lang/chinese-simplified &&
    php flarum cache:clear
    "

    echo
    echo -e "${GREEN}✅ 中文语言包安装完成${RESET}"
    echo -e "${YELLOW}后台启用:${RESET}"
    echo -e "${YELLOW}Admin → Extensions → Chinese Simplified${RESET}"

    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Flarum 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
