#!/bin/bash
# =================================================================
# Paperphone-plus - 跨环境（MySQL/Redis 双自适应 + Redis 分区）运维面板
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
MAGENTA="\033[35m"
RESET="\033[0m"

BASE_DIR="/opt/paperphone"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/server/.env"
DEFAULT_BACKUP_DIR="$BASE_DIR/backups"

check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker！${RESET}"; exit 1
    fi
}

get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        # 强制获取 IPv4
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        # 强制获取 IPv6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        # auto 模式：双栈环境优先获取 IPv4 (更适合大众网络)，纯 v6 环境自动fallback到 v6
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        # 如果获取 v4 失败，说明可能是纯 v6 机器，尝试获取 v6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    # 兜底处理：所有接口都失败时，直接输出 127.0.0.1，不报错
    echo "127.0.0.1" && return 0
}

get_status_info() {
    local active_id=$(docker ps -q --filter "name=paperphone-plus-client" --filter "status=running" | head -n 1)
    if [ -n "$active_id" ]; then
        status="${GREEN}运行中${RESET}"
        port_display="80"
    else
        local dead_id=$(docker ps -aq --filter "name=paperphone-plus-client" | head -n 1)
        if [ -n "$dead_id" ]; then status="${RED}已停止${RESET}"; else status="${RED}未部署${RESET}"; fi
        port_display="N/A"
    fi
}



install_utils() {
    check_dependencies
    mkdir -p "$BASE_DIR/server"
    
    echo -e "${CYAN}====== 1. 数据库与缓存部署模式选择 ======${RESET}"
    echo -e "${GREEN}1) 内置常规模式${RESET} (本地跑 MySQL 和 Redis 容器)"
    echo -e "${GREEN}2) 远程数据模式${RESET} (连接外部已有的 MySQL/Redis，跳过本地库)"
    echo -ne "${YELLOW}请选择模式 [默认 1]: ${RESET}"; read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    local db_host="mysql" local redis_host="redis" local db_user="paperphoneplus" local db_pass="changeme"
    local db_name="paperphoneplus" local db_port="3306" local redis_pass="" local redis_port="6379" local redis_db="0"

    if [ "$db_mode" = "2" ]; then
        echo -e "\n${CYAN}➜ 请输入远程 MySQL 配置:${RESET}"
        echo -ne "${YELLOW}远程 MySQL 地址 (Host): ${RESET}"; read -r db_host
        echo -ne "${YELLOW}远程 MySQL 端口 (Port) [默认 3306]: ${RESET}"; read -r tmp_port; [[ -n "$tmp_port" ]] && db_port="$tmp_port"
        echo -ne "${YELLOW}远程 MySQL 用户 (User) [默认 paperphoneplus]: ${RESET}"; read -r tmp_user; [[ -n "$tmp_user" ]] && db_user="$tmp_user"
        echo -ne "${YELLOW}远程 MySQL 密码 (Password): ${RESET}"; read -r db_pass
        echo -ne "${YELLOW}远程 MySQL 数据库名 (DB Name) [默认 paperphoneplus]: ${RESET}"; read -r tmp_db; [[ -n "$tmp_db" ]] && db_name="$tmp_db"

        echo -e "\n${CYAN}➜ 请输入远程 Redis 配置:${RESET}"
        echo -ne "${YELLOW}远程 Redis 地址 (Host): ${RESET}"; read -r redis_host
        echo -ne "${YELLOW}远程 Redis 端口 (Port) [默认 6379]: ${RESET}"; read -r tmp_rport; [[ -n "$tmp_rport" ]] && redis_port="$tmp_rport"
        echo -ne "${YELLOW}远程 Redis 分区/库编号 (DB Index) [默认 0]: ${RESET}"; read -r tmp_rdb; [[ -n "$tmp_rdb" ]] && redis_db="$tmp_rdb"
        echo -ne "${YELLOW}远程 Redis 密码 (无密码直接回车): ${RESET}"; read -r redis_pass
    fi

    echo -e "\n${CYAN}====== 2. 安全与基础密钥配置 ======${RESET}"
    local rand_jwt=$(date +%s | sha256sum | base64 | head -c 32)
    echo -ne "${YELLOW}请输入前端访问端口 [默认 80]: ${RESET}"; read -r custom_port; [[ -z "$custom_port" ]] && custom_port="80"
    echo -ne "${YELLOW}后台管理密码 [默认 admin123]: ${RESET}"; read -r admin_pass; [[ -z "$admin_pass" ]] && admin_pass="admin123"

    # 写入 .env 文件
    cat <<EOF > "$ENV_FILE"
PORT=3000
JWT_SECRET="${rand_jwt}"
JWT_EXPIRES_IN=7d
DB_HOST=${db_host}
DB_PORT=${db_port}
DB_USER=${db_user}
DB_PASS=${db_pass}
DB_NAME=${db_name}
REDIS_HOST=${redis_host}
REDIS_PORT=${redis_port}
REDIS_PASS=${redis_pass}
REDIS_DB=${redis_db}
ADMIN_PATH=/admin
ADMIN_PASSWORD=${admin_pass}
EOF

    # 根据部署模式，智能生成 server 的内部依赖块，彻底废除不稳定的 sed 逻辑
    local server_depends=""
    if [ "$db_mode" = "1" ]; then
        server_depends=$(cat <<EOF
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
)
    fi

    # 构造基础双容器架构
    cat <<EOF > "$COMPOSE_FILE"
services:
  client:
    container_name: paperphone-plus-client
    image: facilisvelox/paperphone-plus-client:latest
    ports:
      - "${custom_port}:80"
    depends_on:
      server:
        condition: service_healthy
    restart: unless-stopped

  server:
    container_name: paperphone-plus-server
    image: facilisvelox/paperphone-plus-server:latest
    ports:
      - "3000:3000"
    env_file:
      - ./server/.env
    environment:
      REDIS_DB: \${REDIS_DB:-0}
${server_depends}
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:3000/health"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s
    restart: unless-stopped
EOF

    # 只有常规模式（db_mode 为 1）下，才会继续在文件尾部追加本地数据库卷
    if [ "$db_mode" = "1" ]; then
        cat <<EOF >> "$COMPOSE_FILE"

  mysql:
    container_name: paperphone-mysql
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: ${db_pass}
      MYSQL_DATABASE: ${db_name}
      MYSQL_USER: ${db_user}
      MYSQL_PASSWORD: ${db_pass}
    volumes:
      - mysql_data:/var/lib/mysql
    ports:
      - "127.0.0.1:3306:3306"
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    restart: unless-stopped

  redis:
    container_name: paperphone-redis
    image: redis:7-alpine
    command: >
      sh -c "if [ -n '${redis_pass}' ]; then
        redis-server --requirepass '${redis_pass}'
      else
        redis-server
      fi"
    volumes:
      - redis_data:/data
    ports:
      - "127.0.0.1:6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

volumes:
  mysql_data:
  redis_data:
EOF
    fi

    echo -e "${YELLOW}正在通过 Docker Compose 部署并拉起集群...${RESET}"
    cd "$BASE_DIR" && docker compose up -d
    echo -e "${GREEN}Paperphone-plus 部署成功！${RESET}"

    # 智能防护获取公网 IP。若环境没有 get_public_ip 函数，自适应切回本地公网卡网段
    local SERVER_IP
    if command -v get_public_ip &> /dev/null; then
        SERVER_IP=$(get_public_ip)
    else
        SERVER_IP=$(hostname -I | awk '{print $1}')
    fi

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}         Paperphone-plus 部署成功！               ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://${SERVER_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}👑 管理后台: http://${SERVER_IP}:${custom_port}/admin${RESET}"
    echo -e "${YELLOW}👑 后端地址: http://${SERVER_IP}:3000${RESET}"
    echo -e "${YELLOW}🔑 管理密码: ${admin_pass}${RESET}"
    echo -e "${YELLOW}📂 数据目录: ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}
    

    


trigger_backup() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then echo -e "${RED}错误: 未部署系统！${RESET}"; return; fi
    
    echo -ne "${YELLOW}请输入备份保存的绝对路径 [默认: $DEFAULT_BACKUP_DIR]: ${RESET}"
    read -r backup_dir
    [[ -z "$backup_dir" ]] && backup_dir="$DEFAULT_BACKUP_DIR"
    mkdir -p "$backup_dir" && chmod -R 777 "$backup_dir"
    
    cd "$BASE_DIR"
    local timestamp=$(date +%Y%m%d-%H%M%S)

    # 1. 智能判定 MySQL 是否属于远程模式
    if grep -q "mysql:" "$COMPOSE_FILE"; then
        echo -e "${CYAN}[数据库备份] 内置模式：正在热导出本地 MySQL 数据快照...${RESET}"
        local db_user=$(grep -E "^DB_USER=" "$ENV_FILE" | cut -d'=' -f2)
        local db_pass=$(grep -E "^DB_PASS=" "$ENV_FILE" | cut -d'=' -f2)
        local db_name=$(grep -E "^DB_NAME=" "$ENV_FILE" | cut -d'=' -f2)
        docker exec -e MYSQL_PWD="${db_pass}" paperphone-mysql mysqldump -u "${db_user}" "${db_name}" > "${backup_dir}/paperphone-${timestamp}.sql" 2>/dev/null
    else
        echo -e "${CYAN}[数据库备份] ${YELLOW}检测到远程 MySQL 环境，自动跳过本地数据备份。${RESET}"
    fi

    # 2. 智能判定 Redis 是否属于远程模式
    if grep -q "redis:" "$COMPOSE_FILE"; then
        echo -e "${CYAN}[缓存备份] 内置模式：正在同步本地 Redis 缓存盘...${RESET}"
        docker exec paperphone-redis redis-cli save 2>/dev/null
    else
        echo -e "${CYAN}[缓存备份] ${YELLOW}检测到远程 Redis 环境，自动跳过本地缓存备份。${RESET}"
    fi
    
    echo -e "${CYAN}[物理打包] 正在打包核心环境配置文件资产...${RESET}"
    tar -czf "${backup_dir}/paperphone-files-${timestamp}.tar.gz" server/.env docker-compose.yml 2>/dev/null
    echo -e "${GREEN}备份打包成功！保存在: $backup_dir${RESET}"
}

restore_utils() {
    echo -ne "${YELLOW}请输入你的备份文件存放绝对路径 [默认: $DEFAULT_BACKUP_DIR]: ${RESET}"
    read -r backup_dir
    [[ -z "$backup_dir" ]] && backup_dir="$DEFAULT_BACKUP_DIR"

    if [[ ! -d "$backup_dir" ]]; then echo -e "${RED}错误: 未检测到备份路径 $backup_dir${RESET}"; return; fi
    clear
    echo -e "${CYAN}====== 📥 Paperphone-plus 智能全自动恢复面板 ======${RESET}"
    echo -e "读取路径: $backup_dir"
    echo -e "----------------------------------------------------"
    
    local tar_files=($(ls "$backup_dir" 2>/dev/null | grep -E "paperphone-files-.*\.tar\.gz"))
    if [ ${#tar_files[@]} -eq 0 ]; then echo -e "${RED}未找到符合条件的 paperphone-files-*.tar.gz 压缩包！${RESET}"; return; fi
    
    for i in "${!tar_files[@]}"; do echo -e "${GREEN}[$i]${RESET} 压缩包: ${tar_files[$i]}"; done
    echo -e "----------------------------------------------------"
    echo -ne "${YELLOW}请选择要恢复的物理资产包(tar.gz)编号: ${RESET}"
    read -r tar_idx
    if [[ -z "$tar_idx" || ! "$tar_idx" =~ ^[0-9]+$ || $tar_idx -ge ${#tar_files[@]} ]]; then return; fi
    local selected_tar="${backup_dir}/${tar_files[$tar_idx]}"

    echo -ne "\n${RED}警告: 本操作会强行覆盖现有环境配置！确认回灌部署吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then return; fi

    echo -e "${YELLOW}正在安全停止本地业务前端及集群容器...${RESET}"
    if [ -d "$BASE_DIR" ]; then
        cd "$BASE_DIR" && docker compose down 2>/dev/null
    fi

    echo -e "${YELLOW}[智能基建] 检测并全自动创建本地系统主环境主目录: $BASE_DIR ...${RESET}"
    mkdir -p "$BASE_DIR/server"

    echo -e "${YELLOW}[物理释放] 正在释放回填物理配置文件资产...${RESET}"
    tar -xzf "$selected_tar" -C "$BASE_DIR/"
    cd "$BASE_DIR"

    # 3. 智能联动：MySQL 远程环境检测与直跳
    if ! grep -q "mysql:" "$COMPOSE_FILE"; then
        echo -e "${CYAN}[智能判定] MySQL 属于【远程数据库模式】，直接跳过本地 MySQL 库灌录。${RESET}"
    else
        echo -e "${YELLOW}[库灌录] 检测到内置 MySQL，正在单独拉起本地数据节点准备回灌...${RESET}"
        local sql_files=($(ls "$backup_dir" 2>/dev/null | grep -E "paperphone-.*\.sql"))
        if [ ${#sql_files[@]} -gt 0 ]; then
            docker compose up -d mysql
            echo -e "${YELLOW}等待本地 MySQL 响应初始化中...${RESET}"
            sleep 15
            
            local db_user=$(grep -E "^DB_USER=" "$ENV_FILE" | cut -d'=' -f2)
            local db_pass=$(grep -E "^DB_PASS=" "$ENV_FILE" | cut -d'=' -f2)
            local db_name=$(grep -E "^DB_NAME=" "$ENV_FILE" | cut -d'=' -f2)
            
            docker cp "${backup_dir}/${sql_files[0]}" paperphone-mysql:/tmp/restore.sql 2>/dev/null
            docker exec -i paperphone-mysql sh -c "export MYSQL_PWD='${db_pass}'; mysql -u ${db_user} ${db_name} < /tmp/restore.sql" 2>/dev/null
            docker exec paperphone-mysql rm -f /tmp/restore.sql 2>/dev/null
        else
            echo -e "${YELLOW}未检测到对应数据库 .sql 文件，跳过库回灌。${RESET}"
        fi
    fi

    # 4. 智能联动：Redis 远程环境检测与直跳
    if ! grep -q "redis:" "$COMPOSE_FILE"; then
        echo -e "${CYAN}[智能判定] Redis 属于【远程缓存模式】，无需本地容器，直接跳过。${RESET}"
    else
        echo -e "${YELLOW}[缓存拉起] 检测到内置缓存拓扑，正在拉起本地 Redis 节点...${RESET}"
        docker compose up -d redis
    fi

    echo -e "${YELLOW}正在全量复活整个前端与核心业务节点...${RESET}"
    docker compose up -d --force-recreate
    echo -e "${GREEN}🌟 集群资产及业务已完美归位！请刷新页面进行业务验证！${RESET}"
}

logs_menu() {
    while true; do
        clear
        echo -e "${CYAN}===================================${RESET}"
        echo -e "${CYAN}      📋 集群分流实时运行日志审计       ${RESET}"
        echo -e "${CYAN}===================================${RESET}"
        echo -e "${GREEN}1. 查看 Client 端 (前端 Nginx 流量日志)${RESET}"
        echo -e "${GREEN}2. 查看 Server 端 (Rust 后端业务核心日志)${RESET}"
        echo -e "${GREEN}3. 查看 MySQL (本地数据持久化层日志)${RESET}"
        echo -e "${GREEN}4. 查看 Redis (本地高频缓存层日志)${RESET}"
        echo -e "${RED}0. 返回主菜单${RESET}"
        echo -e "${CYAN}===================================${RESET}"
        echo -ne "${GREEN}请选择要审计的容器日志编号: ${RESET}"
        read -r log_choice
        if [ -d "$BASE_DIR" ]; then cd "$BASE_DIR"; fi
        case "$log_choice" in
            1) docker compose logs -f --tail=100 client ;;
            2) docker compose logs -f --tail=100 server ;;
            3) docker compose logs -f --tail=100 mysql 2>/dev/null || echo -e "${RED}远程模式未启用内置数据库。${RESET}" ;;
            4) docker compose logs -f --tail=100 redis 2>/dev/null || echo -e "${RED}远程模式未启用内置缓存。${RESET}" ;;
            0) break ;;
            *) echo -e "${RED}选择无效！${RESET}" && sleep 1 ;;
        esac
    done
}

uninstall_utils() {
    echo -ne "${YELLOW}确定要彻底卸载并删除 Paperphone-plus 吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器集群已安全解除绑架并释放。${RESET}"
            echo -ne "${YELLOW}是否同时彻底清除宿主机物理配置和核心缓存卷？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}物理痕迹已彻底抹去。${RESET}"
            fi
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { if [ -d "$BASE_DIR" ]; then cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}已启动${RESET}"; fi; }
stop_utils() { if [ -d "$BASE_DIR" ]; then cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}已停止${RESET}"; fi; }
restart_utils() { if [ -d "$BASE_DIR" ]; then cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}已重启${RESET}"; fi; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}Client 端服务状态: $status"
    echo -e "${YELLOW}默认前端服务端口 : ${port_display}${RESET}"
    echo -e "--------------------------------"
    docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "paperphone"
    echo -e "${GREEN}================================${RESET}"
}

update_utils() {
    if [[ ! -f "$BASE_DIR" ]]; then echo -e "${RED}错误: 未部署！${RESET}"; return; fi
    cd "$BASE_DIR" && docker compose pull && docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN} ◈  Paperphone-plus  管理面板  ◈ ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}前端状态 :${RESET} $status"
    echo -e "${GREEN}活动端口 :${RESET} ${YELLOW}${port_display}${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN} 1. 部署启动${RESET}"
    echo -e "${GREEN} 2. 更新容器${RESET}"
    echo -e "${GREEN} 3. 卸载容器${RESET}"
    echo -e "${GREEN} 4. 启动容器${RESET}"
    echo -e "${GREEN} 5. 停止容器${RESET}"
    echo -e "${GREEN} 6. 重启容器${RESET}"
    echo -e "${GREEN} 7. 查看日志${RESET}"
    echo -e "${GREEN} 8. 状态报告${RESET}"
    echo -e "${GREEN} 9. 备份${RESET}"
    echo -e "${GREEN}10. 恢复${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -ne "${GREEN}请输入操作代号: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_utils ;;
        2) update_utils ;;
        3) uninstall_utils ;;
        4) start_utils ;;
        5) stop_utils ;;
        6) restart_utils ;;
        7) logs_menu ;;
        8) show_info ;;
        9) trigger_backup ;;
        10) restore_utils ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效代号！${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
