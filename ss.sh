#!/bin/bash
# =================================================================
# Rhex 论坛系统 Docker Compose 管理面板
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

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取备份目录路径 (优先从当前 .env 或系统默认获取)
get_backup_dir() {
    local saved_dir=$(grep -E "^PANEL_BACKUP_DIR=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    if [[ -n "$saved_dir" ]]; then
        echo "$saved_dir"
    else
        echo "$BASE_DIR/backups"
    fi
}

# 动态获取核心容器状态与映射端口 (终极模糊匹配+镜像双重校验)
get_status_info() {
    # 终极智能匹配：直接查找所有正在运行、且镜像名包含 rhex 的 web 相关容器
    local active_id=$(docker ps -q --filter "ancestor=lovedevpanda/rhex" | xargs -I {} docker inspect --format '{{if expr (index .Config.Cmd 2) "==" "start"}}{{.Id}}{{end}}' {} 2>/dev/null | head -n 1)
    
    # 如果上面基于 CMD 的高级筛选落空，回退到最稳健的模糊名称过滤
    if [[ -z "$active_id" ]]; then
        active_id=$(docker ps -q --filter "name=web" --filter "status=running" | head -n 1)
    fi
    
    if [ -n "$active_id" ]; then
        status="${GREEN}运行中${RESET}"
        
        # 尝试精准抓取容器在宿主机上暴露的真实端口
        webui_port=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{(index $conf 0).HostPort}}{{end}}' "$active_id" 2>/dev/null)
        
        # 如果由于网络模式原因没抓到，直接回退读取 .env 配置文件中的 PORT
        if [[ -z "$webui_port" || "$webui_port" == "<nil>" ]]; then
            webui_port=$(grep -E "^PORT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2)
            [[ -z "$webui_port" ]] && webui_port="5475" # 降级匹配你刚才输入的 5475
        fi
        port_display="${webui_port}"
    else
        # 探测是否有虽然存在但处于停止状态的 Rhex 容器
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


# 部署 Rhex
install_utils() {
    check_dependencies
    mkdir -p "$BASE_DIR/uploads" "$BASE_DIR/addons"
    chmod -R 777 "$BASE_DIR/uploads" "$BASE_DIR/addons"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 数据库部署模式选择 ======${RESET}"
    echo -e "${GREEN}1) 内置常规模式${RESET} (本机自动创建并运行 Postgres 和 Redis 容器)"
    echo -e "${GREEN}2) 远程数据模式${RESET} (连接外部 RDS / 异地独立数据库，本机只跑 Web/Worker)"
    echo -ne "${YELLOW}请选择模式 [默认 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    # 初始化默认连接变量
    local pg_host="postgres"
    local redis_host="redis"
    local pg_user="postgres"
    local pg_pass="postgres"
    local pg_db="bbs"
    local pg_port="5432"
    local redis_pass=""
    local redis_port="6379"
    local redis_db_num="0"
    local use_redis_url_auth="n"

    if [ "$db_mode" = "2" ]; then
        echo -e "\n${CYAN}➜ 请输入远程 PostgreSQL 配置:${RESET}"
        echo -ne "${YELLOW}远程 PG 地址 (Host): ${RESET}"; read -r pg_host
        echo -ne "${YELLOW}远程 PG 端口 (Port) [默认 5432]: ${RESET}"; read -r tmp_port; [[ -n "$tmp_port" ]] && pg_port="$tmp_port"
        echo -ne "${YELLOW}远程 PG 用户 (User) [默认 postgres]: ${RESET}"; read -r tmp_user; [[ -n "$tmp_user" ]] && pg_user="$tmp_user"
        echo -ne "${YELLOW}远程 PG 密码 (Password): ${RESET}"; read -r pg_pass
        echo -ne "${YELLOW}远程 PG 数据库名 (DB Name) [默认 bbs]: ${RESET}"; read -r tmp_db; [[ -n "$tmp_db" ]] && pg_db="$tmp_db"

        echo -e "\n${CYAN}➜ 请输入远程 Redis 配置:${RESET}"
        echo -ne "${YELLOW}远程 Redis 地址 (Host): ${RESET}"; read -r redis_host
        echo -ne "${YELLOW}远程 Redis 端口 (Port) [默认 6379]: ${RESET}"; read -r tmp_rport; [[ -n "$tmp_rport" ]] && redis_port="$tmp_rport"
        echo -ne "${YELLOW}远程 Redis 分库编号 (DB) [默认 0]: ${RESET}"; read -r tmp_rdb; [[ -n "$tmp_rdb" ]] && redis_db_num="$tmp_rdb"
        echo -ne "${YELLOW}远程 Redis 密码 (没有直接回车): ${RESET}"; read -r redis_pass
        
        if [[ -n "$redis_pass" ]]; then
            echo -ne "${YELLOW}是否直接将认证信息写入 REDIS_URL 连接串中？(y/n) [默认 n]: ${RESET}"
            read -r use_redis_url_auth
        fi
    else
        # 内置模式自动生成内置认证
        redis_pass=$(date +%s%N | sha256sum | base64 | head -c 16)
    fi

    # 动态组装 Redis 连接串
    local redis_url_str=""
    if [ "$use_redis_url_auth" = "y" ] || [ "$use_redis_url_auth" = "Y" ]; then
        redis_url_str="redis://:${redis_pass}@${redis_host}:${redis_port}/${redis_db_num}"
    else
        redis_url_str="redis://${redis_host}:${redis_port}"
    fi

    echo -e "\n${CYAN}====== 2. 自定义备份路径设置 ======${RESET}"
    echo -ne "${YELLOW}请输入快照及 Dump 文件的备份绝对路径 [默认: $BASE_DIR/backups]: ${RESET}"
    read -r custom_backup_dir
    [[ -z "$custom_backup_dir" ]] && custom_backup_dir="$BASE_DIR/backups"
    mkdir -p "$custom_backup_dir" && chmod -R 777 "$custom_backup_dir"

    echo -e "\n${CYAN}====== 3. 网络端口与站点配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Rhex 前端访问端口 [默认 3000]: ${RESET}"; read -r custom_port; [[ -z "$custom_port" ]] && custom_port="3000"
    echo -ne "${YELLOW}请输入站点公网 URL (例如 https://bbs.rhex.im, 可选): ${RESET}"; read -r site_url

    echo -e "\n${CYAN}====== 4. 管理员初始化配置 (仅首次生效) ======${RESET}"
    echo -ne "${YELLOW}管理员用户名 [默认 admin]: ${RESET}"; read -r admin_user; [[ -z "$admin_user" ]] && admin_user="admin"
    echo -ne "${YELLOW}管理员密码 [默认 ChangeMe_123456]: ${RESET}"; read -r admin_pass; [[ -z "$admin_pass" ]] && admin_pass="ChangeMe_123456"
    echo -ne "${YELLOW}管理员邮箱 [默认 admin@rhex.im]: ${RESET}"; read -r admin_email; [[ -z "$admin_email" ]] && admin_email="admin@rhex.im"
    echo -ne "${YELLOW}管理员昵称 [默认 秦始皇]: ${RESET}"; read -r admin_nick; [[ -z "$admin_nick" ]] && admin_nick="秦始皇"

    local rand_session=$(date +%s | sha256sum | base64 | head -c 32)
    local rand_captcha=$(date +%s%N | sha256sum | base64 | head -c 32)

    # 写入基础环境配置
    cat <<EOF > "$ENV_FILE"
PORT=${custom_port}
TZ=Asia/Shanghai
PANEL_BACKUP_DIR="${custom_backup_dir}"
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

    # 如果未将认证写入连接串，则作为独立环境变量下发
    if [ "$use_redis_url_auth" != "y" ] && [ "$use_redis_url_auth" != "Y" ]; then
        cat <<EOF >> "$ENV_FILE"
REDIS_PASSWORD="${redis_pass}"
REDIS_DB="${redis_db_num}"
EOF
    else
        cat <<EOF >> "$ENV_FILE"
REDIS_PASSWORD=""
REDIS_DB=""
EOF
    fi

    [[ -n "$site_url" ]] && echo -e "SITE_URL=\"${site_url}\"\nAPP_URL=\"${site_url}\"" >> "$ENV_FILE"

    # 生成 Compose 编排文件
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

  postgres-backup:
    image: postgres:18
    container_name: rhex-backup
    profiles:
      - backup
    restart: "no"
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      POSTGRES_DB: \${POSTGRES_DB:-bbs}
      POSTGRES_USER: \${POSTGRES_USER:-postgres}
      PGPASSWORD: \${POSTGRES_PASSWORD:-postgres}
      TZ: \${TZ:-Asia/Shanghai}
    volumes:
      - ${custom_backup_dir}:/backups
    command:
      - sh
      - -c
      - |
        set -eu
        mkdir -p /backups
        pg_dump -h postgres -U "\$\${POSTGRES_USER:-postgres}" -d "\$\${POSTGRES_DB:-bbs}" -Fc -f "/backups/rhex-\$\$(date +%Y%m%d-%H%M%S).dump"
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

# 复合全量数据备份 (支持自定义目录)
trigger_backup() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then echo -e "${RED}错误: 未部署！${RESET}"; return; fi
    local backup_dir=$(get_backup_dir)
    mkdir -p "$backup_dir"
    
    cd "$BASE_DIR"
    if grep -q "postgres-backup:" "$COMPOSE_FILE"; then
        echo -e "${CYAN}[步骤 1/2] 导出容器内置库 .dump 文件至自定义目录...${RESET}"
        docker compose --profile backup run --rm postgres-backup
    else
        echo -e "${YELLOW}[跳过 1/2] 检测到您使用的是远程库，请在远端平台执行 SQL 备份。${RESET}"
    fi

    echo -e "${CYAN}[步骤 2/2] 打包物理文件归档...${RESET}"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local target_tar="${backup_dir}/rhex-files-${timestamp}.tar.gz"
    
    tar -czf "$target_tar" uploads addons .env docker-compose.yml
    echo -e "${GREEN}全量快照物理打包成功！归档位置: $target_tar${RESET}"
}

# 灾备一键恢复逻辑 (支持自定义目录)
restore_utils() {
    local backup_dir=$(get_backup_dir)
    if [[ ! -d "$backup_dir" ]]; then
        echo -e "${RED}错误: 未检测到备份路径 $backup_dir${RESET}"
        return
    fi
    clear
    echo -e "${CYAN}====== 📥 Rhex 灾备一键快照恢复面板 ======${RESET}"
    echo -e "${YELLOW}当前备份路径: ${backup_dir}${RESET}"
    echo -e "----------------------------------------------------"
    
    local files=($(ls "$backup_dir" 2>/dev/null | grep -E "rhex-files-.*\.tar\.gz"))
    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}未在指定路径找到符合格式的 rhex-files-*.tar.gz 快照！${RESET}"
        return
    fi

    for i in "${!files[@]}"; do
        echo -e "${GREEN}[$i]${RESET} ${files[$i]}"
    done
    echo -e "----------------------------------------------------"
    echo -ne "${YELLOW}请选择要恢复的物理快照编号: ${RESET}"
    read -r file_idx

    if [[ -z "$file_idx" || ! "$file_idx" =~ ^[0-9]+$ || $file_idx -ge ${#files[@]} ]]; then
        echo -e "${RED}无效选择，恢复终止。${RESET}"
        return
    fi

    local target_file="${backup_dir}/${files[$file_idx]}"
    echo -e "${RED}警告: 恢复过程会清理当前目录并回填所选快照的所有物理资产！${RESET}"
    echo -ne "${YELLOW}确认要继续执行回填恢复吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then return; fi

    echo -e "${YELLOW}正在停止现有集群...${RESET}"
    cd "$BASE_DIR" && docker compose down 2>/dev/null

    echo -e "${YELLOW}正在解压回填物理资产包...${RESET}"
    tar -xzf "$target_file" -C "$BASE_DIR/"
    
    echo -e "${YELLOW}正在重新拉起集群并同步数据库迁移...${RESET}"
    docker compose up -d --force-recreate
    echo -e "${GREEN}🌟 快照数据灾备恢复成功！${RESET}"
}

update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then echo -e "${RED}错误: 未部署！${RESET}"; return; fi
    cd "$BASE_DIR" && docker compose pull && docker compose up -d --remove-orphans
    echo -e "${GREEN}升级完成！${RESET}"
}

uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并彻底删除本地数据吗？(y/n): ${RESET}"; read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        cd "$BASE_DIR" && docker compose down -v 2>/dev/null; rm -rf "$BASE_DIR"; echo -e "${GREEN}卸载完成。${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}已激活${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}已挂起${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}已重启${RESET}"; }
logs_utils() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    local backup_dir=$(get_backup_dir)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}Web端运行状态    : $status"
    echo -e "${YELLOW}当前前端活动端口 : ${port_display}${RESET}"
    echo -e "${YELLOW}当前设定的备份集 : ${backup_dir}${RESET}"
    echo -e "--------------------------------"
    docker ps --format "table {{.Names}}\t{{.Status}}" | grep "rhex"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}     ◈  Rhex 论坛管理面板 ◈       ${RESET}"
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
        7) logs_utils ;;
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
