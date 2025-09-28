#!/bin/bash
# ========================================
# Lsky-Pro 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="lsky-pro"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== Lsky-Pro 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载 (含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 查看数据库信息${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}=========================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        5) show_db_info ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    read -p "请输入 Web 端口 [默认:7791]: " input_port
    PORT=${input_port:-7791}
    read -p "请输入数据库名 [默认:lskypro]: " input_db
    MYSQL_DATABASE=${input_db:-lskypro}
    read -p "请输入数据库用户 [默认:lskyuser]: " input_user
    MYSQL_USER=${input_user:-lskyuser}
    read -p "请输入数据库密码 [默认:自动生成]: " input_pass
    MYSQL_PASSWORD=${input_pass:-$(openssl rand -hex 8)}
    read -p "请输入 Root 密码 [默认:自动生成]: " input_root
    MYSQL_ROOT_PASSWORD=${input_root:-$(openssl rand -hex 8)}

    mkdir -p "$APP_DIR/data/html" "$APP_DIR/data/db"

    # 保存配置
    cat > "$CONFIG_FILE" <<EOF
PORT=$PORT
MYSQL_DATABASE=$MYSQL_DATABASE
MYSQL_USER=$MYSQL_USER
MYSQL_PASSWORD=$MYSQL_PASSWORD
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
EOF

    # 生成 compose
    cat > "$COMPOSE_FILE" <<EOF
services:
  lsky-pro:
    image: dko0/lsky-pro:latest
    container_name: lsky-pro
    restart: always
    ports:
      - "127.0.0.1:${PORT}:80"
    volumes:
      - ./data/html:/var/www/html
    environment:
      - MYSQL_HOST=mysql
      - MYSQL_DATABASE=\${MYSQL_DATABASE}
      - MYSQL_USER=\${MYSQL_USER}
      - MYSQL_PASSWORD=\${MYSQL_PASSWORD}
    depends_on:
      - mysql

  mysql:
    image: mysql:8.0
    container_name: lsky-pro-db
    restart: always
    environment:
      - MYSQL_DATABASE=\${MYSQL_DATABASE}
      - MYSQL_USER=\${MYSQL_USER}
      - MYSQL_PASSWORD=\${MYSQL_PASSWORD}
      - MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASSWORD}
    command: --default-authentication-plugin=mysql_native_password
    volumes:
      - ./data/db:/var/lib/mysql
EOF

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ Lsky-Pro 已启动${RESET}"
    echo -e "${GREEN}🌐 访问地址: http://127.0.0.1:$PORT${RESET}"
    show_db_info
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Lsky-Pro 已更新${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Lsky-Pro 已卸载并清理数据${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f lsky-pro
    read -p "按回车返回菜单..."
    menu
}

function show_db_info() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "未找到配置文件，请先安装"
        sleep 1
        menu
    fi
    source "$CONFIG_FILE"
    echo -e "${GREEN}📂 数据库信息:${RESET}"
    echo -e "数据库名: ${MYSQL_DATABASE}"
    echo -e "用户名:   ${MYSQL_USER}"
    echo -e "密码:     ${MYSQL_PASSWORD}"
    echo -e "Root 密码:${MYSQL_ROOT_PASSWORD}"
    echo -e "访问方式: mysql -u${MYSQL_USER} -p${MYSQL_PASSWORD} -h 127.0.0.1 -P3306 ${MYSQL_DATABASE}"
}

menu
