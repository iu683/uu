#!/bin/bash
# ========================================
# MongoDB 容器管理面板 (Docker Compose) 
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
APP_NAME="mongodb"
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

# 获取容器动态状态及自定义数据库个数
get_sys_status() {
    if [ ! -f "$CONFIG_FILE" ]; then
        status="${RED}未安装${RESET}"
        version="${RED}无${RESET}"
        port_show="${RED}无${RESET}"
        db_count="${RED}0${RESET}"
    else
        source "$CONFIG_FILE"
        version="6.0 (Community)"
        port_show="$PORT"
        
        if [ "$(docker ps -q -f name=^mongodb$)" ]; then
            status="${GREEN}运行中${RESET}"
            # 排除系统内置库（admin, config, local），计算用户自定义库数量
            local raw_count=$(docker exec -i mongodb mongosh -u admin -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --quiet --eval "db.getMongo().getDBNames().filter(d => !['admin','config','local'].includes(d)).length" 2>/dev/null)
            db_count="${YELLOW}${raw_count//[[:space:]]/}${RESET} 个"
        elif [ "$(docker ps -a -q -f name=^mongodb$)" ]; then
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
    echo -e "${GREEN}   ◈    MongoDB 管理面板    ◈  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态       :${RESET} $status"
    echo -e "${GREEN}版本       :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口       :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}已创数据库 :${RESET} $db_count"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 MongoDB${RESET}"
    echo -e "${GREEN} 2. 更新 MongoDB${RESET}"
    echo -e "${GREEN} 3. 卸载 MongoDB${RESET}"
    echo -e "${GREEN} 4. 启动 MongoDB${RESET}"
    echo -e "${GREEN} 5. 停止 MongoDB${RESET}"
    echo -e "${GREEN} 6. 重启 MongoDB${RESET}"
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
    
    read -p $'\e[32m请输入数字: \e[0m' num
    case "$num" in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) start_mg ;;
        5) stop_mg ;;
        6) restart_mg ;;
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
        echo -e "${RED}检测到已经安装过 MongoDB。${RESET}"
        pause; menu
    fi
    
    read -p "请输入 MongoDB 端口 [默认 27017]: " input_port
    PORT=${input_port:-27017}
    
    echo -e "\n请选择网络绑定策略 (IP Binding):"
    echo -e "  [1] 允许公网/局域网访问 (绑定 0.0.0.0) [默认]"
    echo -e "  [2] 仅允许本地访问     (绑定 127.0.0.1)"
    read -p "请输入数字 [1-2, 默认 1]: " bind_choice
    bind_choice=${bind_choice:-1}
    
    local compose_port_mapping
    local bind_status_text
    if [ "$bind_choice" = "2" ]; then
        compose_port_mapping="127.0.0.1:${PORT}:27017"
        bind_status_text="仅限本地 (127.0.0.1)"
    else
        compose_port_mapping="${PORT}:27017"
        bind_status_text="开放公网 (0.0.0.0)"
    fi

    read -p "请输入 admin 根密码 [留空自动生成]: " input_pass
    MONGO_ROOT_PASSWORD=${input_pass:-$(gen_pass)}

    mkdir -p "$APP_DIR/data" "$BACKUP_DIR"
    
    cat > "$COMPOSE_FILE" <<EOF
services:
  mongodb-db:
    container_name: mongodb
    image: mongo:6.0
    restart: always
    ports:
      - "${compose_port_mapping}"
    command: mongod --auth
    environment:
      MONGO_INITDB_ROOT_USERNAME: admin
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_ROOT_PASSWORD}
      TZ: Asia/Shanghai
    volumes:
      - ./data:/data/db
EOF

    cat > "$CONFIG_FILE" <<EOF
PORT=$PORT
MONGO_ROOT_PASSWORD=$MONGO_ROOT_PASSWORD
BIND_STRATEGY=$bind_choice
EOF

    cd "$APP_DIR" && $COMPOSE_CMD up -d
    
    local public_ip=$(get_public_ip)
    local local_ip=$(get_local_ip)
    
    echo -e "\n${GREEN}================================================${RESET}"
    echo -e "${GREEN}🎉 MongoDB 安全认证版安装启动成功！运行连接信息：${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN} 网络绑定策略 :${RESET} ${YELLOW}${bind_status_text}${RESET}"
    if [ "$bind_choice" = "2" ]; then
        echo -e "${GREEN} 唯一连接地址 :${RESET} 127.0.0.1:${PORT}"
    else
        echo -e "${GREEN} 公网连接地址 :${RESET} ${public_ip}:${PORT}"
        echo -e "${GREEN} 内网连接地址 :${RESET} 127.0.0.1:${PORT}"
    fi
    echo -e "${GREEN} 管理用户名   :${RESET} admin"
    echo -e "${GREEN} 认证数据库   :${RESET} admin"
    echo -e "${GREEN} 管理员密码   :${RESET} ${YELLOW}${MONGO_ROOT_PASSWORD}${RESET}"
    echo -e "${GREEN} 配置文件路径 :${RESET} ${CONFIG_FILE}"
    echo -e "${GREEN}================================================${RESET}"
    
    pause; menu
}

function update_app() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}未检测到安装目录，请先安装${RESET}"; sleep 1; menu; fi
    cd "$APP_DIR" && $COMPOSE_CMD pull && $COMPOSE_CMD up -d
    echo -e "${GREEN}✅ MongoDB 已更新并重启${RESET}"
    pause; menu
}

function uninstall_app() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}未检测到安装目录${RESET}"; sleep 1; menu; fi
    read -p "确定要彻底卸载吗？数据将清空！(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" || "$confirm" == "yes" ]]; then
        cd "$APP_DIR" && $COMPOSE_CMD down -v
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ MongoDB 已彻底卸载${RESET}"
    else
        echo -e "${YELLOW}已取消卸载${RESET}"
    fi
    pause; menu
}

function start_mg() {
    docker start mongodb &>/dev/null
    echo -e "${GREEN}✅ MongoDB 容器已启动${RESET}"
    pause; menu
}

function stop_mg() {
    docker stop mongodb &>/dev/null
    echo -e "${GREEN}✅ MongoDB 容器已停止${RESET}"
    pause; menu
}

function restart_mg() {
    docker restart mongodb &>/dev/null
    echo -e "${GREEN}✅ MongoDB 容器已重启${RESET}"
    pause; menu
}

function view_logs() {
    echo -e "${YELLOW}提示: 朝下滚动，按下 Ctrl + C 即可退出日志回到主菜单。${RESET}"
    sleep 1
    docker logs --tail 100 -f mongodb
    menu
}

function show_info() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MongoDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    SERVER_IP=$(get_public_ip)
    local local_ip=$(get_local_ip)
    BIND_STRATEGY=${BIND_STRATEGY:-1}
    
    echo -e "\n${GREEN}====== MongoDB 运行信息 ======${RESET}"
    if [ "$BIND_STRATEGY" = "2" ]; then
        echo -e "${GREEN}绑定状态 :${RESET} ${YELLOW}仅限本地监听 (127.0.0.1)${RESET}"
        echo -e "${GREEN}连接地址 :${RESET} 127.0.0.1:${PORT}"
    else
        echo -e "${GREEN}绑定状态 :${RESET} ${GREEN}开放公网/局域网 (0.0.0.0)${RESET}"
        echo -e "${GREEN}公网地址 :${RESET} ${SERVER_IP}:${PORT}"
        echo -e "${GREEN}内网地址 :${RESET} 127.0.0.1:${PORT}"
    fi
    echo -e "${GREEN}超级管理员:${RESET} admin"
    echo -e "${GREEN}超级密码  :${RESET} ${YELLOW}${MONGO_ROOT_PASSWORD}${RESET}"
    echo -e "${GREEN}安装路径  :${RESET} $APP_DIR"
    echo -e "${GREEN}标准连接串:${RESET} ${CYAN}mongodb://admin:${MONGO_ROOT_PASSWORD}@${SERVER_IP}:${PORT}/?authSource=admin${RESET}"
    echo -e "${GREEN}================================${RESET}"
    
    echo -e "${GREEN}当前用户自定义数据库及集合统计:${RESET}"
    docker exec -i mongodb mongosh -u admin -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --quiet --eval "
    db.getMongo().getDBNames().forEach(function(d) {
        if(!['admin','config','local'].includes(d)){
            var dbInstance = db.getSiblingDB(d);
            print(' 📂 数据库: ' + d + ' (含有 ' + dbInstance.getCollectionNames().length + ' 个集合)');
        }
    });"
    
    echo -e "\n${GREEN}当前数据库系统用户角色列表:${RESET}"
    docker exec -i mongodb mongosh -u admin -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --quiet --eval "
    db.getSiblingDB('admin').getUsers().forEach(function(u) {
        print(' 👤 用户: ' + u.user + ' | 认证库: ' + u.db + ' | 角色: ' + JSON.stringify(u.roles.map(r => r.role + '@' + r.db)));
    });"
    echo -e "${GREEN}================================${RESET}"
    pause; menu
}

function create_database() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MongoDB${RESET}"; sleep 1; menu; fi
    echo -e "${YELLOW}提示：MongoDB 的机制是不需要显式创建空库。当你在新库里插入第一条数据（或创建用户）时，数据库会被自动创建。${RESET}"
    read -p "请输入你想创建的数据库名: " new_db
    if [ -z "$new_db" ]; then echo -e "${RED}输入不能为空！${RESET}"; pause; menu; fi
    
    # 建立一个临时集合以固化库
    docker exec -i mongodb mongosh -u admin -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --quiet --eval "db.getSiblingDB('$new_db').createCollection('init_holder')" &>/dev/null
    echo -e "${GREEN}✅ 数据库 $new_db 初始化占位成功。${RESET}"
    pause; menu
}

function delete_database() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MongoDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    read -p "请输入要彻底删除的数据库名: " del_db
    if [ -z "$del_db" ]; then echo -e "${RED}输入不能为空！${RESET}"; pause; menu; fi
    if [[ "$del_db" =~ ^(admin|config|local)$ ]]; then echo -e "${RED}❌ 安全限制：拒绝删除系统保留库！${RESET}"; pause; menu; fi
    
    read -p "警告：确定要彻底删除 MongoDB 数据库 [$del_db] 吗？集合及数据将瞬间蒸发！(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" || "$confirm" == "yes" ]]; then
        docker exec -i mongodb mongosh -u admin -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --quiet --eval "db.getSiblingDB('$del_db').dropDatabase()" &>/dev/null
        echo -e "${GREEN}✅ 数据库 $del_db 移除动作完成。${RESET}"
    else
        echo -e "${YELLOW}操作已取消。${RESET}"
    fi
    pause; menu
}

function create_user() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MongoDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    read -p "请输入新用户名: " new_user
    if [ -z "$new_user" ]; then echo -e "${RED}用户名不能为空！${RESET}"; pause; menu; fi
    read -p "请输入新用户密码 [留空随机]: " new_pass
    new_pass=${new_pass:-$(gen_pass)}
    read -p "该用户需要读写哪一个数据库: " grant_db
    if [ -z "$grant_db" ]; then echo -e "${RED}数据库名不能为空！${RESET}"; pause; menu; fi

    # 在目标库创建拥有 readWrite 权限的业务账号
    docker exec -i mongodb mongosh -u admin -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --quiet --eval "
    db.getSiblingDB('$grant_db').createUser({
        user: '$new_user',
        pwd: '$new_pass',
        roles: [{ role: 'readWrite', db: '$grant_db' }]
    })" &>/dev/null

    echo -e "${YELLOW}✅ 业务用户 $new_user 创建成功。密码: $new_pass (拥有 $grant_db 的独占读写权限)${RESET}"
    pause; menu
}

function delete_user() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MongoDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    read -p "请输入要删除的用户名: " del_user
    read -p "该用户所属的认证数据库名: " user_db
    if [[ -z "$del_user" || -z "$user_db" ]]; then echo -e "${RED}输入不能为空！${RESET}"; pause; menu; fi
    if [ "$del_user" = "admin" ]; then echo -e "${RED}❌ 安全限制：拒绝删除根超级管理员 admin！${RESET}"; pause; menu; fi

    docker exec -i mongodb mongosh -u admin -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --quiet --eval "db.getSiblingDB('$user_db').dropUser('$del_user')" &>/dev/null
    echo -e "${GREEN}✅ 尝试卸载用户 '$del_user' 结束。${RESET}"
    pause; menu
}

# 13. 一键联动的最高所有权创建
function create_db_user() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MongoDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    read -p "新数据库名: " new_db
    read -p "新用户名: " new_user
    if [[ -z "$new_db" || -z "$new_user" ]]; then echo -e "${RED}库名和用户名不能为空！${RESET}"; pause; menu; fi
    read -p "密码 [留空随机]: " new_pass
    new_pass=${new_pass:-$(gen_pass)}

    # 同时初始化数据库和高权限业务账号
    docker exec -i mongodb mongosh -u admin -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --quiet --eval "
    db.getSiblingDB('$new_db').createCollection('init_holder');
    db.getSiblingDB('$new_db').createUser({
        user: '$new_user',
        pwd: '$new_pass',
        roles: [{ role: 'dbOwner', db: '$new_db' }]
    });" &>/dev/null

    echo -e "${YELLOW}✅ 联动深度创建成功！${RESET}"
    echo -e "${GREEN} 🚀 用户名 :${RESET} $new_user"
    echo -e "${GREEN} 🚀 密  码 :${RESET} ${YELLOW}$new_pass${RESET}"
    echo -e "${GREEN} 🚀 数据库 :${RESET} $new_db"
    pause; menu
}

function change_password() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MongoDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    read -p "请输入要修改密码的用户名 [默认 admin]: " target_user
    target_user=${target_user:-admin}
    read -p "该用户所在的认证数据库 [默认 admin]: " user_db
    user_db=${user_db:-admin}
    read -p "请输入新密码 [留空随机生成]: " new_pass
    new_pass=${new_pass:-$(gen_pass)}

    docker exec -i mongodb mongosh -u admin -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --quiet --eval "db.getSiblingDB('$user_db').updateUser('$target_user', {pwd: '$new_pass'})" &>/dev/null

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 用户 '$target_user' 密码修改成功！新密码: ${YELLOW}$new_pass${RESET}"
        if [ "$target_user" = "admin" ] && [ "$user_db" = "admin" ]; then
            sed -i "s/^MONGO_ROOT_PASSWORD=.*/MONGO_ROOT_PASSWORD=$new_pass/g" "$CONFIG_FILE"
            sed -i "s/MONGO_INITDB_ROOT_PASSWORD:.*/MONGO_INITDB_ROOT_PASSWORD: $new_pass/g" "$COMPOSE_FILE"
            echo -e "${GREEN}✅ 本地安全配置文件已全量同步更新。${RESET}"
        fi
    else
        echo -e "${RED}❌ 密码修改失败，请确保用户与认证库匹配。${RESET}"
    fi
    pause; menu
}

function backup_db() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MongoDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    local target_dir=""
    echo -e "\n请选择备份文件导出目标："
    echo -e "  [1] 导出到脚本默认备份目录 (${BACKUP_DIR})"
    echo -e "  [2] 导出到自定义外部目录的绝对路径"
    read -p "请选择 [1-2, 默认 1]: " path_choice
    path_choice=${path_choice:-1}

    if [ "$path_choice" = "1" ]; then
        target_dir="$BACKUP_DIR"
        mkdir -p "$target_dir"
    else
        read -p "请输入要保存备份的目录绝对路径 (如 /root/): " custom_dir
        if [ -z "$custom_dir" ]; then echo -e "${RED}目录不能为空！${RESET}"; pause; menu; fi
        target_dir="$custom_dir"
        mkdir -p "$target_dir"
    fi

    read -p "要备份的单个库名 (全库物理备份请输入 all): " db
    if [ -z "$db" ]; then echo -e "${RED}输入不能为空！${RESET}"; pause; menu; fi
    
    # 采用更安全的官方高压缩比格式
    BACKUP_FILE="${target_dir%/}/${db}_$(date +%Y%m%d_%H%M%S).archive"
    
    if [ "$db" = "all" ]; then
        docker exec -i mongodb mongodump -u admin -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --archive > "$BACKUP_FILE"
    else
        docker exec -i mongodb mongodump -u admin -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin -d "$db" --archive > "$BACKUP_FILE"
    fi

    if [ $? -eq 0 ] && [ -s "$BACKUP_FILE" ]; then
        echo -e "${YELLOW}✅ MongoDB 二进制存档备份完成，文件存放在: $BACKUP_FILE${RESET}"
    else
        echo -e "${RED}❌ 备份失败，请核对权限或磁盘容量。${RESET}"
        rm -f "$BACKUP_FILE"
    fi
    pause; menu
}

function restore_db() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先安装 MongoDB${RESET}"; sleep 1; menu; fi
    source "$CONFIG_FILE"
    
    local archive_absolute_path=""

    echo -e "\n请选择备份文件来源路径："
    echo -e "  [1] 从脚本默认备份目录恢复 (${BACKUP_DIR})"
    echo -e "  [2] 输入自定义外部 .archive 文件的绝对路径"
    read -p "请选择 [1-2, 默认 1]: " path_choice
    path_choice=${path_choice:-1}

    if [ "$path_choice" = "1" ]; then
        if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR")" ]; then
            echo -e "${RED}❌ 默认备份目录下没有找到任何备份存档${RESET}"; pause; menu
        fi
        echo -e "${GREEN}可用历史备份:${RESET}"
        ls -1 "$BACKUP_DIR"
        read -p "请输入完整备份文件名: " file
        archive_absolute_path="$BACKUP_DIR/$file"
    else
        read -p "请输入 .archive 文件的绝对路径 (如 /root/data.archive): " custom_path
        archive_absolute_path="$custom_path"
    fi

    if [ ! -f "$archive_absolute_path" ]; then
        echo -e "${RED}❌ 错误：未找到指定的备份文件！[ $archive_absolute_path ]${RESET}"
        pause; menu
    fi

    # --nsInclude 可以自动映射恢复，如果是全库直接回车
    read -p "目标数据库名 (如果是通过 all 备份的全库文件，直接敲回车): " target_db

    if [ -z "$target_db" ]; then
        docker exec -i mongodb mongorestore -u admin -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --archive < "$archive_absolute_path"
    else
        # 智能重定向单库
        docker exec -i mongodb mongorestore -u admin -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin --archive --nsFrom '.*' --nsTo "$target_db.*" < "$archive_absolute_path"
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${YELLOW}✅ MongoDB 数据存档恢复成功！${RESET}"
    else
        echo -e "${RED}❌ 恢复失败，请检查报错日志。${RESET}"
    fi
    pause; menu
}

# ==================== 启动 ====================
menu
