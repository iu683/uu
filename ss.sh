#!/bin/bash
# ========================================
# MariaDB 容器管理面板 (Docker Compose) 
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
CYAN="\033[36m"
APP_NAME="mariadb"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"
DEFAULT_BACKUP_DIR="$APP_DIR/backup"

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

# 获取容器动态状态及自定义数据库个数
get_sys_status() {
    if [ ! -f "$CONFIG_FILE" ]; then
        status="${RED}未安装${RESET}"
        version="${RED}无${RESET}"
        port_show="${RED}无${RESET}"
        db_count="${RED}0${RESET}"
    else
        source "$CONFIG_FILE"
        version="11.4 (LTS)"
        port_show="$PORT"
        
        if [ "$(docker ps -q -f name=^mariadb$)" ]; then
            status="${GREEN}运行中${RESET}"
            local raw_count=$(docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys');" -s --skip-column-names 2>/dev/null)
            if [ -z "$raw_count" ]; then
                db_count="${YELLOW}未知 (请先启动容器)${RESET}"
            else
                db_count="${YELLOW}${raw_count//[[:space:]]/}${RESET} ${GREEN}个${RESET}"
            fi
        elif [ "$(docker ps -a -q -f name=^mariadb$)" ]; then
            status="${YELLOW}已停止${RESET}"
            db_count="${YELLOW}未知 (请先启动容器)${RESET}"
        else
            status="${RED}未启动 (容器不存在)${RESET}"
            db_count="${RED}0${RESET}"
        fi
    fi
}

# 内部辅助函数：美观地打印当前非系统数据库列表
_list_custom_dbs() {
    echo -e "${CYAN}--- 当前服务器上已创自定义数据库列表 ---${RESET}"
    docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "
    SELECT SCHEMA_NAME as '数据库名称' FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys');"
    echo -e "${CYAN}---------------------------------------${RESET}"
}

# 内部辅助函数：美观地打印当前普通业务用户列表
_list_custom_users() {
    echo -e "${CYAN}--- 当前服务器上已创业务用户列表 ---${RESET}"
    docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "
    SELECT User as '用户名', Host as '允许连入主机' FROM mysql.user WHERE User NOT IN ('root', 'healthcheck', 'mariadb.sys', '');"
    echo -e "${CYAN}------------------------------------${RESET}"
}

# ==================== 菜单 ====================
function menu() {
    clear
    get_sys_status
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈    MariaDB 管理面板    ◈  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态       :${RESET} $status"
    echo -e "${GREEN}版本       :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口       :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}已创数据库 :${RESET} $db_count"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 MariaDB${RESET}"
    echo -e "${GREEN} 2. 更新 MariaDB${RESET}"
    echo -e "${GREEN} 3. 卸载 MariaDB${RESET}"
    echo -e "${GREEN} 4. 启动 MariaDB${RESET}"
    echo -e "${GREEN} 5. 停止 MariaDB${RESET}"
    echo -e "${GREEN} 6. 重启 MariaDB${RESET}"
    echo -e "${GREEN} 7. 查看 日志${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${GREEN} 8. 数据库信息${RESET}"
    echo -e "${GREEN} 9. 创建数据库${RESET}"
    echo -e "${GREEN}10. 删除数据库${RESET}"
    echo -e "${GREEN}11. 创建用户${RESET}"
    echo -e "${GREEN}12. 删除用户${RESET}"
    echo -e "${GREEN}13.${RESET} ${YELLOW}创建数据库+用户${RESET}"
    echo -e "${GREEN}14. 修改用户密码${RESET}"
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
        4) start_md ;;
        5) stop_md ;;
        6) restart_md ;;
        7) view_logs ;;
        8) show_info ;;
        9) create_database ;;
        10) delete_database ;;
        11) create_user ;;
        12) delete_user ;;
        13) create_db_user ;;
        14) change_password ;;
        15) backup_db ;;
        16) restore_db ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

# ==================== 功能实现 ====================

function install_app() {
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${RED}检测到已经安装过 MariaDB。${RESET}"
        pause; menu
    fi
    
    read -p "请输入 MariaDB 端口 [默认 3306]: " input_port
    PORT=${input_port:-3306}
    
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

    read -p "请输入 root 运行密码 [留空自动生成]: " input_pass
    MARIADB_ROOT_PASSWORD=${input_pass:-$(gen_pass)}

    mkdir -p "$APP_DIR/data" "$DEFAULT_BACKUP_DIR"
    
    cat > "$COMPOSE_FILE" <<EOF
services:
  mariadb-db:
    container_name: mariadb
    image: mariadb:11.4
    restart: always
    ports:
      - "${compose_port_mapping}"
    command: --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    environment:
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      TZ: Asia/Shanghai
    volumes:
      - ./data:/var/lib/mysql
EOF

    cat > "$CONFIG_FILE" <<EOF
PORT=$PORT
MARIADB_ROOT_PASSWORD=$MARIADB_ROOT_PASSWORD
BIND_STRATEGY=$bind_choice
EOF

    cd "$APP_DIR" && $COMPOSE_CMD up -d
    
    local public_ip=$(get_public_ip)
    local local_ip=$(get_local_ip)
    
    echo -e "\n${GREEN}================================================${RESET}"
    echo -e "${GREEN}🎉 MariaDB 容器版安装启动成功！运行连接信息：${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN} 网络绑定策略 :${RESET} ${YELLOW}${bind_status_text}${RESET}"
    if [ "$bind_choice" = "2" ]; then
        echo -e "${GREEN} 唯一连接地址 :${RESET} 127.0.0.1:${PORT}"
    else
        echo -e "${GREEN} 公网连接地址 :${RESET} ${public_ip}:${PORT}"
        echo -e "${GREEN} 内网连接地址 :${RESET} 127.0.0.1:${PORT}"
    fi
    echo -e "${GREEN} 管理用户名   :${RESET} root"
    echo -e "${GREEN} 超级管理密码 :${RESET} ${YELLOW}${MARIADB_ROOT_PASSWORD}${RESET}"
    echo -e "${GREEN} 标准连接串   :${RESET} ${CYAN}mysql://root:${MARIADB_ROOT_PASSWORD}@${public_ip}:${PORT}/;${RESET}"
    echo -e "${GREEN} 配置文件路径 :${RESET} ${CONFIG_FILE}"
    echo -e "${GREEN}================================================${RESET}"
    
    pause; menu
}

function update_app() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}未检测到安装目录，请先安装${RESET}"; sleep 1; menu; fi
    cd "$APP_DIR" && $COMPOSE_CMD pull && $COMPOSE_CMD up -d
    echo -e "${GREEN}✅ MariaDB 已更新并重启${RESET}"
    pause; menu
}

function uninstall_app() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}未检测到安装目录${RESET}"; sleep 1; menu; fi
    read -p "确定要彻底卸载吗？所有数据表将清空！(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" || "$confirm" == "yes" ]]; then
        cd "$APP_DIR" && $COMPOSE_CMD down -v
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ MariaDB 已彻底卸载${RESET}"
    else
        echo -e "${YELLOW}已取消卸载${RESET}"
    fi
    pause; menu
}

function start_md() {
    docker start mariadb &>/dev/null
    echo -e "${GREEN}✅ MariaDB 容器已启动${RESET}"
    pause; menu
}

function stop_md() {
    docker stop mariadb &>/dev/null
    echo -e "${GREEN}✅ MariaDB 容器已停止${RESET}"
    pause; menu
}

function restart_md() {
    docker restart mariadb &>/dev/null
    echo -e "${GREEN}✅ MariaDB 容器已重启${RESET}"
    pause; menu
}

function view_logs() {
    echo -e "${YELLOW}提示: 朝下滚动，按下 Ctrl + C 即可退出日志回到主菜单。${RESET}"
    sleep 1
    docker logs --tail 100 -f mariadb
    menu
}

function show_info() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MariaDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    SERVER_IP=$(get_public_ip)
    local local_ip=$(get_local_ip)
    BIND_STRATEGY=${BIND_STRATEGY:-1}
    
    echo -e "\n${GREEN}====== MariaDB 运行信息 ======${RESET}"
    if [ "$BIND_STRATEGY" = "2" ]; then
        echo -e "${GREEN}绑定状态 :${RESET} ${YELLOW}仅限本地监听 (127.0.0.1)${RESET}"
        echo -e "${GREEN}连接地址 :${RESET} 127.0.0.1:${PORT}"
    else
        echo -e "${GREEN}绑定状态 :${RESET} ${GREEN}开放公网/局域网 (0.0.0.0)${RESET}"
        echo -e "${GREEN}公网地址 :${RESET} ${SERVER_IP}:${PORT}"
        echo -e "${GREEN}内网地址 :${RESET} 127.0.0.1:${PORT}"
    fi
    echo -e "${GREEN}超级管理员:${RESET} root"
    echo -e "${GREEN}超级密码  :${RESET} ${YELLOW}${MARIADB_ROOT_PASSWORD}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    
    _list_custom_dbs
    
    echo -e "\n${GREEN}当前系统全量用户及连入限制清单:${RESET}"
    docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "
    SELECT User as '用户', Host as '允许连入主机' FROM mysql.user;"
    echo -e "${GREEN}================================${RESET}"
    pause; menu
}

function create_database() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MariaDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    read -p "请输入你想创建的数据库名: " new_db
    if [ -z "$new_db" ]; then echo -e "${RED}输入不能为空！${RESET}"; pause; menu; fi
    
    docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "CREATE DATABASE \`$new_db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" &>/dev/null
    echo -e "${GREEN}✅ 数据库 $new_db 创建成功。${RESET}"
    pause; menu
}

# 💡 升级 10：先列出已创数据库，再执行交互删除
function delete_database() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MariaDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    echo -e "\n${YELLOW}[🔥 准备执行删除库操作]${RESET}"
    _list_custom_dbs
    
    read -p "请输入要彻底删除的数据库名: " del_db
    if [ -z "$del_db" ]; then echo -e "${RED}输入不能为空！${RESET}"; pause; menu; fi
    if [[ "$del_db" =~ ^(information_schema|mysql|performance_schema|sys)$ ]]; then echo -e "${RED}❌ 安全限制：拒绝删除系统保留核心库！${RESET}"; pause; menu; fi
    
    read -p "危险警告：确定要彻底删除自定义库 [$del_db] 吗？(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "DROP DATABASE \`$del_db\`;" &>/dev/null
        echo -e "${GREEN}✅ 数据库 $del_db 已成功从内存与磁盘彻底擦除。${RESET}"
    else
        echo -e "${YELLOW}操作已取消。${RESET}"
    fi
    pause; menu
}

function create_user() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MariaDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    read -p "请输入新用户名: " new_user
    if [ -z "$new_user" ]; then echo -e "${RED}用户名不能为空！${RESET}"; pause; menu; fi
    read -p "请输入新用户密码 [留空随机]: " new_pass
    new_pass=${new_pass:-$(gen_pass)}
    read -p "该用户需要拥有哪一个数据库的权限: " grant_db
    if [ -z "$grant_db" ]; then echo -e "${RED}数据库名不能为空！${RESET}"; pause; menu; fi

    docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "
    CREATE USER '$new_user'@'%' IDENTIFIED BY '$new_pass';
    GRANT ALL PRIVILEGES ON \`$grant_db\`.* TO '$new_user'@'%';
    FLUSH PRIVILEGES;" &>/dev/null

    echo -e "${YELLOW}✅ 业务用户 $new_user 创建成功。密码: $new_pass (已拥有 $grant_db 的全部操作权限)${RESET}"
    pause; menu
}

# 💡 升级 12：先列出已创业务用户，再执行交互删除
function delete_user() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MariaDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    echo -e "\n${YELLOW}[🔥 准备执行删除用户操作]${RESET}"
    _list_custom_users
    
    read -p "请输入要删除的用户名: " del_user
    if [ -z "$del_user" ]; then echo -e "${RED}输入不能为空！${RESET}"; pause; menu; fi
    if [[ "$del_user" = "root" || "$del_user" = "healthcheck" || "$del_user" = "mariadb.sys" ]]; then 
        echo -e "${RED}❌ 安全限制：拒绝删除系统级保留核心账户！${RESET}"; pause; menu; 
    fi

    read -p "确定要注销业务用户 '$del_user' 吗？(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "DROP USER '$del_user'@'%'; FLUSH PRIVILEGES;" &>/dev/null
        echo -e "${GREEN}✅ 业务用户 '$del_user' 已成功注销。${RESET}"
    else
        echo -e "${YELLOW}操作已取消。${RESET}"
    fi
    pause; menu
}

function create_db_user() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MariaDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    read -p "新数据库名: " new_db
    read -p "新用户名: " new_user
    if [[ -z "$new_db" || -z "$new_user" ]]; then echo -e "${RED}库名和用户名不能为空！${RESET}"; pause; menu; fi
    read -p "密码 [留空随机]: " new_pass
    new_pass=${new_pass:-$(gen_pass)}

    docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "
    CREATE DATABASE \`$new_db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER '$new_user'@'%' IDENTIFIED BY '$new_pass';
    GRANT ALL PRIVILEGES ON \`$new_db\`.* TO '$new_user'@'%';
    FLUSH PRIVILEGES;" &>/dev/null

    echo -e "${YELLOW}✅ 联动深度创建成功！${RESET}"
    echo -e "${GREEN} 🚀 用户名 :${RESET} $new_user"
    echo -e "${GREEN} 🚀 密  码 :${RESET} ${YELLOW}$new_pass${RESET}"
    echo -e "${GREEN} 🚀 数据库 :${RESET} $new_db"
    pause; menu
}

function change_password() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MariaDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    read -p "请输入要修改密码的用户名 [默认 root]: " target_user
    target_user=${target_user:-root}
    read -p "请输入新密码 [留空随机]: " new_pass
    new_pass=${new_pass:-$(gen_pass)}

    if [ "$target_user" = "root" ]; then
        docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$new_pass'; ALTER USER 'root'@'%' IDENTIFIED BY '$new_pass'; FLUSH PRIVILEGES;" &>/dev/null
        sed -i "s/^MARIADB_ROOT_PASSWORD=.*/MARIADB_ROOT_PASSWORD=$new_pass/g" "$CONFIG_FILE"
        sed -i "s/MARIADB_ROOT_PASSWORD:.*/MARIADB_ROOT_PASSWORD: $new_pass/g" "$COMPOSE_FILE"
        echo -e "${GREEN}✅ 本地安全配置文件已全量同步更新。${RESET}"
    else
        docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "ALTER USER '$target_user'@'%' IDENTIFIED BY '$new_pass'; FLUSH PRIVILEGES;" &>/dev/null
    fi

    echo -e "${GREEN}✅ 用户 '$target_user' 密码更新成功！新密码: ${YELLOW}$new_pass${RESET}"
    pause; menu
}

# 💡 升级 15：备份数据库（支持任意自定义路径映射）
function backup_db() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MariaDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    read -p "请输入你想单独备份的库名 (全库备份请输入 all): " db
    if [ -z "$db" ]; then echo -e "${RED}输入不能为空！${RESET}"; pause; menu; fi
    
    # 允许自定目录交互
    read -p "请输入备份文件存放目录 [默认 $DEFAULT_BACKUP_DIR]: " user_dir
    local tgt_dir=${user_dir:-$DEFAULT_BACKUP_DIR}
    
    # 自动建立目录（支持多级）
    mkdir -p "$tgt_dir"
    
    local BACKUP_FILE="$tgt_dir/${db}_$(date +%Y%m%d_%H%M%S).sql"
    
    if [ "$db" = "all" ]; then
        docker exec -i mariadb mariadb-dump -u root -p"$MARIADB_ROOT_PASSWORD" --all-databases > "$BACKUP_FILE"
    else
        docker exec -i mariadb mariadb-dump -u root -p"$MARIADB_ROOT_PASSWORD" --databases "$db" > "$BACKUP_FILE"
    fi

    if [ $? -eq 0 ] && [ -s "$BACKUP_FILE" ]; then
        echo -e "${YELLOW}✅ SQL 结构及数据备份成功，存放于: $BACKUP_FILE${RESET}"
    else
        echo -e "${RED}❌ 备份失败，请检查目标目录权限。${RESET}"
        rm -f "$BACKUP_FILE"
    fi
    pause; menu
}

# 💡 升级 16：恢复数据库（支持从任意自定义路径加载 SQL）
function restore_db() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MariaDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    read -p "请输入备份文件所在的扫描目录 [默认 $DEFAULT_BACKUP_DIR]: " user_dir
    local tgt_dir=${user_dir:-$DEFAULT_BACKUP_DIR}
    
    if [ ! -d "$tgt_dir" ] || [ -z "$(ls -A "$tgt_dir" 2>/dev/null)" ]; then
        echo -e "${RED}❌ 错误：在指定目录 [$tgt_dir] 下没有找到任何 SQL 备份文件！${RESET}"; pause; menu
    fi
    
    echo -e "${GREEN}--- 指定目录下的可用历史备份列表 ---${RESET}"
    ls -1 "$tgt_dir" | grep '\.sql$'
    echo -e "${GREEN}------------------------------------${RESET}"
    
    read -p "请输入完整备份文件名: " file
    local backup_path="$tgt_dir/$file"
    
    if [ ! -f "$backup_path" ]; then
        echo -e "${RED}❌ 错误：未找到指定的备份文件！${RESET}"; pause; menu
    fi

    read -p "将此备份覆盖恢复入哪一个数据库 (如果是通过 all 备份的全库文件，直接敲回车): " target_db

    if [ -z "$target_db" ]; then
        docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" < "$backup_path"
    else
        docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS \`$target_db\`;"
        docker exec -i mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "$target_db" < "$backup_path"
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${YELLOW}✅ 数据恢复流在目标实例中覆盖执行成功！${RESET}"
    else
        echo -e "${RED}❌ 恢复失败，请检查 SQL 内容合法性。${RESET}"
    fi
    pause; menu
}

# ==================== 启动 ====================
menu
