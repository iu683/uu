#!/bin/bash
# ========================================
# MySQL 一键管理脚本 (Docker Compose) - 完整安全版
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

# ==================== 菜单 ====================
function menu() {
    clear
    echo -e "${GREEN}=== MySQL 管理菜单 ===${RESET}"
    echo -e "${GREEN}1.  安装启动${RESET}"
    echo -e "${GREEN}2.  更新${RESET}"
    echo -e "${GREEN}3.  卸载${RESET}"
    echo -e "${GREEN}4.  查看日志${RESET}"
    echo -e "${GREEN}5.  创建新数据库${RESET}"
    echo -e "${GREEN}6.  创建用户并授权${RESET}"
    echo -e "${GREEN}7.  一键创建数据库+用户+授权${RESET}"
    echo -e "${GREEN}8.  查看数据库信息${RESET}"
    echo -e "${GREEN}9.  备份数据库${RESET}"
    echo -e "${GREEN}10. 恢复数据库${RESET}"
    echo -e "${GREEN}0.  退出${RESET}"
    echo -e "${GREEN}=======================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        5) create_database ;;
        6) create_user ;;
        7) create_db_user ;;
        8) show_info ;;
        9) backup_db ;;
        10) restore_db ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

# ==================== 安装 ====================
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
      - "${PORT}:3306"
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
    pause
    menu
}

# ==================== 更新 ====================
function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ MySQL 已更新并重启完成${RESET}"
    pause
    menu
}

# ==================== 卸载 ====================
function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ MySQL 已卸载，数据已删除${RESET}"
    pause
    menu
}

# ==================== 删除容器 ====================
function remove_container() {
    docker rm -f mysql
    echo -e "${GREEN}✅ MySQL 容器已删除 (数据保留在 $APP_DIR/data)${RESET}"
    pause
    menu
}

# ==================== 创建数据库 ====================
function create_database() {
    source "$CONFIG_FILE"
    read -p "请输入新数据库名: " new_db
    read -p "请输入字符集(默认utf8mb4): " charset
    charset=${charset:-utf8mb4}

    docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS \`$new_db\` CHARACTER SET $charset COLLATE ${charset}_general_ci;
EOF

    echo -e "${GREEN}✅ 数据库 $new_db 已创建 (字符集: $charset)${RESET}"
    pause
    menu
}

# ==================== 创建用户并授权 ====================
function create_user() {
    source "$CONFIG_FILE"
    read -p "请输入新用户名: " new_user
    read -p "请输入新用户密码 [留空自动生成]: " new_pass
    new_pass=${new_pass:-$(gen_pass)}
    read -p "请输入要授权的数据库名: " grant_db

    docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" <<EOF
CREATE USER IF NOT EXISTS '$new_user'@'%' IDENTIFIED BY '$new_pass';
GRANT ALL PRIVILEGES ON \`$grant_db\`.* TO '$new_user'@'%';
FLUSH PRIVILEGES;
EOF

    echo -e "${GREEN}✅ 用户 $new_user 已创建，并对数据库 $grant_db 授予全部权限${RESET}"
    pause
    menu
}

# ==================== 一键创建数据库+用户+授权 ====================
function create_db_user() {
    source "$CONFIG_FILE"
    read -p "请输入新数据库名: " new_db
    read -p "请输入字符集(默认utf8mb4): " charset
    charset=${charset:-utf8mb4}
    read -p "请输入新用户名: " new_user
    read -p "请输入新用户密码 [留空自动生成]: " new_pass
    new_pass=${new_pass:-$(gen_pass)}

    docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS \`$new_db\` CHARACTER SET $charset COLLATE ${charset}_general_ci;
CREATE USER IF NOT EXISTS '$new_user'@'%' IDENTIFIED BY '$new_pass';
GRANT ALL PRIVILEGES ON \`$new_db\`.* TO '$new_user'@'%';
FLUSH PRIVILEGES;
EOF

    echo -e "${GREEN}✅ 数据库 $new_db 已创建 (字符集: $charset)${RESET}"
    echo -e "${GREEN}✅ 用户 $new_user 已创建，并拥有数据库 $new_db 的全部权限${RESET}"
    pause
    menu
}

# ==================== 备份数据库 ====================
function backup_db() {
    source "$CONFIG_FILE"
    mkdir -p "$BACKUP_DIR"
    read -p "请输入要备份的数据库名: " db
    BACKUP_FILE="$BACKUP_DIR/${db}_$(date +%Y%m%d%H%M%S).sql"
    docker exec -i mysql mysqldump -uroot -p"$ROOT_PASSWORD" "$db" > "$BACKUP_FILE"
    echo -e "${GREEN}✅ 数据库 $db 已备份到 $BACKUP_FILE${RESET}"
    pause
    menu
}

# ==================== 恢复数据库 ====================
function restore_db() {
    source "$CONFIG_FILE"
    echo -e "${GREEN}备份文件列表:${RESET}"
    ls -1 "$BACKUP_DIR"
    read -p "请输入要恢复的备份文件名: " file
    docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" < "$BACKUP_DIR/$file"
    echo -e "${GREEN}✅ 数据库已从 $file 恢复${RESET}"
    pause
    menu
}

# ==================== 查看信息 ====================
function show_info() {
    source "$CONFIG_FILE"

    # 获取公网 IP（用可靠免费接口）
    HOST_IP=$(curl -s https://ifconfig.me 2>/dev/null)
    if [[ -z "$HOST_IP" ]]; then
        # 公网 IP 获取失败，使用局域网 IP
        HOST_IP=$(hostname -I | awk '{print $1}')
    fi

    echo -e "${GREEN}📦 数据目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}⚙️ 配置目录: $APP_DIR/config${RESET}"
    echo -e "${GREEN}🔑 root 密码: $ROOT_PASSWORD${RESET}"
    echo -e "${GREEN}🌐 连接地址: $HOST_IP:$PORT${RESET}"

    # 列出已创建数据库
    echo -e "${GREEN}📂 已创建数据库:${RESET}"
    docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" -e "SHOW DATABASES;" | tail -n +2

    # 列出已创建用户
    echo -e "${GREEN}👤 已创建用户:${RESET}"
    docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" -e "SELECT user, host FROM mysql.user;" | tail -n +2

    pause
    menu
}




# ==================== 查看日志 ====================
function view_logs() {
    docker logs -f mysql
    pause
    menu
}

# ==================== 启动菜单 ====================
menu
