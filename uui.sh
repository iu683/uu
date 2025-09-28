#!/bin/bash
# ========================================
# MySQL 一键管理脚本 (Docker Compose) - 安全版
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="mysql"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"
BACKUP_DIR="$APP_DIR/backup"

# 随机密码生成函数
gen_pass() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

pause() {
    read -p "按回车返回菜单..."
}

function menu() {
    clear
    echo -e "${GREEN}=== MySQL 管理菜单 ===${RESET}"
    echo -e "${GREEN}1.  安装/启动${RESET}"
    echo -e "${GREEN}2.  更新${RESET}"
    echo -e "${GREEN}3.  卸载 (含数据)${RESET}"
    echo -e "${GREEN}4.  查看日志${RESET}"
    echo -e "${GREEN}7.  删除容器和数据${RESET}"
    echo -e "${GREEN}8.  创建新数据库${RESET}"
    echo -e "${GREEN}9.  创建用户并授权${RESET}"
    echo -e "${GREEN}10. 一键创建数据库+用户+授权${RESET}"
    echo -e "${GREEN}11. 查看访问地址${RESET}"
    echo -e "${GREEN}12. 备份数据库${RESET}"
    echo -e "${GREEN}13. 恢复数据库${RESET}"
    echo -e "${GREEN}0.  退出${RESET}"
    echo -e "${GREEN}=======================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        7) remove_container ;;
        8) create_database ;;
        9) create_user ;;
        10) create_db_user ;;
        11) show_info ;;
        12) backup_db ;;
        13) restore_db ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    read -p "请输入 MySQL 端口 [默认:3306]: " input_port
    PORT=${input_port:-3306}

    read -p "请输入 MySQL root 密码 [留空自动生成]: " input_pass
    ROOT_PASSWORD=${input_pass:-$(gen_pass)}

    mkdir -p "$APP_DIR/data" "$APP_DIR/config" "$BACKUP_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  mysql-db:
    container_name: mysql
    image: mysql:8.0
    restart: always
    ports:
      - "127.0.0.1:${PORT}:3306"
    environment:
      MYSQL_ROOT_PASSWORD: ${ROOT_PASSWORD}
    volumes:
      - ./data:/var/lib/mysql
      - ./config:/etc/mysql/conf.d
EOF

    cat > "$CONFIG_FILE" <<EOF
PORT=$PORT
ROOT_PASSWORD=$ROOT_PASSWORD
EOF

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ MySQL 已启动${RESET}"
    show_info
    pause
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ MySQL 已更新并重启完成${RESET}"
    pause
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ MySQL 已卸载，数据已删除${RESET}"
    pause
    menu
}

function remove_container() {
    docker rm -f mysql
    echo -e "${GREEN}✅ MySQL 容器已删除 (数据保留在 $APP_DIR/data)${RESET}"
    pause
    menu
}

function create_database() {
    source "$CONFIG_FILE"
    read -p "请输入数据库名: " db
    docker exec -i mysql sh -c "MYSQL_PWD='$ROOT_PASSWORD' mysql -uroot -e \"CREATE DATABASE \`$db\`;\""
    echo -e "${GREEN}✅ 数据库 $db 已创建${RESET}"
    pause
    menu
}

function create_user() {
    source "$CONFIG_FILE"
    read -p "请输入新用户名: " user
    read -p "请输入新用户密码 [留空自动生成]: " pass
    pass=${pass:-$(gen_pass)}
    read -p "请输入数据库名 (授权给该用户): " db
    docker exec -i mysql sh -c "MYSQL_PWD='$ROOT_PASSWORD' mysql -uroot -e \"CREATE USER '$user'@'%' IDENTIFIED BY '$pass'; GRANT ALL PRIVILEGES ON \`$db\`.* TO '$user'@'%'; FLUSH PRIVILEGES;\""
    echo -e "${GREEN}✅ 用户 $user 已创建，密码: $pass${RESET}"
    pause
    menu
}

function create_db_user() {
    source "$CONFIG_FILE"
    read -p "请输入数据库名: " db
    read -p "请输入新用户名: " user
    read -p "请输入新用户密码 [留空自动生成]: " pass
    pass=${pass:-$(gen_pass)}
    docker exec -i mysql sh -c "MYSQL_PWD='$ROOT_PASSWORD' mysql -uroot -e \"CREATE DATABASE \`$db\`; CREATE USER '$user'@'%' IDENTIFIED BY '$pass'; GRANT ALL PRIVILEGES ON \`$db\`.* TO '$user'@'%'; FLUSH PRIVILEGES;\""
    echo -e "${GREEN}✅ 数据库 $db 和用户 $user 已创建，密码: $pass${RESET}"
    pause
    menu
}

function backup_db() {
    source "$CONFIG_FILE"
    mkdir -p "$BACKUP_DIR"
    read -p "请输入要备份的数据库名: " db
    BACKUP_FILE="$BACKUP_DIR/${db}_$(date +%Y%m%d%H%M%S).sql"
    docker exec -i mysql sh -c "MYSQL_PWD='$ROOT_PASSWORD' mysqldump -uroot $db" > "$BACKUP_FILE"
    echo -e "${GREEN}✅ 数据库 $db 已备份到 $BACKUP_FILE${RESET}"
    pause
    menu
}

function restore_db() {
    source "$CONFIG_FILE"
    echo -e "${GREEN}备份文件列表:${RESET}"
    ls -1 "$BACKUP_DIR"
    read -p "请输入要恢复的备份文件名: " file
    docker exec -i mysql sh -c "MYSQL_PWD='$ROOT_PASSWORD' mysql -uroot" < "$BACKUP_DIR/$file"
    echo -e "${GREEN}✅ 数据库已从 $file 恢复${RESET}"
    pause
    menu
}

function show_info() {
    source "$CONFIG_FILE"
    echo -e "${GREEN}📦 数据目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}⚙️ 配置目录: $APP_DIR/config${RESET}"
    echo -e "${GREEN}🔑 root 密码: $ROOT_PASSWORD${RESET}"
    echo -e "${GREEN}🌐 连接地址: 127.0.0.1:$PORT${RESET}"
}

function view_logs() {
    docker logs -f mysql
    pause
    menu
}

menu
