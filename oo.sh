#!/bin/bash
# =================================================================
# Rhex 论坛系统 - 动态灾备与多路日志面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
MAGENTA="\033[35m"
RESET="\033[0m"

BASE_DIR="/opt/rhex"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
DEFAULT_BACKUP_DIR="$BASE_DIR/backups"

check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker！${RESET}"; exit 1
    fi
}

get_status_info() {
    local active_id=$(docker ps -q --filter "ancestor=lovedevpanda/rhex" | xargs -I {} docker inspect --format '{{if expr (index .Config.Cmd 2) "==" "start"}}{{.Id}}{{end}}' {} 2>/dev/null | head -n 1)
    [[ -z "$active_id" ]] && active_id=$(docker ps -q --filter "name=web" --filter "status=running" | head -n 1)
    
    if [ -n "$active_id" ]; then
        status="${GREEN}运行中${RESET}"
        webui_port=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{(index $conf 0).HostPort}}{{end}}' "$active_id" 2>/dev/null)
        if [[ -z "$webui_port" || "$webui_port" == "<nil>" ]]; then
            webui_port=$(grep -E "^PORT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2)
            [[ -z "$webui_port" ]] && webui_port="3000"
        fi
        port_display="${webui_port}"
    else
        local dead_id=$(docker ps -aq --filter "name=web" | head -n 1)
        if [ -n "$dead_id" ]; then status="${RED}已停止${RESET}"; else status="${RED}未部署${RESET}"; fi
        port_display="N/A"
    fi
}

# 获取公网 IP (兼容双栈环境)
get_public_ip() {
    local mode=${1:-"auto"}
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

install_utils() {
    check_dependencies
    mkdir -p "$BASE_DIR/uploads" "$BASE_DIR/addons"
    chmod -R 777 "$BASE_DIR/uploads" "$BASE_DIR/addons"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 数据库部署模式选择 ======${RESET}"
    echo -e "${GREEN}1) 内置常规模式${RESET} (本地创建并运行 Postgres/Redis)"
    echo -e "${GREEN}2) 远程数据模式${RESET} (跨网络连接外部 RDS/独立数据库)"
    echo -ne "${YELLOW}请选择模式 [默认 1]: ${RESET}"; read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    local pg_host="postgres" local redis_host="redis" local pg_user="postgres" local pg_pass="postgres"
    local pg_db="bbs" local pg_port="5432" local redis_pass="" local redis_port="6379" local redis_db_num="0"
    local use_redis_url_auth="n"

    if [ "$db_mode" = "2" ]; then
        echo -e "\n${CYAN}➜ 请输入远程 PostgreSQL 配置:${RESET}"
        echo -ne "${YELLOW}远程 PostgreSQL 地址 (Host): ${RESET}"; read -r pg_host
        echo -ne "${YELLOW}远程 PostgreSQL 端口 (Port) [默认 5432]: ${RESET}"; read -r tmp_port; [[ -n "$tmp_port" ]] && pg_port="$tmp_port"
        echo -ne "${YELLOW}远程 PostgreSQL 用户 (User) [默认 postgres]: ${RESET}"; read -r tmp_user; [[ -n "$tmp_user" ]] && pg_user="$tmp_user"
        echo -ne "${YELLOW}远程 PostgreSQL 密码 (Password): ${RESET}"; read -r pg_pass
        echo -ne "${YELLOW}远程 PostgreSQL 数据库名 (DB Name) [默认 bbs]: ${RESET}"; read -r tmp_db; [[ -n "$tmp_db" ]] && pg_db="$tmp_db"

        echo -e "\n${CYAN}➜ 请输入远程 Redis 配置:${RESET}"
        echo -ne "${YELLOW}远程 Redis 地址 (Host): ${RESET}"; read -r redis_host
        echo -ne "${YELLOW}远程 Redis 端口 (Port) [默认 6379]: ${RESET}"; read -r tmp_rport; [[ -n "$tmp_rport" ]] && redis_port="$tmp_rport"
        echo -ne "${YELLOW}远程 Redis 分库编号 (DB) [默认 0]: ${RESET}"; read -r tmp_rdb; [[ -n "$tmp_rdb" ]] && redis_db_num="$tmp_rdb"
        echo -ne "${YELLOW}远程 Redis 密码 (没有直接回车): ${RESET}"; read -r redis_pass
        if [[ -n "$redis_pass" ]]; then
            echo -ne "${YELLOW}是否直接将认证信息写入 REDIS_URL 连接串中？(y/n) [默认 n]: ${RESET}"; read -r use_redis_url_auth
        fi
    else
        redis_pass=$(date +%s%N | sha256sum | base64 | head -c 16)
    fi

    local redis_url_str=""
    if [ "$use_redis_url_auth" = "y" ] || [ "$use_redis_url_auth" = "Y" ]; then
        redis_url_str="redis://:${redis_pass}@${redis_host}:${redis_port}/${redis_db_num}"
    else
        redis_url_str="redis://${redis_host}:${redis_port}"
    fi

    echo -e "\n${CYAN}====== 2. 网络端口与站点配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Rhex 前端访问端口 [默认 3000]: ${RESET}"; read -r custom_port; [[ -z "$custom_port" ]] && custom_port="3000"
    echo -ne "${YELLOW}请输入站点公网 URL (例如 https://bbs.rhex.im, 可选): ${RESET}"; read -r site_url

    echo -e "\n${CYAN}====== 3. 管理员初始化配置 (仅首次生效) ======${RESET}"
    echo -ne "${YELLOW}管理员用户名 [默认 admin]: ${RESET}"; read -r admin_user; [[ -z "$admin_user" ]] && admin_user="admin"
    echo -ne "${YELLOW}管理员密码 [默认 ChangeMe_123456]: ${RESET}"; read -r admin_pass; [[ -z "$admin_pass" ]] && admin_pass="ChangeMe_123456"
    echo -ne "${YELLOW}管理员邮箱 [默认 admin@rhex.im]: ${RESET}"; read -r admin_email; [[ -z "$admin_email" ]] && admin_email="admin@rhex.im"
    echo -ne "${YELLOW}管理员昵称 [默认 秦始皇]: ${RESET}"; read -r admin_nick; [[ -z "$admin_nick" ]] && admin_nick="秦始皇"

    local rand_session=$(date +%s | sha256sum | base64 | head -c 32)
    local rand_captcha=$(date +%s%N | sha256sum | base64 | head -c 32)

    cat <<EOF > "$ENV_FILE"
PORT=${custom_port}
TZ=Asia/Shanghai
SESSION_SECRET="${rand_session}"
CAPTCHA_SECRET_KEY="${rand_captcha}"
POSTGRES_DB=${pg_db}
POSTGRES_USER=${pg_user}
POSTGRES_PASSWORD=${pg_pass}
POSTGRES_PORT=${pg_port}
REDIS_PORT=${redis_port}
REDIS_KEY_PREFIX=rhex
SEED_ADMIN_USERNAME="${admin_user}"
SEED_ADMIN_PASSWORD="${admin_pass}"
SEED_ADMIN_EMAIL="${admin_email}"
SEED_ADMIN_NICKNAME="${admin_nick}"
BACKGROUND_JOB_WEB_RUNTIME=worker-only
BACKGROUND_JOB_CONCURRENCY=10
BACKGROUND_JOB_MAX_ATTEMPTS=3
BACKGROUND_JOB_RETRY_BASE_MS=5000
BACKGROUND_JOB_RETRY_MAX_MS=300000
EOF

    if [ "$use_redis_url_auth" != "y" ] && [ "$use_redis_url_auth" != "Y" ]; then
        echo -e "REDIS_PASSWORD=\"${redis_pass}\"\nREDIS_DB=\"${redis_db_num}\"" >> "$ENV_FILE"
    else
        echo -e "REDIS_PASSWORD=\"\"\nREDIS_DB=\"\"" >> "$ENV_FILE"
    fi
    [[ -n "$site_url" ]] && echo -e "SITE_URL=\"${site_url}\"\nAPP_URL=\"${site_url}\"" >> "$ENV_FILE"

    cat <<EOF > "$COMPOSE_FILE"
x-app-environment: &app-environment
  DATABASE_URL: postgresql://${pg_user}:${pg_pass}@${pg_host}:${pg_port}/${pg_db}?schema=public
  REDIS_URL: "${redis_url_str}"
  REDIS_PASSWORD: \${REDIS_PASSWORD:-}
  REDIS_DB: \${REDIS_DB:-}

x-app-service: &app-service
  image: ghcr.io/lovedevpanda/rhex:latest
  pull_policy: always
  init: true
  env_file:
    - .env
  volumes:
    - ./uploads:/app/uploads
    - ./addons:/app/addons

services:
EOF

    if [ "$db_mode" = "1" ]; then
        cat <<EOF >> "$COMPOSE_FILE"
  postgres:
    image: postgres:18
    container_name: rhex-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: \${POSTGRES_DB:-bbs}
      POSTGRES_USER: \${POSTGRES_USER:-postgres}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:-postgres}
      TZ: \${TZ:-Asia/Shanghai}
    ports:
      - "127.0.0.1:\${POSTGRES_PORT:-5432}:5432"
    volumes:
      - postgres_data:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -U \${POSTGRES_USER:-postgres} -d \${POSTGRES_DB:-bbs}"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 10s

  redis:
    image: redis:latest
    container_name: rhex-redis
    restart: unless-stopped
    command:
      - sh
      - -c
      - |
        set -eu
        if [ -n "\$\${REDIS_PASSWORD:-}" ]; then
          exec redis-server --appendonly yes --requirepass "\$\${REDIS_PASSWORD}"
        fi
        exec redis-server --appendonly yes
    environment:
      REDIS_PASSWORD: \${REDIS_PASSWORD:-}
    ports:
      - "127.0.0.1:\${REDIS_PORT:-6379}:6379"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD-SHELL", "if [ -n \"\$\${REDIS_PASSWORD:-}\" ]; then redis-cli -a \"\$\${REDIS_PASSWORD}\" --no-auth-warning ping; else redis-cli ping; fi"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 5s
EOF
    fi

    cat <<EOF >> "$COMPOSE_FILE"
  setup:
    <<: *app-service
    container_name: rhex-setup
    restart: on-failure
    environment: *app-environment
EOF
    [[ "$db_mode" = "1" ]] && echo -e "    depends_on:\n      postgres:\n        condition: service_healthy\n      redis:\n        condition: service_healthy" >> "$COMPOSE_FILE"
    
    cat <<EOF >> "$COMPOSE_FILE"
    command: ["pnpm", "run", "setup:prod"]

  web:
    <<: *app-service
    container_name: rhex-web
    restart: unless-stopped
    stop_grace_period: 30s
    environment:
      <<: *app-environment
      HOSTNAME: \${HOSTNAME:-0.0.0.0}
      PORT: \${PORT:-3000}
    ports:
      - "\${PORT:-3000}:\${PORT:-3000}"
    command: ["pnpm", "run", "start"]
    depends_on:
      setup:
        condition: service_completed_successfully
EOF
    if [ "$db_mode" = "1" ]; then
        cat <<EOF >> "$COMPOSE_FILE"
      postgres:
        condition: service_healthy
        restart: true
      redis:
        condition: service_healthy
        restart: true
EOF
    fi

    cat <<EOF >> "$COMPOSE_FILE"
  worker:
    <<: *app-service
    container_name: rhex-worker
    restart: unless-stopped
    stop_grace_period: 30s
    environment:
      <<: *app-environment
      INTERNAL_REVALIDATION_ORIGIN: \${INTERNAL_REVALIDATION_ORIGIN:-http://web:\${PORT:-3000}}
    command: ["pnpm", "run", "worker"]
    depends_on:
      setup:
        condition: service_completed_successfully
EOF
    if [ "$db_mode" = "1" ]; then
        cat <<EOF >> "$COMPOSE_FILE"
      postgres:
        condition: service_healthy
        restart: true
      redis:
        condition: service_healthy
        restart: true
EOF
    fi

    [[ "$db_mode" = "1" ]] && echo -e "\nvolumes:\n  postgres_data:\n  redis_data:" >> "$COMPOSE_FILE"

    echo -e "${YELLOW}正在通过 Docker Compose 部署运行拓扑...${RESET}"
    cd "$BASE_DIR" && docker compose up -d

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}         Rhex 官方全集成架构 部署成功！              ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}论坛访问地址     : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}初始管理员账号   : ${admin_user}${RESET}"
    echo -e "${YELLOW}初始管理员密码   : ${admin_pass}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 动态自定义路径的复合备份
trigger_backup() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then echo -e "${RED}错误: 未部署！${RESET}"; return; fi
    
    echo -ne "${YELLOW}请输入备份保存的绝对路径 [默认: $DEFAULT_BACKUP_DIR]: ${RESET}"
    read -r backup_dir
    [[ -z "$backup_dir" ]] && backup_dir="$DEFAULT_BACKUP_DIR"
    mkdir -p "$backup_dir" && chmod -R 777 "$backup_dir"
    
    cd "$BASE_DIR"
    echo -e "${CYAN}[步骤 1/2] 正在备份并导出 .dump 数据库快照...${RESET}"
    local pg_user=$(grep -E "^POSTGRES_USER=" "$ENV_FILE" | cut -d'=' -f2)
    local pg_pass=$(grep -E "^POSTGRES_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2)
    local pg_db=$(grep -E "^POSTGRES_DB=" "$ENV_FILE" | cut -d'=' -f2)
    local pg_host="postgres"
    if grep -q "DATABASE_URL: postgresql://" "$COMPOSE_FILE"; then
        pg_host=$(grep "DATABASE_URL:" "$COMPOSE_FILE" | head -n 1 | cut -d'@' -f2 | cut -d':' -f1)
    fi
    
    local timestamp=$(date +%Y%m%d-%H%M%S)
    
    if [ "$pg_host" = "postgres" ] || [ "$pg_host" = "127.0.0.1" ]; then
        docker exec -e PGPASSWORD="${pg_pass}" rhex-postgres pg_dump -U "${pg_user}" -d "${pg_db}" -Fc -f "/var/lib/postgresql/rhex-${timestamp}.dump" 2>/dev/null
        docker cp rhex-postgres:/var/lib/postgresql/rhex-${timestamp}.dump "${backup_dir}/" 2>/dev/null
        docker exec rhex-postgres rm -f "/var/lib/postgresql/rhex-${timestamp}.dump" 2>/dev/null
    else
        docker run --rm --network=host -v "${backup_dir}:/backups" -e PGPASSWORD="${pg_pass}" postgres:18 pg_dump -h "${pg_host}" -U "${pg_user}" -d "${pg_db}" -Fc -f "/backups/rhex-${timestamp}.dump" 2>/dev/null
    fi
    
    echo -e "${CYAN}[步骤 2/2] 打包网页物理归档...${RESET}"
    local target_tar="${backup_dir}/rhex-files-${timestamp}.tar.gz"
    tar -czf "$target_tar" uploads addons .env docker-compose.yml
    echo -e "${GREEN}全量资产打包成功！位置: $backup_dir${RESET}"
}


restore_utils() {
    echo -ne "${YELLOW}请输入你的备份文件存放绝对路径 [默认: $DEFAULT_BACKUP_DIR]: ${RESET}"
    read -r backup_dir
    [[ -z "$backup_dir" ]] && backup_dir="$DEFAULT_BACKUP_DIR"

    if [[ ! -d "$backup_dir" ]]; then echo -e "${RED}错误: 未检测到备份路径 $backup_dir${RESET}"; return; fi
    clear
    echo -e "${CYAN}====== 📥 Rhex 本地常规模式灾备强灌恢复面板 ======${RESET}"
    echo -e "读取路径: $backup_dir"
    echo -e "----------------------------------------------------"
    
    local tar_files=($(ls "$backup_dir" 2>/dev/null | grep -E "rhex-files-.*\.tar\.gz"))
    if [ ${#tar_files[@]} -eq 0 ]; then echo -e "${RED}未找到符合条件的 rhex-files-*.tar.gz 压缩包！${RESET}"; return; fi
    
    for i in "${!tar_files[@]}"; do echo -e "${GREEN}[$i]${RESET} 压缩包: ${tar_files[$i]}"; done
    echo -e "----------------------------------------------------"
    echo -ne "${YELLOW}请选择要恢复的网页物理快照(tar.gz)编号: ${RESET}"
    read -r tar_idx
    if [[ -z "$tar_idx" || ! "$tar_idx" =~ ^[0-9]+$ || $tar_idx -ge ${#tar_files[@]} ]]; then return; fi
    local selected_tar="${backup_dir}/${tar_files[$tar_idx]}"

    echo -e "\n${CYAN}----------------------------------------------------${RESET}"
    local dump_files=($(ls "$backup_dir" 2>/dev/null | grep -E "rhex-.*\.dump"))
    if [ ${#dump_files[@]} -eq 0 ]; then
        echo -e "${RED}未找到任何 .dump 数据库快照！恢复终止。${RESET}"; return
    else
        for i in "${!dump_files[@]}"; do echo -e "${CYAN}[$i]${RESET} 帖子数据库: ${dump_files[$i]}"; done
        echo -e "----------------------------------------------------"
        echo -ne "${YELLOW}请选择你要恢复灌录的帖子数据 (.dump) 编号: ${RESET}"
        read -r dump_idx
    fi

    echo -ne "\n${RED}警告: 本操作会强行覆盖现有本地表结构！确认回灌帖子数据吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then return; fi

    echo -e "${YELLOW}正在安全停止本地业务线前端容器...${RESET}"
    # 如果目录不存在，先跳过 down，防止 cd 报错
    if [ -d "$BASE_DIR" ]; then
        cd "$BASE_DIR" && docker compose down 2>/dev/null
    fi

    echo -e "${YELLOW}[核心特性] 检测并自动创建本地系统主环境主目录: $BASE_DIR ...${RESET}"
    mkdir -p "$BASE_DIR"

    echo -e "${YELLOW}[步骤 1/2] 正在回填本地配置文件及文件资产...${RESET}"
    tar -xzf "$selected_tar" -C "$BASE_DIR/"

    # 此时 $BASE_DIR 肯定有文件了，直接切换进去
    cd "$BASE_DIR"

    local pg_user=$(grep -E "^POSTGRES_USER=" "$ENV_FILE" | cut -d'=' -f2)
    local pg_pass=$(grep -E "^POSTGRES_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2)
    local pg_db=$(grep -E "^POSTGRES_DB=" "$ENV_FILE" | cut -d'=' -f2)
    local target_dump_name="${dump_files[$dump_idx]}"

    echo -e "${YELLOW}[步骤 2/2] 正在拉起本地独立 Postgres 数据节点进行高权限沙箱回灌...${RESET}"
    docker compose up -d postgres
    echo -e "${YELLOW}等待本地库响应初始化中...${RESET}"
    sleep 10

    docker cp "${backup_dir}/${target_dump_name}" rhex-postgres:/tmp/restore.dump
    echo -e "${CYAN}正在对本地数据库实施 Clean & Overwrite 帖子恢复...${RESET}"
    docker exec -e PGPASSWORD="${pg_pass}" rhex-postgres pg_restore -U "${pg_user}" -d "${pg_db}" -c --if-exists /tmp/restore.dump
    docker exec rhex-postgres rm -f /tmp/restore.dump

    echo -e "${YELLOW}正在全面唤醒整个前端 Web 业务和分布式 Worker...${RESET}"
    docker compose up -d --force-recreate
    echo -e "${GREEN}🌟 帖子数据流已完美强灌还原！请刷新本地论坛页面确认！${RESET}"
}

# 独立的二级日志管理子菜单
logs_menu() {
    while true; do
        clear
        echo -e "${GREEN}===================================${RESET}"
        echo -e "${GREEN}     📋 容器集群分流日志审计面板     ${RESET}"
        echo -e "${GREEN}===================================${RESET}"
        echo -e "${GREEN}1. 查看 Web 端 (前端流实时运行日志)${RESET}"
        echo -e "${GREEN}2. 查看 Worker 端 (后台异步任务日志)${RESET}"
        echo -e "${GREEN}3. 查看 Postgres (本地数据库核心日志)${RESET}"
        echo -e "${GREEN}4. 查看 Redis (本地高并发缓存日志)${RESET}"
        echo -e "${GREEN}0. 返回主菜单${RESET}"
        echo -e "${GREEN}===================================${RESET}"
        echo -ne "${GREEN}请选择要审计的容器日志编号: ${RESET}"
        read -r log_choice
        cd "$BASE_DIR"
        case "$log_choice" in
            1) docker compose logs -f --tail=100 web ;;
            2) docker compose logs -f --tail=100 worker ;;
            3) docker compose logs -f --tail=100 postgres 2>/dev/null || echo -e "${RED}未在此节点找到内置数据库服务。${RESET}" ;;
            4) docker compose logs -f --tail=100 redis 2>/dev/null || echo -e "${RED}未在此节点找到内置缓存服务。${RESET}" ;;
            0) break ;;
            *) echo -e "${RED}选择无效！${RESET}" && sleep 1 ;;
        esac
    done
}

update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then echo -e "${RED}错误: 未部署！${RESET}"; return; fi
    cd "$BASE_DIR" && docker compose pull && docker compose up -d --remove-orphans
    echo -e "${GREEN}升级完成！${RESET}"
}


uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 Rhex吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时彻底删除本地全部数据库与配置缓存？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地全部配置与缓存已彻底清理。${RESET}"
            fi
        else
            docker rm -f "rhex-web" "rhex-worker" "rhex-setup" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}已重启${RESET}"; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}Web端运行状态    : $status"
    echo -e "${YELLOW}当前前端活动端口 : ${port_display}${RESET}"
    echo -e "--------------------------------"
    docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "rhex|postgres|redis"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}    ◈  Rhex    论坛管理面板 ◈      ${RESET}"
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
