#!/bin/bash
# =================================================================
# MailGo - 面板
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
MAGENTA="\033[35m"
RESET="\033[0m"

BASE_DIR="/opt/mailgo"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
DEFAULT_BACKUP_DIR="$BASE_DIR/backups"

check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker！${RESET}"; exit 1
    fi
}


# 格式化 URL 中的 IP (如果是 IPv6 则加上方括号 [])
format_ip_for_url() {
    local ip="$1"
    if [[ "$ip" == *":"* ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}


get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
}

# 动态获取容器整体状态和端口
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        web_port="N/A"
        data_dir="N/A"
        return 0
    fi
    if [ -f "$COMPOSE_FILE" ]; then
        # 1. 尝试动态获取运行状态
        if [ "$(docker ps -q -f name=mailgo)" ]; then
            status="${GREEN}运行中${RESET}"
            web_port=$(docker inspect --format='{{(index (index .NetworkSettings.Ports "5547/tcp") 0).HostPort}}' mailgo 2>/dev/null)
        elif [ "$(docker ps -aq -f name=mailgo)" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=""
        else
            status="${RED}未部署${RESET}"
            web_port=""
        fi
        
        # 2. 如果 Inspect 读取为空（或容器未运行），触发智能静态解包
        if [ -z "$web_port" ]; then
            # 改进点：放宽匹配规则，允许提取包含 $SERVER_PORT 变量的行
            web_port=$(sed -n '/mailgo:/,/^[[:space:]]*[a-zA-Z]/p' "$COMPOSE_FILE" | grep -E '\-[[:space:]]*["'\'']?[0-9$]+' | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"''-${}')
            
            # 3. 判定提取出来的是否是环境变量占位符
            if [[ -z "$web_port" || "$web_port" == *"SERVER_PORT"* || ! "$web_port" =~ ^[0-9]+$ ]]; then
                if [ -f "$ENV_FILE" ]; then
                    # 精准从 .env 中抓取 SERVER_PORT
                    web_port=$(grep -E "^SERVER_PORT=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
                fi
            fi
            
            # 4. 终极防空兜底
            [[ -z "$web_port" ]] && web_port="8080"
        fi
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
    
    # 传递给面板打印变量
    port_display="$web_port"
}


install_utils() {
    check_dependencies
    mkdir -p "$BASE_DIR"
    
    echo -e "${CYAN}====== 1. 数据库与缓存部署模式选择 ======${RESET}"
    echo -e "${GREEN}1) 内置常规模式 (本地跑 MySQL 和 Redis 容器)${RESET}"
    echo -e "${GREEN}2) 远程数据模式 (连接外部已有的 MySQL/Redis，跳过本地库)${RESET}"
    echo -ne "${YELLOW}请选择模式 [默认 1]: ${RESET}"; read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    local db_host="mysql" local redis_host="redis" local db_user="mailgo" local db_pass="mailgo_secret"
    local db_name="mailgo" local db_port="3306" local redis_pass="" local redis_port="6379" local redis_db="0"
    local db_root_pass="root_secret"

    if [ "$db_mode" = "2" ]; then
        echo -e "\n${CYAN}➜ 请输入远程 MySQL 配置:${RESET}"
        echo -ne "${YELLOW}远程 MySQL 地址 (Host): ${RESET}"; read -r db_host
        echo -ne "${YELLOW}远程 MySQL 端口 (Port) [默认 3306]: ${RESET}"; read -r tmp_port; [[ -n "$tmp_port" ]] && db_port="$tmp_port"
        echo -ne "${YELLOW}远程 MySQL 用户 (User) [默认 mailgo]: ${RESET}"; read -r tmp_user; [[ -n "$tmp_user" ]] && db_user="$tmp_user"
        echo -ne "${YELLOW}远程 MySQL 密码: ${RESET}"; read -r db_pass
        echo -ne "${YELLOW}远程 MySQL 数据库名 (DB Name) [默认 mailgo]: ${RESET}"; read -r tmp_db; [[ -n "$tmp_db" ]] && db_name="$tmp_db"

        echo -e "\n${CYAN}➜ 请输入远程 Redis 配置:${RESET}"
        echo -ne "${YELLOW}远程 Redis 地址 (Host): ${RESET}"; read -r redis_host
        echo -ne "${YELLOW}远程 Redis 端口 (Port) [默认 6379]: ${RESET}"; read -r tmp_rport; [[ -n "$tmp_rport" ]] && redis_port="$tmp_rport"
        echo -ne "${YELLOW}远程 Redis 分区/库编号 (DB Index) [默认 0]: ${RESET}"; read -r tmp_rdb; [[ -n "$tmp_rdb" ]] && redis_db="$tmp_rdb"
        echo -ne "${YELLOW}远程 Redis 密码 (无密码直接回车): ${RESET}"; read -r redis_pass
    fi

    echo -e "\n${CYAN}====== 2. 安全与基础密钥配置 ======${RESET}"
    local rand_key=$(date +%s | sha256sum | head -c 32)
    echo -ne "${YELLOW}请输入 MailGo 访问端口 [默认 8080]: ${RESET}"; read -r custom_port; [[ -z "$custom_port" ]] && custom_port="8080"
    echo -ne "${YELLOW}请输入镜像版本标签 (Image Tag) [默认 latest]: ${RESET}"; read -r image_tag; [[ -z "$image_tag" ]] && image_tag="latest"

    # 写入 .env 文件
    cat <<EOF > "$ENV_FILE"
# ═══════════════════════════════════════════════════════════════
#  MailGo Environment Configuration
# ═══════════════════════════════════════════════════════════════

ENCRYPTION_KEY=${rand_key}
SERVER_PORT=${custom_port}
MAILGO_IMAGE_TAG=${image_tag}
TRUSTED_PROXIES=

# ── MySQL 配置 ──
MYSQL_USER=${db_user}
MYSQL_PASSWORD=${db_pass}
MYSQL_HOST=${db_host}
MYSQL_PORT=${db_port}
MYSQL_DATABASE=${db_name}
MYSQL_ROOT_PASSWORD=${db_root_pass}

# ── Redis 配置 ──
REDIS_HOST=${redis_host}
REDIS_PORT=${redis_port}
REDIS_PASSWORD=${redis_pass}
REDIS_DB=${redis_db}
EOF

    # 根据部署模式，智能生成内部依赖块
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

    # 构造核心 docker-compose.yml 拓扑
    cat <<EOF > "$COMPOSE_FILE"
services:
  mailgo:
    image: ghcr.io/mengmengcode/mailgo:\${MAILGO_IMAGE_TAG:-latest}
    container_name: mailgo
    restart: unless-stopped
    ports:
      - "\${SERVER_PORT:-8080}:\${SERVER_PORT:-8080}"
    env_file: .env
${server_depends}

EOF

    # 只有常规模式下，才会追加本地数据基础设施
    if [ "$db_mode" = "1" ]; then
        cat <<EOF >> "$COMPOSE_FILE"
  mysql:
    image: mysql:8.0
    container_name: mailgo-mysql
    restart: unless-stopped
    command:
      - --innodb-buffer-pool-size=\${MYSQL_INNODB_BUFFER_POOL_SIZE:-256M}
      - --innodb-log-file-size=\${MYSQL_INNODB_LOG_FILE_SIZE:-128M}
      - --innodb-flush-log-at-trx-commit=\${MYSQL_INNODB_FLUSH_LOG_AT_TRX_COMMIT:-2}
      - --innodb-flush-method=O_DIRECT
      - --max-connections=\${MYSQL_MAX_CONNECTIONS:-50}
      - --performance-schema=OFF
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD:-root_secret}
      MYSQL_DATABASE: mailgo
      MYSQL_USER: mailgo
      MYSQL_PASSWORD: \${MYSQL_PASSWORD:-mailgo_secret}
    volumes:
      - mysql-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p\${MYSQL_ROOT_PASSWORD:-root_secret}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  redis:
    image: redis:7-alpine
    container_name: mailgo-redis
    restart: unless-stopped
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  mysql-data:
  redis-data:
EOF
    fi

    echo -e "${YELLOW}正在通过 Docker Compose 部署并拉起集群...${RESET}"
    cd "$BASE_DIR" && docker compose up -d
    echo -e "${GREEN}MailGo 容器集群正在初始化...${RESET}"
    sleep 5

    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             MailGo 部署成功！                      ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://${DETECT_IP}:${port_display}${RESET}"
    echo -e "${YELLOW}📂 数据目录: ${BASE_DIR}${RESET}"
    echo -e "${MAGENTA}🔑 首次安装 - 正在尝试抓取控制台初始密码:${RESET}"
    echo -e "----------------------------------------------------"
    docker logs mailgo 2>&1 | grep -E "Password|password|密码" || echo -e "${YELLOW}未在日志中匹配到初始密码，可稍后前往日志审计功能查看。${RESET}"
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
    if grep -q "mailgo-mysql" "$COMPOSE_FILE"; then
        echo -e "${CYAN}[数据库备份] 内置模式：正在热导出本地 MySQL 数据快照...${RESET}"
        local db_user=$(grep -E "^MYSQL_USER=" "$ENV_FILE" | cut -d'=' -f2)
        local db_pass=$(grep -E "^MYSQL_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2)
        local db_name=$(grep -E "^MYSQL_DATABASE=" "$ENV_FILE" | cut -d'=' -f2)
        docker exec -e MYSQL_PWD="${db_pass}" mailgo-mysql mysqldump -u "${db_user}" "${db_name}" > "${backup_dir}/mailgo-${timestamp}.sql" 2>/dev/null
    else
        echo -e "${CYAN}[数据库备份] ${YELLOW}检测到远程 MySQL 环境，自动跳过本地数据备份。${RESET}"
    fi

    # 2. 智能判定 Redis 是否属于远程模式
    if grep -q "mailgo-redis" "$COMPOSE_FILE"; then
        echo -e "${CYAN}[缓存备份] 内置模式：正在同步本地 Redis 缓存盘...${RESET}"
        docker exec mailgo-redis redis-cli save 2>/dev/null
    else
        echo -e "${CYAN}[缓存备份] ${YELLOW}检测到远程 Redis 环境，自动跳过本地缓存备份。${RESET}"
    fi
    
    echo -e "${CYAN}[物理打包] 正在打包核心环境配置文件资产...${RESET}"
    tar -czf "${backup_dir}/mailgo-files-${timestamp}.tar.gz" .env docker-compose.yml 2>/dev/null
    echo -e "${GREEN}备份打包成功！保存在: $backup_dir${RESET}"
}

restore_utils() {
    echo -ne "${YELLOW}请输入你的备份文件存放绝对路径 [默认: $DEFAULT_BACKUP_DIR]: ${RESET}"
    read -r backup_dir
    [[ -z "$backup_dir" ]] && backup_dir="$DEFAULT_BACKUP_DIR"

    if [[ ! -d "$backup_dir" ]]; then echo -e "${RED}错误: 未检测到备份路径 $backup_dir${RESET}"; return; fi
    clear
    echo -e "${CYAN}====== 📥 MailGo 智能全自动恢复面板 ======${RESET}"
    echo -e "读取路径: $backup_dir"
    echo -e "----------------------------------------------------"
    
    local tar_files=($(ls "$backup_dir" 2>/dev/null | grep -E "mailgo-files-.*\.tar\.gz"))
    if [ ${#tar_files[@]} -eq 0 ]; then echo -e "${RED}未找到符合条件的 mailgo-files-*.tar.gz 压缩包！${RESET}"; return; fi
    
    for i in "${!tar_files[@]}"; do echo -e "${GREEN}[$i]${RESET} 压缩包: ${tar_files[$i]}"; done
    echo -e "----------------------------------------------------"
    echo -ne "${YELLOW}请选择要恢复的物理资产包(tar.gz)编号: ${RESET}"
    read -r tar_idx
    if [[ -z "$tar_idx" || ! "$tar_idx" =~ ^[0-9]+$ || $tar_idx -ge ${#tar_files[@]} ]]; then return; fi
    local selected_tar="${backup_dir}/${tar_files[$tar_idx]}"

    echo -ne "\n${RED}警告: 本操作会强行覆盖现有环境配置！确认回灌部署吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then return; fi

    echo -e "${YELLOW}正在安全停止本地主服务及集群容器...${RESET}"
    if [ -d "$BASE_DIR" ]; then
        cd "$BASE_DIR" && docker compose down 2>/dev/null
    fi

    echo -e "${YELLOW}[智能基建] 检测并全自动创建系统主目录: $BASE_DIR ...${RESET}"
    mkdir -p "$BASE_DIR"

    echo -e "${YELLOW}[物理释放] 正在释放回填物理配置文件资产...${RESET}"
    tar -xzf "$selected_tar" -C "$BASE_DIR/"
    cd "$BASE_DIR"

    # 3. 智能联动：MySQL 远程环境检测与直跳
    if ! grep -q "mailgo-mysql" "$COMPOSE_FILE"; then
        echo -e "${CYAN}[智能判定] MySQL 属于【远程数据库模式】，直接跳过本地 MySQL 库灌录。${RESET}"
    else
        echo -e "${YELLOW}[库灌录] 检测到内置 MySQL，正在单独拉起本地数据节点准备回灌...${RESET}"
        local sql_files=($(ls "$backup_dir" 2>/dev/null | grep -E "mailgo-.*\.sql"))
        if [ ${#sql_files[@]} -gt 0 ]; then
            docker compose up -d mysql
            echo -e "${YELLOW}等待本地 MySQL 响应初始化中 (15s)...${RESET}"
            sleep 15
            
            local db_user=$(grep -E "^MYSQL_USER=" "$ENV_FILE" | cut -d'=' -f2)
            local db_pass=$(grep -E "^MYSQL_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2)
            local db_name=$(grep -E "^MYSQL_DATABASE=" "$ENV_FILE" | cut -d'=' -f2)
            
            docker cp "${backup_dir}/${sql_files[0]}" mailgo-mysql:/tmp/restore.sql 2>/dev/null
            docker exec -i mailgo-mysql sh -c "export MYSQL_PWD='${db_pass}'; mysql -u ${db_user} ${db_name} < /tmp/restore.sql" 2>/dev/null
            docker exec mailgo-mysql rm -f /tmp/restore.sql 2>/dev/null
        else
            echo -e "${YELLOW}未检测到对应数据库 .sql 文件，跳过库回灌。${RESET}"
        fi
    fi

    # 4. 智能联动：Redis 远程环境检测与直跳
    if ! grep -q "mailgo-redis" "$COMPOSE_FILE"; then
        echo -e "${CYAN}[智能判定] Redis 属于【远程缓存模式】，无需本地容器，直接跳过。${RESET}"
    else
        echo -e "${YELLOW}[缓存拉起] 检测到内置缓存拓扑，正在拉起本地 Redis 节点...${RESET}"
        docker compose up -d redis
    fi

    echo -e "${YELLOW}正在全量复活 MailGo 业务主节点...${RESET}"
    docker compose up -d --force-recreate
    echo -e "${GREEN}🌟 快照数据灾备恢复成功！请刷新页面进行业务验证！${RESET}"
}

logs_menu() {
    while true; do
        clear
        echo -e "${GREEN}===================================${RESET}"
        echo -e "${GREEN}     📋 MailGo 实时运行日志审计    ${RESET}"
        echo -e "${GREEN}===================================${RESET}"
        echo -e "${GREEN}1. 查看 MailGo 主业务运行日志${RESET}"
        echo -e "${GREEN}2. 查看 MySQL (本地数据持久化层日志)${RESET}"
        echo -e "${GREEN}3. 查看 Redis (本地高频缓存层日志)${RESET}"
        echo -e "${GREEN}0. 返回主菜单${RESET}"
        echo -e "${GREEN}===================================${RESET}"
        echo -ne "${GREEN}请选择要审计的容器日志编号: ${RESET}"
        get_status_info
        if [ -d "$BASE_DIR" ]; then cd "$BASE_DIR"; fi
        read -r log_choice
        case "$log_choice" in
            1) docker compose logs -f --tail=100 mailgo ;;
            2) docker compose logs -f --tail=100 mysql 2>/dev/null || echo -e "${RED}远程模式未启用内置数据库。${RESET}" ;;
            3) docker compose logs -f --tail=100 redis 2>/dev/null || echo -e "${RED}远程模式未启用内置缓存。${RESET}" ;;
            0) break ;;
            *) echo -e "${RED}选择无效！${RESET}" && sleep 1 ;;
        esac
    done
}

uninstall_utils() {
    echo -ne "${YELLOW}确定要彻底卸载并删除 MailGo 吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            echo -e "${GREEN}容器集群与相关挂载卷已安全解除并释放。${RESET}"
            echo -ne "${YELLOW}是否同时彻底清除宿主机物理配置和核心缓存卷？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}已彻底清除宿主机系统主目录。${RESET}"
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
    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}MailGo 服务状态 : $status"
    echo -e "${YELLOW}当前宿主机映射端口: ${port_display}${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://${DETECT_IP}:${port_display}${RESET}"
    echo -e "${YELLOW}📂 数据目录: ${BASE_DIR}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到集群编排文件 ($COMPOSE_FILE)！${RESET}"
        echo -e "${YELLOW}请先执行选项 1 部署/启动新实例。${RESET}"
        return 1
    fi

    echo -e "${CYAN}===================================${RESET}"
    echo -e "${CYAN}     🔄 正在拉取并同步最新镜像       ${RESET}"
    echo -e "${CYAN}===================================${RESET}"
    
    cd "$BASE_DIR" || exit 1

    echo -e "${YELLOW}➜ 正在连接远程仓库拉取最新 MailGo 镜像...${RESET}"
    if docker compose pull; then
        echo -e "${GREEN}✔ 镜像下载/更新完成。${RESET}"
        
        echo -e "${YELLOW}➜ 正在应用热重载应用镜像变更...${RESET}"
        docker compose up -d --remove-orphans
        echo -e "${GREEN}🌟 MailGo 已成功更新！${RESET}"
    else
        echo -e "${RED}❌ 镜像拉取失败！请检查网络连接或镜像源连通性。${RESET}"
    fi
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}      ◈   MailGo 管理面板   ◈     ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${port_display}${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN} 1. 部署启动${RESET}"
    echo -e "${GREEN} 2. 更新容器${RESET}"
    echo -e "${GREEN} 3. 卸载容器${RESET}"
    echo -e "${GREEN} 4. 启动容器${RESET}"
    echo -e "${GREEN} 5. 停止容器${RESET}"
    echo -e "${GREEN} 6. 重启容器${RESET}"
    echo -e "${GREEN} 7. 查看日志${RESET}"
    echo -e "${GREEN} 8. 查看配置${RESET}"
    echo -e "${GREEN} 9. 快照备份${RESET}"
    echo -e "${GREEN}10. 快照恢复${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
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
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
