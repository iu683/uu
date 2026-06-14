#!/bin/bash
# ========================================
# MySQL 一键管理脚本 (Docker Compose)
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

# 自动适配 docker compose 语法
if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

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

get_local_ip() {
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-127.0.0.1}"
}

pause() {
    read -p $'\e[32m按回车返回菜单...\e[0m'
}

# 获取容器动态状态及数据库个数用于菜单显示
get_sys_status() {
    if [ ! -f "$CONFIG_FILE" ]; then
        status="${RED}未安装${RESET}"
        version="${RED}无${RESET}"
        port_show="${RED}无${RESET}"
        db_count="${RED}0${RESET}"
    else
        source "$CONFIG_FILE"
        version="8.0"
        port_show="$PORT"
        
        if [ "$(docker ps -q -f name=^mysql$)" ]; then
            status="${GREEN}运行中${RESET}"
            db_count=$(docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysql -uroot -e "SHOW DATABASES;" 2>/dev/null | grep -Ev "Database|information_schema|performance_schema|sys|mysql" | wc -l)
            db_count="${YELLOW}${db_count//[[:space:]]/}${RESET} ${GREEN}个${RESET}"
        elif [ "$(docker ps -a -q -f name=^mysql$)" ]; then
            status="${YELLOW}已停止${RESET}"
            db_count="${YELLOW}未知 (请先启动容器)${RESET}"
        else
            status="${RED}未启动 (容器不存在)${RESET}"
            db_count="${RED}0${RESET}"
        fi
    fi
}

# ==================== 菜单 ====================
function menu() {
    clear
    get_sys_status
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  MySQL 容器管理面板 ◈     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态       :${RESET} $status"
    echo -e "${GREEN}版本       :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口       :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}已创数据库 :${RESET} $db_count"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 MySQL${RESET}"
    echo -e "${GREEN} 2. 更新 MySQL${RESET}"
    echo -e "${GREEN} 3. 卸载 MySQL${RESET}"
    echo -e "${GREEN} 4. 启动 MySQL${RESET}"
    echo -e "${GREEN} 5. 停止 MySQL${RESET}"
    echo -e "${GREEN} 6. 重启 MySQL${RESET}"
    echo -e "${GREEN} 7. 查看运行日志${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${GREEN} 8. 数据库信息${RESET}"
    echo -e "${GREEN} 9. 创建数据库${RESET}"
    echo -e "${GREEN}10. 删除数据库${RESET}"
    echo -e "${GREEN}11. 创建用户并授权${RESET}"
    echo -e "${GREEN}12. 创建数据库+用户${RESET}"
    echo -e "${GREEN}13. 修改用户密码${RESET}"
    echo -e "${GREEN}14. 删除已有用户${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${GREEN}15. 备份数据库${RESET}"
    echo -e "${GREEN}16. 恢复数据库${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    
    read -p $'\e[32m请输入选项: \e[0m' num
    case "$num" in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) start_mysql ;;
        5) stop_mysql ;;
        6) restart_mysql ;;
        7) view_logs ;;
        8) show_info ;;
        9) create_database ;;
        10) delete_database ;;
        11) create_user ;;
        12) create_db_user ;;
        13) change_password ;;
        14) delete_user ;;
        15) backup_db ;;
        16) restore_db ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

# ==================== 功能实现 ====================

function install_app() {
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${RED}检测到已经安装过 MySQL。${RESET}"
        pause; menu
    fi
    
    # 1. 输入端口
    read -p "请输入 MySQL 端口 [默认 3306]: " input_port
    PORT=${input_port:-3306}
    
    # 2. 选择 IP 绑定策略
    echo -e "\n请选择网络绑定策略 (IP Binding):"
    echo -e "  [1] 允许公网/局域网访问 (绑定 0.0.0.0) [默认]"
    echo -e "  [2] 仅允许本地访问     (绑定 127.0.0.1)"
    read -p "请输入数字 [1-2, 默认 1]: " bind_choice
    bind_choice=${bind_choice:-1}
    
    local compose_port_mapping
    local bind_status_text
    if [ "$bind_choice" = "2" ]; then
        compose_port_mapping="127.0.0.1:${PORT}:3306"
        bind_status_text="仅限本地 (127.0.0.1)"
    else
        compose_port_mapping="${PORT}:3306"
        bind_status_text="开放公网 (0.0.0.0)"
    fi

    # 3. 输入或生成密码
    read -p "请输入 root 密码 [留空自动生成]: " input_pass
    ROOT_PASSWORD=${input_pass:-$(gen_pass)}

    # 创建必要的目录
    mkdir -p "$APP_DIR/data" "$APP_DIR/config" "$BACKUP_DIR"
    
    # 4. 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  mysql-db:
    container_name: mysql
    image: mysql:8.0
    restart: always
    ports:
      - "${compose_port_mapping}"
    environment:
      MYSQL_ROOT_PASSWORD: ${ROOT_PASSWORD}
      TZ: Asia/Shanghai
    volumes:
      - ./data:/var/lib/mysql
      - ./config:/etc/mysql/conf.d
EOF

    # 5. 生成本地环境记录文件
    cat > "$CONFIG_FILE" <<EOF
PORT=$PORT
ROOT_PASSWORD=$ROOT_PASSWORD
BIND_STRATEGY=$bind_choice
EOF

    # 6. 部署容器
    cd "$APP_DIR" && $COMPOSE_CMD up -d
    
    # 获取展示需要的 IP
    local public_ip=$(get_public_ip)
    local local_ip=$(get_local_ip)
    
    # 7. 输出精美的连接卡片
    echo -e "\n${GREEN}================================================${RESET}"
    echo -e "${GREEN}🎉 MySQL 安装启动成功！运行连接信息如下：${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN} 网络绑定策略 :${RESET} ${YELLOW}${bind_status_text}${RESET}"
    if [ "$bind_choice" = "2" ]; then
        echo -e "${GREEN} 唯一连接地址 :${RESET} 127.0.0.1:${PORT}"
    else
        echo -e "${GREEN} 公网连接地址 :${RESET} ${public_ip}:${PORT}"
        echo -e "${GREEN} 内网连接地址 :${RESET} 127.0.0.1:${PORT}"
    fi
    echo -e "${GREEN} 管理用户名   :${RESET} root"
    echo -e "${GREEN} 管理员密码   :${RESET} ${YELLOW}${ROOT_PASSWORD}${RESET}"
    echo -e "${GREEN} 配置文件路径 :${RESET} ${CONFIG_FILE}"
    echo -e "${GREEN}================================================${RESET}"
    
    if [ "$bind_choice" = "1" ]; then
        echo -e "${YELLOW}提示：由于你开启了公网访问，请务必前往云服务器控制台放行 ${PORT} 端口！${RESET}\n"
    else
        echo -e "${BLUE}提示：由于你选择了仅本地访问，外部任何 IP (包括Navicat远程) 将无法连接，这非常安全。${RESET}\n"
    fi
    
    pause; menu
}

function update_app() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}未检测到安装目录，请先安装${RESET}"; sleep 1; menu; fi
    cd "$APP_DIR" && $COMPOSE_CMD pull && $COMPOSE_CMD up -d
    echo -e "${GREEN}✅ MySQL 已更新并重启${RESET}"
    pause; menu
}

function uninstall_app() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}未检测到安装目录${RESET}"; sleep 1; menu; fi
    read -p "确定要彻底卸载吗？数据将清空！(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" || "$confirm" == "yes" ]]; then
        cd "$APP_DIR" && $COMPOSE_CMD down -v
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

function show_info() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MySQL${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    SERVER_IP=$(get_public_ip)
    local local_ip=$(get_local_ip)
    
    # 兼容处理未记录绑定策略的历史版本
    BIND_STRATEGY=${BIND_STRATEGY:-1}
    
    echo -e "\n${GREEN}====== MySQL 运行信息 ======${RESET}"
    if [ "$BIND_STRATEGY" = "2" ]; then
        echo -e "${GREEN}绑定状态 :${RESET} ${YELLOW}仅限本地监听 (127.0.0.1)${RESET}"
        echo -e "${GREEN}连接地址 :${RESET} 127.0.0.1:${PORT}"
    else
        echo -e "${GREEN}绑定状态 :${RESET} ${GREEN}开放公网/局域网 (0.0.0.0)${RESET}"
        echo -e "${GREEN}公网地址 :${RESET} ${SERVER_IP}:${PORT}"
        echo -e "${GREEN}内网地址 :${RESET} ${local_ip}:${PORT}"
    fi
    echo -e "${GREEN}root密码 :${RESET} ${YELLOW}${ROOT_PASSWORD}${RESET}"
    echo -e "${GREEN}安装路径 :${RESET} $APP_DIR"
    echo -e "${GREEN}================================${RESET}"
    
    echo -e "${GREEN}当前数据库列表:${RESET}"
    docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysql -uroot -e "SHOW DATABASES;" | grep -Ev "Database|information_schema|performance_schema|sys|mysql"
    
    echo -e "\n${GREEN}当前自定义用户:${RESET}"
    docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysql -uroot -e "SELECT user, host FROM mysql.user;" | grep -Ev "user|root|mysql.sys|mysql.session|mysql.infoschema"
    echo -e "${GREEN}================================${RESET}"
    pause; menu
}

function create_database() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MySQL${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    read -p "请输入新数据库名: " new_db
    if [ -z "$new_db" ]; then echo -e "${RED}输入不能为空！${RESET}"; pause; menu; fi
    read -p "请输入字符集(默认 utf8mb4): " charset
    charset=${charset:-utf8mb4}
    
    local collate=""
    [ "$charset" = "utf8mb4" ] && collate="COLLATE utf8mb4_0900_ai_ci"

    docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS \`$new_db\` CHARACTER SET $charset $collate;
EOF
    echo -e "${YELLOW}✅ 数据库 $new_db 已尝试创建${RESET}"
    pause; menu
}

function delete_database() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MySQL${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    echo -e "${GREEN}当前可删除的数据库列表:${RESET}"
    docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysql -uroot -e "SHOW DATABASES;" | grep -Ev "Database|information_schema|performance_schema|sys|mysql"
    echo "--------------------------------"
    read -p "请输入要删除的数据库名: " del_db
    
    if [ -z "$del_db" ]; then
        echo -e "${RED}输入不能为空！${RESET}"
        pause; menu
    fi
    
    read -p "警告：确定要彻底删除数据库 [$del_db] 吗？数据将不可恢复！(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" || "$confirm" == "yes" ]]; then
        docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysql -uroot -e "DROP DATABASE \`$del_db\`;" 2>/dev/null
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
    if [ -z "$new_user" ]; then echo -e "${RED}用户名不能为空！${RESET}"; pause; menu; fi
    read -p "请输入新用户密码 [留空随机]: " new_pass
    new_pass=${new_pass:-$(gen_pass)}
    read -p "授权数据库名 (输入 * 代表全部): " grant_db

    local target="\`$grant_db\`.*"
    [ "$grant_db" = "*" ] && target="*.*"

    docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysql -uroot <<EOF
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
    if [[ -z "$new_db" || -z "$new_user" ]]; then echo -e "${RED}库名和用户名不能为空！${RESET}"; pause; menu; fi
    read -p "密码 [留空随机]: " new_pass
    new_pass=${new_pass:-$(gen_pass)}

    docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS \`$new_db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER IF NOT EXISTS '$new_user'@'%' IDENTIFIED BY '$new_pass';
GRANT ALL PRIVILEGES ON \`$new_db\`.* TO '$new_user'@'%';
FLUSH PRIVILEGES;
EOF
    echo -e "${YELLOW}✅ 联动创建成功。用户: $new_user 密码: $new_pass${RESET}"
    pause; menu
}

function change_password() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MySQL${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    echo -e "${GREEN}当前系统中的自定义用户:${RESET}"
    docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysql -uroot -e "SELECT user, host FROM mysql.user;" | grep -Ev "user|mysql.sys|mysql.session|mysql.infoschema"
    echo "--------------------------------"
    
    read -p "请输入要修改密码的用户名 [默认 root]: " target_user
    target_user=${target_user:-root}
    read -p "请输入新密码 [留空随机生成]: " new_pass
    new_pass=${new_pass:-$(gen_pass)}

    docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysql -uroot <<EOF
ALTER USER '$target_user'@'%' IDENTIFIED BY '$new_pass';
FLUSH PRIVILEGES;
EOF

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 用户 '$target_user' 密码修改成功！新密码: ${YELLOW}$new_pass${RESET}"
        
        if [ "$target_user" = "root" ]; then
            echo -e "${YELLOW}检测到修改了 root 密码，正在同步本地配置文件...${RESET}"
            sed -i "s/^ROOT_PASSWORD=.*/ROOT_PASSWORD=$new_pass/g" "$CONFIG_FILE"
            sed -i "s/MYSQL_ROOT_PASSWORD:.*/MYSQL_ROOT_PASSWORD: $new_pass/g" "$COMPOSE_FILE"
            echo -e "${GREEN}✅ 本地配置文件已完美同步更新。${RESET}"
        fi
    else
        echo -e "${RED}❌ 密码修改失败，请检查用户是否存在。${RESET}"
    fi
    pause; menu
}

# 14. 删除用户功能
function delete_user() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MySQL${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    echo -e "${GREEN}当前系统可删除的用户列表:${RESET}"
    docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysql -uroot -e "SELECT user, host FROM mysql.user;" | grep -Ev "user|root|mysql.sys|mysql.session|mysql.infoschema"
    echo "--------------------------------"
    read -p "请输入要删除的用户名: " del_user
    
    if [ -z "$del_user" ]; then
        echo -e "${RED}输入不能为空！${RESET}"
        pause; menu
    fi
    if [ "$del_user" = "root" ]; then
        echo -e "${RED}❌ 安全限制：拒绝删除超级管理员 root 用户！${RESET}"
        pause; menu
    fi

    read -p "确定要彻底删除用户 '$del_user' 吗？(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" || "$confirm" == "yes" ]]; then
        docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysql -uroot <<EOF
DROP USER '$del_user'@'%';
FLUSH PRIVILEGES;
EOF
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 用户 '$del_user' 已成功卸载并删除权限。${RESET}"
        else
            echo -e "${RED}❌ 删除失败，请确认该用户名是否存在。${RESET}"
        fi
    else
        echo -e "${YELLOW}操作已取消。${RESET}"
    fi
    pause; menu
}

function backup_db() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MySQL${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    local target_dir=""
    echo -e "\n请选择备份文件导出目标："
    echo -e "  [1] 导出默认备份目录 (${BACKUP_DIR})"
    echo -e "  [2] 导出到自定义外部目录的绝对路径"
    read -p "请选择 [1-2, 默认 1]: " path_choice
    path_choice=${path_choice:-1}

    if [ "$path_choice" = "1" ]; then
        target_dir="$BACKUP_DIR"
        mkdir -p "$target_dir"
    else
        read -p "请输入要保存备份的目录绝对路径 (如 /root/ 或 /home/backup/): " custom_dir
        if [ -z "$custom_dir" ]; then echo -e "${RED}目录不能为空！${RESET}"; pause; menu; fi
        target_dir="$custom_dir"
        # 智能创建目录
        mkdir -p "$target_dir"
    fi

    read -p "要备份的库名 (全库输入 --all-databases): " db
    if [ -z "$db" ] || [[ "$db" =~ ^[[:space:]]+$ ]]; then echo -e "${RED}输入不能为空！${RESET}"; pause; menu; fi
    
    local filename="$db"
    [ "$db" = "--all-databases" ] && filename="all"
    BACKUP_FILE="${target_dir%/}/${filename}_$(date +%Y%m%d_%H%M%S).sql"
    
    docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysqldump -uroot --default-character-set=utf8mb4 "$db" > "$BACKUP_FILE"
    if [ $? -eq 0 ] && [ -s "$BACKUP_FILE" ]; then
        echo -e "${YELLOW}✅ 备份完成，文件已安全存放在: $BACKUP_FILE${RESET}"
    else
        echo -e "${RED}❌ 备份失败，请核对数据库名或目录是否有写入权限。${RESET}"
        rm -f "$BACKUP_FILE"
    fi
    pause; menu
}

function restore_db() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MySQL${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    local sql_absolute_path=""

    echo -e "\n请选择备份文件来源路径："
    echo -e "  [1] 默认备份目录恢复 (${BACKUP_DIR})"
    echo -e "  [2] 输入自定义外部 SQL 文件的绝对路径"
    read -p "请选择 [1-2, 默认 1]: " path_choice
    path_choice=${path_choice:-1}

    if [ "$path_choice" = "1" ]; then
        if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR")" ]; then
            echo -e "${RED}❌ 默认备份目录下没有找到任何备份文件${RESET}"; pause; menu
        fi
        echo -e "${GREEN}可用历史备份:${RESET}"
        ls -1 "$BACKUP_DIR"
        read -p "请输入完整备份文件名: " file
        sql_absolute_path="$BACKUP_DIR/$file"
    else
        read -p "请输入 SQL 文件的绝对路径 (如 /root/data.sql): " custom_path
        sql_absolute_path="$custom_path"
    fi

    # 安全检查文件是否存在
    if [ ! -f "$sql_absolute_path" ]; then
        echo -e "${RED}❌ 错误：未找到 SQL 文件，请重新检查路径 [ $sql_absolute_path ] 是否正确！${RESET}"
        pause; menu
    fi

    read -p "目标数据库名 (若是包含全库备份的 SQL 文件，可直接回车): " target_db

    if [ -z "$target_db" ]; then
        docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysql -uroot < "$sql_absolute_path"
    else
        docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysql -uroot -e "CREATE DATABASE IF NOT EXISTS \`$target_db\`;"
        docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" mysql mysql -uroot "$target_db" < "$sql_absolute_path"
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${YELLOW}✅ 数据库恢复指令执行成功！${RESET}"
    else
        echo -e "${RED}❌ 恢复失败，请查看是否有报错输出。${RESET}"
    fi
    pause; menu
}

# ==================== 启动 ====================
menu
