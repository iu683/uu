#!/bin/bash
# ========================================
# MySQL 一键管理脚本 (Docker Compose) - Mosdns 风格最终强化版
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
YELLOW="\033[33m"
RED="\033[31m"
APP_NAME="mysql"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"
BACKUP_DIR="$APP_DIR/backup"

# 随机密码生成函数
gen_pass() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP"
}

pause() {
    read -p $'\e[32m按回车返回菜单...\e[0m'
}

# 获取容器动态状态用于菜单显示
get_sys_status() {
    if [ ! -f "$CONFIG_FILE" ]; then
        status="${RED}未安装${RESET}"
        version="${RED}无${RESET}"
        port_show="${RED}无${RESET}"
    else
        source "$CONFIG_FILE"
        version="8.0 (Docker)"
        port_show="$PORT"
        
        if [ "$(docker ps -q -f name=^mysql$)" ]; then
            status="${GREEN}运行中${RESET}"
        elif [ "$(docker ps -a -q -f name=^mysql$)" ]; then
            status="${YELLOW}已停止${RESET}"
        else
            status="${RED}未启动 (容器不存在)${RESET}"
        fi
    fi
}

# ==================== 菜单 ====================
function menu() {
    clear
    get_sys_status
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  MySQL 容器管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 Mosdns-MySQL${RESET}"
    echo -e "${GREEN} 2. 更新 Mosdns-MySQL${RESET}"
    echo -e "${GREEN} 3. 卸载 Mosdns-MySQL${RESET}"
    echo -e "${GREEN} 4. 查看数据库信息${RESET}"
    echo -e "${GREEN} 5. 启动 Mosdns-MySQL${RESET}"
    echo -e "${GREEN} 6. 停止 Mosdns-MySQL${RESET}"
    echo -e "${GREEN} 7. 重启 Mosdns-MySQL${RESET}"
    echo -e "${GREEN} 8. 查看运行日志${RESET}"
    echo -e "${GREEN} 9. 创建新数据库${RESET}"
    echo -e "${GREEN}10. 删除已有数据库${RESET}"
    echo -e "${GREEN}11. 创建用户并授权${RESET}"
    echo -e "${GREEN}12. 一键创建库+用户${RESET}"
    echo -e "${GREEN}13. 备份数据库 (Dump)${RESET}"
    echo -e "${GREEN}14. 恢复数据库 (Source)${RESET}"
    echo -e "${GREEN} 0. 退出面板${RESET}"
    echo -e "${GREEN}================================${RESET}"
    
    read -p $'\e[32m请输入数字: \e[0m' num
    case "$num" in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) show_info ;;
        5) start_mysql ;;
        6) stop_mysql ;;
        7) restart_mysql ;;
        8) view_logs ;;
        9) create_database ;;
        10) delete_database ;;
        11) create_user ;;
        12) create_db_user ;;
        13) backup_db ;;
        14) restore_db ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

# ==================== 功能实现 ====================

function install_app() {
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${RED}⚠️ 检测到已经安装过 MySQL。${RESET}"
        pause; menu
    fi
    read -p "请输入 MySQL 端口 [默认 3306]: " input_port
    PORT=${input_port:-3306}
    read -p "请输入 root 密码 [留空自动生成]: " input_pass
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
    cd "$APP_DIR" && docker compose up -d
    echo -e "${GREEN}✅ MySQL 安装启动成功！${RESET}"
    pause; menu
}

function update_app() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}未检测到安装目录，请先安装${RESET}"; sleep 1; menu; fi
    cd "$APP_DIR" && docker compose pull && docker compose up -d
    echo -e "${GREEN}✅ MySQL 已更新并重启${RESET}"
    pause; menu
}

function uninstall_app() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}未检测到安装目录${RESET}"; sleep 1; menu; fi
    read -p "确定要彻底卸载吗？数据将清空！(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        cd "$APP_DIR" && docker compose down -v
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ MySQL 已彻底卸载${RESET}"
    else
        echo -e "${YELLOW}已取消卸载${RESET}"
    fi
    pause; menu
}

function start_mysql() {
    docker start mysql &>/dev/null
    echo -e "${GREEN}✅ MySQL 容器已启动${RESET}"
    pause; menu
}

function stop_mysql() {
    docker stop mysql &>/dev/null
    echo -e "${GREEN}✅ MySQL 容器已停止${RESET}"
    pause; menu
}

function restart_mysql() {
    docker restart mysql &>/dev/null
    echo -e "${GREEN}✅ MySQL 容器已重启${RESET}"
    pause; menu
}

function view_logs() {
    echo -e "${YELLOW}提示: 朝下滚动，按下 Ctrl + C 即可退出日志回到主菜单。${RESET}"
    sleep 1
    docker logs --tail 100 -f mysql
    menu
}

# 4. 查看数据库信息
function show_info() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MySQL${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    SERVER_IP=$(get_public_ip)
    
    echo -e "\n${GREEN}====== MySQL 运行信息 ======${RESET}"
    echo -e "${GREEN}连接地址 :${RESET} ${SERVER_IP}:${PORT}"
    echo -e "${GREEN}root密码 :${RESET} ${YELLOW}${ROOT_PASSWORD}${RESET}"
    echo -e "${GREEN}安装路径 :${RESET} $APP_DIR"
    echo -e "${GREEN}================================${RESET}"
    
    echo -e "${GREEN}当前数据库列表:${RESET}"
    docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" -e "SHOW DATABASES;" | grep -Ev "Database|information_schema|performance_schema|sys|mysql"
    
    echo -e "\n${GREEN}当前自定义用户:${RESET}"
    docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" -e "SELECT user, host FROM mysql.user;" | grep -Ev "user|root|mysql.sys|mysql.session|mysql.infoschema"
    echo -e "${GREEN}================================${RESET}"
    pause; menu
}

# 9. 创建数据库
function create_database() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MySQL${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    read -p "请输入新数据库名: " new_db
    read -p "请输入字符集(默认 utf8mb4): " charset
    charset=${charset:-utf8mb4}
    
    local collate=""
    [ "$charset" = "utf8mb4" ] && collate="COLLATE utf8mb4_0900_ai_ci"

    docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS \`$new_db\` CHARACTER SET $charset $collate;
EOF
    echo -e "${YELLOW}✅ 数据库 $new_db 已尝试创建${RESET}"
    pause; menu
}

# 10. 删除数据库
function delete_database() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MySQL${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    echo -e "${GREEN}当前可删除的数据库列表:${RESET}"
    docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" -e "SHOW DATABASES;" | grep -Ev "Database|information_schema|performance_schema|sys|mysql"
    echo "--------------------------------"
    read -p "请输入要删除的数据库名: " del_db
    
    if [ -z "$del_db" ]; then
        echo -e "${RED}输入不能为空！${RESET}"
        pause; menu
    fi
    
    read -p "⚠️ 警告：确定要彻底删除数据库 [$del_db] 吗？数据将不可恢复！(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" -e "DROP DATABASE \`$del_db\`;" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 数据库 $del_db 删除成功。${RESET}"
        else
            echo -e "${RED}❌ 删除失败，请确认数据库名是否存在或属于系统关键库。${RESET}"
        fi
    else
        echo -e "${YELLOW}操作已取消。${RESET}"
    fi
    pause; menu
}

function create_user() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MySQL${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    read -p "请输入新用户名: " new_user
    read -p "请输入新用户密码 [留空随机]: " new_pass
    new_pass=${new_pass:-$(gen_pass)}
    read -p "授权数据库名 (输入 * 代表全部): " grant_db

    local target="\`$grant_db\`.*"
    [ "$grant_db" = "*" ] && target="*.*"

    docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" <<EOF
CREATE USER IF NOT EXISTS '$new_user'@'%' IDENTIFIED BY '$new_pass';
GRANT ALL PRIVILEGES ON $target TO '$new_user'@'%';
FLUSH PRIVILEGES;
EOF
    echo -e "${YELLOW}✅ 用户 $new_user 创建成功。密码: $new_pass${RESET}"
    pause; menu
}

function create_db_user() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MySQL${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    read -p "新数据库名: " new_db
    read -p "新用户名: " new_user
    read -p "密码 [留空随机]: " new_pass
    new_pass=${new_pass:-$(gen_pass)}

    docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS \`$new_db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER IF NOT EXISTS '$new_user'@'%' IDENTIFIED BY '$new_pass';
GRANT ALL PRIVILEGES ON \`$new_db\`.* TO '$new_user'@'%';
FLUSH PRIVILEGES;
EOF
    echo -e "${YELLOW}✅ 联动创建成功。用户: $new_user 密码: $new_pass${RESET}"
    pause; menu
}

function backup_db() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MySQL${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    mkdir -p "$BACKUP_DIR"
    read -p "要备份的库名 (全库输入 --all-databases): " db
    local filename="$db"
    [ "$db" = "--all-databases" ] && filename="all"
    BACKUP_FILE="$BACKUP_DIR/${filename}_$(date +%Y%m%d_%H%M%S).sql"
    
    docker exec -i mysql mysqldump -uroot -p"$ROOT_PASSWORD" --default-character-set=utf8mb4 "$db" > "$BACKUP_FILE"
    echo -e "${YELLOW}✅ 备份完成: $BACKUP_FILE${RESET}"
    pause; menu
}

function restore_db() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MySQL${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR")" ]; then
        echo -e "${RED}❌ 没有找到备份文件${RESET}"; pause; menu
    fi
    echo -e "${GREEN}可用备份:${RESET}"
    ls -1 "$BACKUP_DIR"
    read -p "请输入完整备份文件名: " file
    read -p "目标数据库名 (全库备份直接回车): " target_db

    if [ -z "$target_db" ]; then
        docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" < "$BACKUP_DIR/$file"
    else
        docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS \`$target_db\`;"
        docker exec -i mysql mysql -uroot -p"$ROOT_PASSWORD" "$target_db" < "$BACKUP_DIR/$file"
    fi
    echo -e "${YELLOW}✅ 导入指令执行完毕${RESET}"
    pause; menu
}

# ==================== 启动 ====================
menu
