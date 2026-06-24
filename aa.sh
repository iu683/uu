#!/bin/bash
# =================================================================
# Twilight 管理面板
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/twilight"
SRC_DIR="$BASE_DIR/Twilight"
REPO_URL="https://github.com/Prejudice-Studio/Twilight.git"

# 检测基础依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! command -v git &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Git，请先安装 Git！${RESET}"
        exit 1
    fi
}

# 获取集群状态
get_status_info() {
    if [ -d "$SRC_DIR" ]; then
        local running_count=$(docker ps -q -f "name=twilight-" | wc -l)
        if [ "$running_count" -ge 1 ]; then
            status="${GREEN}运行中 (已拉起 $running_count 个容器)${RESET}"
        else
            status="${RED}已停止${RESET}"
        fi
        
        if [ -f "$SRC_DIR/.env" ]; then
            web_port=$(grep "WEBUI_PORT=" "$SRC_DIR/.env" 2>/dev/null | cut -d'=' -f2)
            [[ -z "$web_port" ]] && web_port="3000"
        else
            web_port="3000"
        fi
    else
        status="${RED}未部署${RESET}"
        web_port="N/A"
    fi
}

# 动态分析组件形态
get_env_summary() {
    if [ -f "$SRC_DIR/docker-compose.yml" ]; then
        local has_pg=$(grep "container_name: twilight-postgres" "$SRC_DIR/docker-compose.yml")
        local has_rds=$(grep "container_name: twilight-redis" "$SRC_DIR/docker-compose.yml")
        
        if [[ -n "$has_pg" ]]; then pg_info="${GREEN}内置容器${RESET}"; else pg_info="${YELLOW}外部托管${RESET}"; fi
        if [[ -n "$has_rds" ]]; then rds_info="${GREEN}内置容器${RESET}"; else rds_info="${YELLOW}外部托管${RESET}"; fi
    else
        pg_info="${RED}未部署${RESET}"
        rds_info="${RED}未部署${RESET}"
    fi
    echo -e "PostgreSQL: $pg_info | Redis: $rds_info"
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

# 1. 部署启动
install_twilight() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 前端基础配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Twilight 前端网络访问端口 [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"

    echo -ne "${YELLOW}请输入初始超级管理员用户名 (首位注册以此为准) [默认: admin]: ${RESET}"
    read -r admin_user
    [[ -z "$admin_user" ]] && admin_user="admin"

    echo -ne "${YELLOW}请输入 Bot 内部通讯密钥 (建议随机长字符串) [默认: secret_twilight_666]: ${RESET}"
    read -r bot_secret
    [[ -z "$bot_secret" ]] && bot_secret="secret_twilight_666"

    # PostgreSQL 路由分配
    echo -e "\n${CYAN}====== 2. PostgreSQL 数据库配置 ======${RESET}"
    echo -e "${YELLOW}请选择 PostgreSQL 架构类型:${RESET}"
    echo -e "  ${CYAN}1.${RESET} 使用集群自带内置 PostgreSQL 容器 (全自动)"
    echo -e "  ${CYAN}2.${RESET} 使用外部独立/远程 PostgreSQL 数据库"
    echo -ne "${YELLOW}请选择 (1-2) [默认: 1]: ${RESET}"
    read -r pg_choice

    local use_builtin_pg="true"
    local fin_pg_host="postgres"
    local fin_pg_port="5432"
    local fin_pg_user="twilight"
    local fin_pg_pass="twilight_pass_999"
    local fin_pg_db="twilight"

    if [[ "$pg_choice" == "2" ]]; then
        use_builtin_pg="false"
        echo -e "\n${CYAN}--- 远程 PostgreSQL 数据库连接凭证 ---${RESET}"
        echo -ne "${YELLOW}请输入远程 PostgreSQL 主机 IP/域名: ${RESET}"
        read -r remote_pg_host
        while [[ -z "$remote_pg_host" ]]; do echo -ne "${RED}不能为空: ${RESET}"; read -r remote_pg_host; done
        
        echo -ne "${YELLOW}请输入远程 PostgreSQL 端口 [默认: 5432]: ${RESET}"
        read -r remote_pg_port
        [[ -z "$remote_pg_port" ]] && remote_pg_port="5432"

        echo -ne "${YELLOW}请输入远程 PostgreSQL 用户名 [默认: twilight]: ${RESET}"
        read -r remote_pg_user
        [[ -z "$remote_pg_user" ]] && remote_pg_user="twilight"

        echo -ne "${YELLOW}请输入远程 PostgreSQL 密码: ${RESET}"
        read -r remote_pg_pass
        while [[ -z "$remote_pg_pass" ]]; do echo -ne "${RED}不能为空: ${RESET}"; read -r remote_pg_pass; done

        echo -ne "${YELLOW}请输入远程 PostgreSQL 数据库名 [默认: twilight]: ${RESET}"
        read -r remote_pg_db
        [[ -z "$remote_pg_db" ]] && remote_pg_db="twilight"

        fin_pg_host="$remote_pg_host"
        fin_pg_port="$remote_pg_port"
        fin_pg_user="$remote_pg_user"
        fin_pg_pass="$remote_pg_pass"
        fin_pg_db="$remote_pg_db"
    fi

    # Redis 路由分配
    echo -e "\n${CYAN}====== 3. Redis 缓存配置 ======${RESET}"
    echo -e "${YELLOW}请选择 Redis 缓存架构类型:${RESET}"
    echo -e "  ${CYAN}1.${RESET} 使用集群自带内置 Redis 容器 (全自动)"
    echo -e "  ${CYAN}2.${RESET} 使用外部独立/远程 Redis 缓存服务器"
    echo -ne "${YELLOW}请选择 (1-2) [默认: 1]: ${RESET}"
    read -r redis_choice

    local use_builtin_redis="true"
    local fin_redis_url="redis://redis:6379/0"
    local fin_redis_db="0"

    if [[ "$redis_choice" == "2" ]]; then
        use_builtin_redis="false"
        echo -e "\n${CYAN}--- 远程 Redis 缓存连接凭证 ---${RESET}"
        echo -ne "${YELLOW}请输入远程 Redis 主机 IP/域名: ${RESET}"
        read -r remote_redis_host
        while [[ -z "$remote_redis_host" ]]; do echo -ne "${RED}不能为空: ${RESET}"; read -r remote_redis_host; done

        echo -ne "${YELLOW}请输入远程 Redis 端口 [默认: 6379]: ${RESET}"
        read -r remote_redis_port
        [[ -z "$remote_redis_port" ]] && remote_redis_port="6379"

        echo -ne "${YELLOW}请输入远程 Redis 认证密码 (无密码直接回车): ${RESET}"
        read -r remote_redis_pass

        echo -ne "${YELLOW}请输入预备分配的 Redis 分区/DB ID (0-15) [默认: 0]: ${RESET}"
        read -r remote_redis_db
        [[ -z "$remote_redis_db" ]] && remote_redis_db="0"
        fin_redis_db="$remote_redis_db"

        if [[ -z "$remote_redis_pass" ]]; then
            fin_redis_url="redis://${remote_redis_host}:${remote_redis_port}/${remote_redis_db}"
        else
            fin_redis_url="redis://:${remote_redis_pass}@${remote_redis_host}:${remote_redis_port}/${remote_redis_db}"
        fi
    else
        echo -ne "${YELLOW}请输入内置 Redis 分区/DB ID (0-15) [默认: 0]: ${RESET}"
        read -r builtin_redis_db
        [[ -z "$builtin_redis_db" ]] && builtin_redis_db="0"
        fin_redis_db="$builtin_redis_db"
        fin_redis_url="redis://redis:6379/${builtin_redis_db}"
    fi

    # Emby 核心对接
    echo -e "\n${CYAN}====== 4. Emby 服务器业务对接 ======${RESET}"
    echo -ne "${YELLOW}请输入您的 Emby 服务器地址 (如 http://127.0.0.1:8096): ${RESET}"
    read -r emby_url
    while [[ -z "$emby_url" ]]; do echo -ne "${RED}不能为空，请重新输入: ${RESET}"; read -r emby_url; done

    echo -ne "${YELLOW}请输入您的 Emby API Token: ${RESET}"
    read -r emby_token
    while [[ -z "$emby_token" ]]; do echo -ne "${RED}不能为空，请重新输入: ${RESET}"; read -r emby_token; done

    # 拉取或同步源码
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "\n${YELLOW}正在克隆 Twilight 官方 GitHub 源码仓库...${RESET}"
        git clone "$REPO_URL" "$SRC_DIR"
        if [ $? -ne 0 ]; then echo -e "${RED}错误: 克隆失败，请检查网络！${RESET}"; exit 1; fi
    else
        echo -e "\n${GREEN}本地已存在源码，正在同步 Git 分支...${RESET}"
        cd "$SRC_DIR" && git pull
    fi

    cd "$SRC_DIR" || exit

    # 格式化 config.toml
    echo -e "${YELLOW}正在注入配置文件 config.toml ...${RESET}"
    cp deploy/docker/config.docker.toml config.toml
    
    sed -i "s|emby_url = \"http://your-emby-server:8096\"|emby_url = \"${emby_url}\"|g" config.toml
    sed -i "s|emby_token = \"\"|emby_token = \"${emby_token}\"|g" config.toml
    sed -i "s|redis_url = \"redis://redis:6379/0\"|redis_url = \"${fin_redis_url}\"|g" config.toml
    
    sed -i "s|postgres_host = \"postgres\"|postgres_host = \"${fin_pg_host}\"|g" config.toml
    sed -i "s|postgres_port = 5432|postgres_port = ${fin_pg_port}|g" config.toml
    sed -i "s|postgres_user = \"twilight\"|postgres_user = \"${fin_pg_user}\"|g" config.toml
    sed -i "s|postgres_password = \"twilight\"|postgres_password = \"${fin_pg_pass}\"|g" config.toml
    sed -i "s|postgres_database = \"twilight\"|postgres_database = \"${fin_pg_db}\"|g" config.toml

    # 释放前端基址
    cp webui/.env.example webui/.env

    # 组装宿主机全局 .env
    cat <<EOF > .env
TZ=Asia/Shanghai
WEBUI_PORT=${custom_port}
BACKEND_URL=http://twilight:5000
POSTGRES_PASSWORD=${fin_pg_pass}
BOT_INTERNAL_SECRET=${bot_secret}
ADMIN_USERNAMES=${admin_user}
SITE_NAME=Twilight
LOG_LEVEL=info
RUNTIME_LOG_LIMIT=5000
EOF

    # 重组解耦型 docker-compose.yml
    cat <<EOF > docker-compose.yml
name: twilight

x-service-defaults: &service-defaults
  init: true
  stop_grace_period: 30s
  security_opt:
    - no-new-privileges:true
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"

services:
EOF

    if [[ "$use_builtin_pg" == "true" ]]; then
        cat <<EOF >> docker-compose.yml
  postgres:
    <<: *service-defaults
    image: postgres:17-alpine
    container_name: twilight-postgres
    restart: unless-stopped
    environment:
      TZ: \${TZ:-Asia/Shanghai}
      POSTGRES_USER: twilight
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:-twilight}
      POSTGRES_DB: twilight
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./deploy/docker/init-db.sql:/docker-entrypoint-initdb.d/01-init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U twilight"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s
    networks:
      - twilight-net
EOF
    fi

    if [[ "$use_builtin_redis" == "true" ]]; then
        cat <<EOF >> docker-compose.yml
  redis:
    <<: *service-defaults
    image: redis:7-alpine
    container_name: twilight-redis
    restart: unless-stopped
    command: redis-server --appendonly yes --maxmemory 128mb --maxmemory-policy allkeys-lru
    environment:
      TZ: \${TZ:-Asia/Shanghai}
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - twilight-net
EOF
    fi

    cat <<EOF >> docker-compose.yml
  twilight:
    <<: *service-defaults
    build:
      context: .
      dockerfile: Dockerfile
    image: twilight-backend:latest
    container_name: twilight-backend
    restart: unless-stopped
EOF

    if [[ "$use_builtin_pg" == "true" || "$use_builtin_redis" == "true" ]]; then
        echo "    depends_on:" >> docker-compose.yml
        [[ "$use_builtin_pg" == "true" ]] && echo -e "      postgres:\n        condition: service_healthy" >> docker-compose.yml
        [[ "$use_builtin_redis" == "true" ]] && echo -e "      redis:\n        condition: service_healthy" >> docker-compose.yml
    fi

    cat <<EOF >> docker-compose.yml
    environment:
      TZ: \${TZ:-Asia/Shanghai}
      TWILIGHT_GLOBAL_SERVER_NAME: \${SITE_NAME:-Twilight}
      TWILIGHT_LOG_LEVEL: \${LOG_LEVEL:-info}
      TWILIGHT_RUNTIME_LOG_LIMIT: \${RUNTIME_LOG_LIMIT:-5000}
      TWILIGHT_DATABASE_DRIVER: postgres
      TWILIGHT_POSTGRES_HOST: ${fin_pg_host}
      TWILIGHT_POSTGRES_PORT: ${fin_pg_port}
      TWILIGHT_POSTGRES_USER: ${fin_pg_user}
      TWILIGHT_POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      TWILIGHT_POSTGRES_DATABASE: ${fin_pg_db}
      TWILIGHT_POSTGRES_SSLMODE: disable
      TWILIGHT_REDIS_URL: ${fin_redis_url}
      TWILIGHT_API_HOST: 0.0.0.0
      TWILIGHT_API_PORT: 5000
      TWILIGHT_ADMIN_USERNAMES: \${ADMIN_USERNAMES:-admin}
      TWILIGHT_BOT_INTERNAL_SECRET: \${BOT_INTERNAL_SECRET:-}
    env_file:
      - path: .env
        required: false
    volumes:
      - ./config.toml:/app/config.toml:ro
      - twilight_uploads:/app/uploads
      - twilight_backups:/app/db/backups
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:5000/api/v1/system/health >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    networks:
      - twilight-net

  webui:
    <<: *service-defaults
    build:
      context: ./webui
      dockerfile: Dockerfile
    image: twilight-webui:latest
    container_name: twilight-webui
    restart: unless-stopped
    depends_on:
      twilight:
        condition: service_healthy
    environment:
      TZ: \${TZ:-Asia/Shanghai}
      NODE_ENV: production
      PORT: 3000
      BACKEND_URL: \${BACKEND_URL:-http://twilight:5000}
    env_file:
      - path: webui/.env
        required: false
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://localhost:3000').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]
    interval: 30s
    timeout: 5s
    retries: 3
    start_period: 15s
    networks:
      - twilight-net
    ports:
      - "\${WEBUI_PORT:-3000}:3000"

networks:
  twilight-net:
    driver: bridge
    name: twilight-net

volumes:
  twilight_uploads:
    name: twilight-uploads
  twilight_backups:
    name: twilight-backups
EOF

    [[ "$use_builtin_pg" == "true" ]] && echo -e "  postgres_data:\n    name: twilight-postgres-data" >> docker-compose.yml
    [[ "$use_builtin_redis" == "true" ]] && echo -e "  redis_data:\n    name: twilight-redis-data" >> docker-compose.yml

    echo -e "\n${YELLOW}正在编译并拉起容器生态集群 (Next.js 首次编译较慢)...${RESET}"
    docker compose up -d --build

    echo -e "${YELLOW}正在建立生命周期健康检查...${RESET}"
    sleep 10

    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}       Twilight 混合动力集群部署成功！               ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}前端访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}当前数据库源 : PostgreSQL -> ${fin_pg_host}:${fin_pg_port}${RESET}"
    echo -e "${YELLOW}当前缓存源   : Redis -> ${fin_redis_url} (分区 ${fin_redis_db})${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${CYAN}🔑 首次激活指引：${RESET}"
    echo -e "   1. 浏览器打开上面的网页，点击注册。"
    echo -e "   2. 注册时填写的用户名【必须】是: ${GREEN}${admin_user}${RESET}"
    echo -e "   3. 注册成功即刻自动切入超级管理员面板权限！"
    echo -e "${GREEN}====================================================${RESET}"
}

# 2. 更新容器
update_twilight() {
    if [ -d "$SRC_DIR/.git" ]; then
        echo -e "${YELLOW}正在从官方 GitHub 同步最新源码...${RESET}"
        cd "$SRC_DIR" && git pull
        echo -e "${YELLOW}正在无损无缓存重新编译并滚屏更新集群容器...${RESET}"
        docker compose up -d --build
        echo -e "${GREEN}集群镜像已成功热升级！${RESET}"
    else
        echo -e "${RED}未检测到部署目录，无法执行更新。${RESET}"
    fi
}

# 3. 卸载容器
uninstall_twilight() {
    echo -ne "${RED}确定要全面停止并清除 Twilight 容器集群吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        if [ -d "$SRC_DIR" ]; then
            cd "$SRC_DIR" && docker compose down
            echo -ne "${YELLOW}是否连同【本地源码、历史卡密、切片及本地持久化卷】全盘删除？(y/n): ${RESET}"
            read -r clean_data
            if [[ "$clean_data" == "y" || "$clean_data" == "Y" ]]; then
                docker volume rm twilight-postgres-data twilight-redis-data twilight-uploads twilight-backups 2>/dev/null
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}所有物理数据已安全抹除清空。${RESET}"
            fi
        else
            echo -e "${YELLOW}未检测到有效目录，跳过删除。${RESET}"
        fi
    fi
}

# 4. 启动容器
start_twilight() { cd "$SRC_DIR" && docker compose start && echo -e "${GREEN}集群已全面启动运转${RESET}"; }

# 5. 停止容器
stop_twilight() { cd "$SRC_DIR" && docker compose stop && echo -e "${YELLOW}集群已安全停止响应${RESET}"; }

# 6. 重启容器
restart_twilight() { cd "$SRC_DIR" && docker compose restart && echo -e "${GREEN}集群已完成平滑重载${RESET}"; }

# 7. 查看日志
logs_twilight() { cd "$SRC_DIR" && docker compose logs -f --tail=100; }

# 8. 查看配置
show_config() {
    if [ -f "$SRC_DIR/.env" ]; then
        echo -e "${CYAN}--- 当前宿主机 .env 变量架构 ---${RESET}"
        cat "$SRC_DIR/.env"
        echo -e "${CYAN}--------------------------------${RESET}"
    else
        echo -e "${RED}未检测到有效的部署变量文件。${RESET}"
    fi
}

# 主菜单路由
menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}       ◈ Twilight 管理面板 ◈       ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}集群状态 :${RESET} $status"
    echo -e "${GREEN}前端端口 :${RESET} ${YELLOW}${web_port}${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -ne "${GREEN}请输入您的选择: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_twilight ;;
        2) update_twilight ;;
        3) uninstall_twilight ;;
        4) start_twilight ;;
        5) stop_twilight ;;
        6) restart_twilight ;;
        7) logs_twilight ;;
        8) show_config ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效，请重新核对！${RESET}" ;;
    esac
}

while true; do
  menu
  echo -ne "${YELLOW}\n按回车键返回主菜单...${RESET}"
  read -r
done
