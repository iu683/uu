#!/bin/bash
# ========================================
# Typecho 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="typecho"
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

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。" && return
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Typecho 管理菜单 ===${RESET}"
        echo -e "${GREEN}1. 安装启动${RESET}"
        echo -e "${GREEN}2. 更新${RESET}"
        echo -e "${GREEN}3. 重启${RESET}"
        echo -e "${GREEN}4. 查看日志${RESET}"
        echo -e "${GREEN}5. 查看状态${RESET}"
        echo -e "${GREEN}6. 卸载${RESET}"
        echo -e "${GREEN}0. 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            0) exit 0 ;;
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

    read -p "请输入访问端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}
    check_port "$PORT" || return

    # 网站地址
    read -p "请输入网站URL [默认:http://localhost:${PORT}]: " input_url
    SITE_URL=${input_url:-http://localhost:${PORT}}

    read -p "请输入数据目录 [默认:$APP_DIR/Typecho]: " input_data
    DATA_DIR=${input_data:-$APP_DIR/Typecho}

    read -p "请输入 MySQL root 密码: " MYSQL_ROOT_PASSWORD
    read -p "请输入 Typecho 数据库密码: " MYSQL_PASSWORD

    mkdir -p "$DATA_DIR/Typecho"
    mkdir -p "$APP_DIR/db"

cat > "$COMPOSE_FILE" <<EOF
services:
  db:
    image: mysql:8.0
    container_name: typecho-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: typecho
      MYSQL_USER: typecho
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - ${APP_DIR}/db:/var/lib/mysql

  typecho:
    image: joyqi/typecho:nightly-php8.2-apache
    container_name: typecho-server
    restart: always
    ports:
      - "127.0.0.1:${PORT}:80"
    environment:
      TYPECHO_SITE_URL: ${SITE_URL}
      TZ: Asia/Shanghai
    volumes:
      - ${DATA_DIR}:/app/usr
    depends_on:
      - db
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败${RESET}"
        return
    fi

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ Typecho 已启动${RESET}"
    echo -e "${YELLOW}访问地址: ${SITE_URL}${RESET}"
    echo
    echo -e "${GREEN}数据库信息:${RESET}"
    echo -e "${YELLOW}数据库地址: db${RESET}"
    echo -e "${YELLOW}数据库名: typecho${RESET}"
    echo -e "${YELLOW}数据库用户: typecho${RESET}"
    echo -e "${YELLOW}数据库密码: ${MYSQL_PASSWORD}${RESET}"
    echo
    echo -e "${YELLOW}数据目录: ${DATA_DIR}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ typecho更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart typecho-server
    echo -e "${GREEN}✅ typecho已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f typecho-server
}

check_status() {
    docker ps | grep typecho-server
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ typecho已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
