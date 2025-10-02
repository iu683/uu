#!/bin/bash
# ========================================
# DNSMgr 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"
YELLOW="\033[33m"

APP_NAME="dnsmgr"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== DNSMgr 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 重启${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        5) restart_app ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    mkdir -p "$APP_DIR/mysql/conf" "$APP_DIR/mysql/data" "$APP_DIR/mysql/logs" "$APP_DIR/web"

    # Web端口
    read -rp "请输入 Web 端口 [默认:8081]: " input_web
    WEB_PORT=${input_web:-8081}

    # MySQL root 密码
    read -rp "请输入 MySQL root 密码 [默认:123456]: " input_root
    MYSQL_ROOT_PASSWORD=${input_root:-123456}

    # 数据库名
    read -rp "请输入要创建的数据库名 [默认:dnsmgr]: " input_db
    DB_NAME=${input_db:-dnsmgr}

    # 数据库用户和密码
    read -rp "请输入数据库用户名 [默认:dnsmgruser]: " input_user
    DB_USER=${input_user:-dnsmgruser}
    read -rp "请输入数据库用户密码 [默认:dnsmgrpass]: " input_user_pass
    DB_PASSWORD=${input_user_pass:-dnsmgrpass}

    # 生成docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF

services:
  dnsmgr-web:
    container_name: dnsmgr-web
    stdin_open: true
    tty: true
    image: netcccyun/dnsmgr
    depends_on:
      - dnsmgr-mysql
    ports:
      - "127.0.0.1:$WEB_PORT:80"
    volumes:
      - $APP_DIR/web:/app/www
    networks:
      - dnsmgr-network

  dnsmgr-mysql:
    container_name: dnsmgr-mysql
    image: mysql:5.7
    restart: always
    ports:
      - "3306:3306"   # 可远程访问
    environment:
      - MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
      - TZ=Asia/Shanghai
    volumes:
      - $APP_DIR/mysql/conf/my.cnf:/etc/mysql/my.cnf
      - $APP_DIR/mysql/logs:/logs
      - $APP_DIR/mysql/data:/var/lib/mysql
    networks:
      - dnsmgr-network

networks:
  dnsmgr-network:
    driver: bridge
EOF

    # 保存配置
    echo -e "WEB_PORT=$WEB_PORT\nMYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD\nDB_NAME=$DB_NAME\nDB_USER=$DB_USER\nDB_PASSWORD=$DB_PASSWORD" > "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    # 等待 MySQL 启动（使用 TCP 连接，避免 socket 问题）
    echo "⏳ 等待 MySQL 启动..."
    for i in {1..30}; do
        docker exec dnsmgr-mysql mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" -h127.0.0.1 &>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}MySQL 已启动${RESET}"
            break
        fi
        sleep 2
        if [ $i -eq 30 ]; then
            echo -e "${RED}❌ MySQL 启动超时，请检查容器日志${RESET}"
            docker logs -f dnsmgr-mysql --tail 20
            read -p "按回车返回菜单..."
            menu
        fi
    done

    # 创建数据库和用户
    docker exec dnsmgr-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -h127.0.0.1 -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    docker exec dnsmgr-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -h127.0.0.1 -e "CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASSWORD';"
    docker exec dnsmgr-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -h127.0.0.1 -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';"
    docker exec dnsmgr-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -h127.0.0.1 -e "FLUSH PRIVILEGES;"

    # 测试用户连接
    docker exec dnsmgr-mysql mysql -u"$DB_USER" -p"$DB_PASSWORD" -h127.0.0.1 -e "USE \`$DB_NAME\`;" &>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 数据库 $DB_NAME 和用户 $DB_USER 创建成功，并可连接${RESET}"
    else
        echo -e "${RED}❌ 数据库连接失败，请检查 MySQL 配置${RESET}"
    fi

    # 显示数据库连接信息
    echo -e "${GREEN}🔑 数据库连接信息如下:${RESET}"
    echo -e "${GREEN}地址: $(hostname -I | awk '{print $1}')${RESET}"
    echo -e "${GREEN}端口: 3306${RESET}"
    echo -e "${GREEN}root密码: $MYSQL_ROOT_PASSWORD${RESET}"
    echo -e "${GREEN}数据库名: $DB_NAME${RESET}"
    echo -e "${GREEN}用户名: $DB_USER${RESET}"
    echo -e "${GREEN}密码: $DB_PASSWORD${RESET}"
    echo -e "${YELLOW}Web UI 地址: http://127.0.0.1:$WEB_PORT${RESET}"
    echo -e "${GREEN}数据目录: $APP_DIR${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ DNSMgr 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ DNSMgr 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f dnsmgr-web
    read -p "按回车返回菜单..."
    menu
}

function restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ DNSMgr 已重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
