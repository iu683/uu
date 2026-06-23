#!/bin/bash
# =================================================================
# Sub2API 服务 Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="sub2api"
BASE_DIR="/opt/sub2api"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口和环境信息
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        server_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$server_port" ]] && server_port="8080"
    else
        img_version="${RED}未安装${RESET}"
        server_port="N/A"
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

# 部署 Sub2API
install_sub2api() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== Sub2API 核心参数配置 ======${RESET}"
    
    # 1. 端口配置
    echo -ne "${YELLOW}请输入 Sub2API 映射端口 [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"

    # 2. PostgreSQL 数据库路由配置
    echo -e "${CYAN}------------------------------------------------------------${RESET}"
    echo -e "${YELLOW}请选择 PostgreSQL 数据库部署模式:${RESET}"
    echo -e "  1) 创建并连接本地 Docker 容器数据库 (推荐新用户)"
    echo -e "  2) 对接已有的外置/远程 PostgreSQL 数据库"
    echo -ne "${GREEN}请选择 [默认: 1]: ${RESET}"
    read -r db_choice
    [[ -z "$db_choice" ]] && db_choice="1"

    if [[ "$db_choice" == "2" ]]; then
        use_local_db="false"
        echo -ne "${YELLOW}请输入远程 PostgreSQL 数据库 IP/域名: ${RESET}"
        read -r db_host
        echo -ne "${YELLOW}请输入远程 PostgreSQL 端口 [默认: 5432]: ${RESET}"
        read -r db_port
        [[ -z "$db_port" ]] && db_port="5432"
        echo -ne "${YELLOW}请输入远程 PostgreSQL 用户名 [默认: sub2api]: ${RESET}"
        read -r db_user
        [[ -z "$db_user" ]] && db_user="sub2api"
        echo -ne "${YELLOW}请输入远程 PostgreSQL 密码: ${RESET}"
        read -r db_pass
        while [[ -z "$db_pass" ]]; do
            echo -e "${RED}错误: 远程数据库密码不能为空！${RESET}"
            echo -ne "${YELLOW}请输入远程 PostgreSQL 密码: ${RESET}"
            read -r db_pass
        done
        echo -ne "${YELLOW}请输入远程 PostgreSQL 数据库名 [默认: sub2api]: ${RESET}"
        read -r db_name
        [[ -z "$db_name" ]] && db_name="sub2api"
    else
        use_local_db="true"
        db_host="postgres"
        db_port="5432"
        db_user="sub2api"
        db_name="sub2api"
        default_db_pass=$(date +%s%N | md5sum | head -c 16)
        echo -ne "${YELLOW}请设置本地 PostgreSQL 数据库密码 [默认随机: $default_db_pass]: ${RESET}"
        read -r db_pass
        [[ -z "$db_pass" ]] && db_pass="$default_db_pass"
    fi

    # 3. Redis 路由与分区编号配置
    echo -e "${CYAN}------------------------------------------------------------${RESET}"
    echo -e "${YELLOW}请选择 Redis 缓存部署模式:${RESET}"
    echo -e "  1) 创建并连接本地 Docker 容器 Redis"
    echo -e "  2) 对接已有的外置/远程 Redis 缓存服务器"
    echo -ne "${GREEN}请选择 [默认: 1]: ${RESET}"
    read -r redis_choice
    [[ -z "$redis_choice" ]] && redis_choice="1"

    # 提取 Redis 分区编号配置（不论本地远程均适用）
    echo -ne "${YELLOW}请输入要使用的 Redis 数据库分区编号 (DB Index 0-15) [默认: 0]: ${RESET}"
    read -r redis_db_index
    if ! [[ "$redis_db_index" =~ ^[0-9]+$ ]] || [ "$redis_db_index" -lt 0 ] || [ "$redis_db_index" -gt 15 ]; then
        echo -e "${RED}警告: 输入无效，已强制回退到默认分区: 0${RESET}"
        redis_db_index="0"
    fi

    if [[ "$redis_choice" == "2" ]]; then
        use_local_redis="false"
        echo -ne "${YELLOW}请输入远程 Redis IP/域名: ${RESET}"
        read -r redis_host
        echo -ne "${YELLOW}请输入远程 Redis 端口 [默认: 6379]: ${RESET}"
        read -r redis_port
        [[ -z "$redis_port" ]] && redis_port="6379"
        echo -ne "${YELLOW}请输入远程 Redis 密码 (若无密码请直接回车): ${RESET}"
        read -r redis_pass
    else
        use_local_redis="true"
        redis_host="redis"
        redis_port="6379"
        default_redis_pass=$(date +%s%N | md5sum | head -c 12)
        echo -ne "${YELLOW}请设置本地 Redis 密码 [默认随机: $default_redis_pass]: ${RESET}"
        read -r redis_pass
        [[ -z "$redis_pass" ]] && redis_pass="$default_redis_pass"
    fi

    # 4. 管理员配置
    echo -e "${CYAN}------------------------------------------------------------${RESET}"
    echo -ne "${YELLOW}请输入管理员邮箱 [默认: admin@sub2api.local]: ${RESET}"
    read -r admin_email
    [[ -z "$admin_email" ]] && admin_email="admin@sub2api.local"

    default_admin_pass=$(date +%s%N | sha256sum | head -c 12)
    echo -ne "${YELLOW}请设置管理员密码 [默认随机: $default_admin_pass]: ${RESET}"
    read -r admin_pass
    [[ -z "$admin_pass" ]] && admin_pass="$default_admin_pass"

    # 5. 安全密钥自动生成
    if command -v openssl &> /dev/null; then
        jwt_secret=$(openssl rand -hex 32)
        totp_key=$(openssl rand -hex 32)
    else
        jwt_secret=$(date +%s%N | sha256sum | head -c 64)
        totp_key=$(date +%s%N | sha256sum | head -c 64)
    fi

    echo -e "${YELLOW}正在生成宿主机持久化目录...${RESET}"
    mkdir -p "$BASE_DIR/data"
    [[ "$use_local_db" == "true" ]] && mkdir -p "$BASE_DIR/postgres_data"
    [[ "$use_local_redis" == "true" ]] && mkdir -p "$BASE_DIR/redis_data"
    chmod -R 777 "$BASE_DIR"

    # 6. 动态生成 .env 配置文件
    echo -e "${YELLOW}正在写入符合官方规范的 .env 环境配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
BIND_HOST=0.0.0.0
SERVER_PORT=${custom_port}
SERVER_MODE=release

LOG_LEVEL=info
LOG_FORMAT=json
LOG_SERVICE_NAME=sub2api
LOG_ENV=production
LOG_CALLER=true
LOG_STACKTRACE_LEVEL=error
LOG_OUTPUT_TO_STDOUT=true
LOG_OUTPUT_TO_FILE=true
LOG_OUTPUT_FILE_PATH=
LOG_ROTATION_MAX_SIZE_MB=100
LOG_ROTATION_MAX_BACKUPS=10
LOG_ROTATION_MAX_AGE_DAYS=7
LOG_ROTATION_COMPRESS=true
LOG_ROTATION_LOCAL_TIME=true
LOG_SAMPLING_ENABLED=false
LOG_SAMPLING_INITIAL=100
LOG_SAMPLING_THEREAFTER=100

SERVER_MAX_REQUEST_BODY_SIZE=268435456
GATEWAY_MAX_BODY_SIZE=268435456
SERVER_H2C_ENABLED=true
SERVER_H2C_MAX_CONCURRENT_STREAMS=50
SERVER_H2C_IDLE_TIMEOUT=75
SERVER_H2C_MAX_READ_FRAME_SIZE=1048576
SERVER_H2C_MAX_UPLOAD_BUFFER_PER_CONNECTION=2097152
SERVER_H2C_MAX_UPLOAD_BUFFER_PER_STREAM=524288

RUN_MODE=standard
TZ=Asia/Shanghai

POSTGRES_USER=${db_user}
POSTGRES_PASSWORD=${db_pass}
POSTGRES_DB=${db_name}
DATABASE_PORT=${db_port}
POSTGRES_MAX_CONNECTIONS=1024
POSTGRES_SHARED_BUFFERS=1GB
POSTGRES_EFFECTIVE_CACHE_SIZE=4GB
POSTGRES_MAINTENANCE_WORK_MEM=128MB
DATABASE_MAX_OPEN_CONNS=256
DATABASE_MAX_IDLE_CONNS=128
DATABASE_CONN_MAX_LIFETIME_MINUTES=30
DATABASE_CONN_MAX_IDLE_TIME_MINUTES=5

REDIS_PORT=${redis_port}
REDIS_PASSWORD=${redis_pass}
REDIS_DB=${redis_db_index}
REDIS_MAXCLIENTS=50000
REDIS_POOL_SIZE=4096
REDIS_MIN_IDLE_CONNS=256
REDIS_ENABLE_TLS=false

ADMIN_EMAIL=${admin_email}
ADMIN_PASSWORD=${admin_pass}

JWT_SECRET=${jwt_secret}
JWT_EXPIRE_HOUR=24
JWT_ACCESS_TOKEN_EXPIRE_MINUTES=0
TOTP_ENCRYPTION_KEY=${totp_key}

RATE_LIMIT_OVERLOAD_COOLDOWN_MINUTES=10
GATEWAY_FORCE_CODEX_CLI=false
GATEWAY_OPENAI_RESPONSE_HEADER_TIMEOUT=0
GATEWAY_OPENAI_HTTP2_ENABLED=true
GATEWAY_OPENAI_HTTP2_ALLOW_PROXY_FALLBACK_TO_HTTP1=true
GATEWAY_OPENAI_HTTP2_FALLBACK_ERROR_THRESHOLD=2
GATEWAY_OPENAI_HTTP2_FALLBACK_WINDOW_SECONDS=60
GATEWAY_OPENAI_HTTP2_FALLBACK_TTL_SECONDS=600
GATEWAY_MAX_CONNS_PER_HOST=2048
GATEWAY_MAX_IDLE_CONNS=8192
GATEWAY_MAX_IDLE_CONNS_PER_HOST=4096
GATEWAY_SCHEDULING_STICKY_SESSION_MAX_WAITING=3
GATEWAY_SCHEDULING_STICKY_SESSION_WAIT_TIMEOUT=120s
GATEWAY_SCHEDULING_FALLBACK_WAIT_TIMEOUT=30s
GATEWAY_SCHEDULING_FALLBACK_MAX_WAITING=100
GATEWAY_SCHEDULING_LOAD_BATCH_ENABLED=true
GATEWAY_SCHEDULING_SLOT_CLEANUP_INTERVAL=30s
GATEWAY_SCHEDULING_DB_FALLBACK_ENABLED=true
GATEWAY_SCHEDULING_DB_FALLBACK_TIMEOUT_SECONDS=0
GATEWAY_SCHEDULING_DB_FALLBACK_MAX_QPS=0
GATEWAY_SCHEDULING_OUTBOX_POLL_INTERVAL_SECONDS=1
GATEWAY_SCHEDULING_OUTBOX_LAG_WARN_SECONDS=5
GATEWAY_SCHEDULING_OUTBOX_LAG_REBUILD_SECONDS=10
GATEWAY_SCHEDULING_OUTBOX_LAG_REBUILD_FAILURES=3
GATEWAY_SCHEDULING_OUTBOX_BACKLOG_REBUILD_ROWS=10000
GATEWAY_SCHEDULING_FULL_REBUILD_INTERVAL_SECONDS=300

GATEWAY_IMAGE_STREAM_DATA_INTERVAL_TIMEOUT=900
GATEWAY_IMAGE_STREAM_KEEPALIVE_INTERVAL=10
GATEWAY_IMAGE_CONCURRENCY_ENABLED=false
GATEWAY_IMAGE_CONCURRENCY_MAX_CONCURRENT_REQUESTS=0
GATEWAY_IMAGE_CONCURRENCY_OVERFLOW_MODE=reject
GATEWAY_IMAGE_CONCURRENCY_WAIT_TIMEOUT_SECONDS=30
GATEWAY_IMAGE_CONCURRENCY_MAX_WAITING_REQUESTS=100

DASHBOARD_AGGREGATION_ENABLED=true
DASHBOARD_AGGREGATION_INTERVAL_SECONDS=60
DASHBOARD_AGGREGATION_LOOKBACK_SECONDS=120
DASHBOARD_AGGREGATION_BACKFILL_ENABLED=false
DASHBOARD_AGGREGATION_BACKFILL_MAX_DAYS=31
DASHBOARD_AGGREGATION_RECOMPUTE_DAYS=2
DASHBOARD_AGGREGATION_RETENTION_USAGE_LOGS_DAYS=90
DASHBOARD_AGGREGATION_RETENTION_HOURLY_DAYS=180
DASHBOARD_AGGREGATION_RETENTION_DAILY_DAYS=730

SECURITY_URL_ALLOWLIST_ENABLED=false
SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP=true
SECURITY_URL_ALLOWLIST_ALLOW_PRIVATE_HOSTS=true

GEMINI_OAUTH_CLIENT_ID=
GEMINI_OAUTH_CLIENT_SECRET=
GEMINI_OAUTH_SCOPES=
GEMINI_QUOTA_POLICY=
OPS_ENABLED=true
UPDATE_PROXY_URL=
EOF

    # 7. 动态裁切并生成 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在动态编排符合您硬件拓扑的 docker-compose.yml...${RESET}"
    
    # 基础的主程序配置
    cat <<EOF > "$COMPOSE_FILE"
services:
  sub2api:
    image: weishaw/sub2api:latest
    container_name: sub2api
    restart: unless-stopped
    ulimits:
      nofile:
        soft: 100000
        hard: 100000
    ports:
      - "\${BIND_HOST:-0.0.0.0}:\${SERVER_PORT:-8080}:8080"
    volumes:
      - ./data:/app/data:Z
    environment:
      - AUTO_SETUP=true
      - SERVER_HOST=0.0.0.0
      - SERVER_PORT=8080
      - SERVER_MODE=\${SERVER_MODE:-release}
      - RUN_MODE=\${RUN_MODE:-standard}
      - DATABASE_HOST=${db_host}
      - DATABASE_PORT=\${DATABASE_PORT:-5432}
      - DATABASE_USER=\${POSTGRES_USER:-sub2api}
      - DATABASE_PASSWORD=\${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}
      - DATABASE_DBNAME=\${POSTGRES_DB:-sub2api}
      - DATABASE_SSLMODE=disable
      - DATABASE_MAX_OPEN_CONNS=\${DATABASE_MAX_OPEN_CONNS:-50}
      - DATABASE_MAX_IDLE_CONNS=\${DATABASE_MAX_IDLE_CONNS:-10}
      - DATABASE_CONN_MAX_LIFETIME_MINUTES=\${DATABASE_CONN_MAX_LIFETIME_MINUTES:-30}
      - DATABASE_CONN_MAX_IDLE_TIME_MINUTES=\${DATABASE_CONN_MAX_IDLE_TIME_MINUTES:-5}
      - REDIS_HOST=${redis_host}
      - REDIS_PORT=\${REDIS_PORT:-6379}
      - REDIS_PASSWORD=\${REDIS_PASSWORD:-}
      - REDIS_DB=\${REDIS_DB:-0}
      - REDIS_POOL_SIZE=\${REDIS_POOL_SIZE:-1024}
      - REDIS_MIN_IDLE_CONNS=\${REDIS_MIN_IDLE_CONNS:-10}
      - REDIS_ENABLE_TLS=\${REDIS_ENABLE_TLS:-false}
      - ADMIN_EMAIL=\${ADMIN_EMAIL:-admin@sub2api.local}
      - ADMIN_PASSWORD=\${ADMIN_PASSWORD:-}
      - JWT_SECRET=\${JWT_SECRET:-}
      - JWT_EXPIRE_HOUR=\${JWT_EXPIRE_HOUR:-24}
      - TOTP_ENCRYPTION_KEY=\${TOTP_ENCRYPTION_KEY:-}
      - TZ=\${TZ:-Asia/Shanghai}
      - GEMINI_OAUTH_CLIENT_ID=\${GEMINI_OAUTH_CLIENT_ID:-}
      - GEMINI_OAUTH_CLIENT_SECRET=\${GEMINI_OAUTH_CLIENT_SECRET:-}
      - GEMINI_OAUTH_SCOPES=\${GEMINI_OAUTH_SCOPES:-}
      - GEMINI_QUOTA_POLICY=\${GEMINI_QUOTA_POLICY:-}
      - GEMINI_CLI_OAUTH_CLIENT_SECRET=\${GEMINI_CLI_OAUTH_CLIENT_SECRET:-}
      - ANTIGRAVITY_OAUTH_CLIENT_SECRET=\${ANTIGRAVITY_OAUTH_CLIENT_SECRET:-}
      - ANTIGRAVITY_USER_AGENT_VERSION=\${ANTIGRAVITY_USER_AGENT_VERSION:-}
      - SECURITY_URL_ALLOWLIST_ENABLED=\${SECURITY_URL_ALLOWLIST_ENABLED:-false}
      - SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP=\${SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP:-false}
      - SECURITY_URL_ALLOWLIST_ALLOW_PRIVATE_HOSTS=\${SECURITY_URL_ALLOWLIST_ALLOW_PRIVATE_HOSTS:-false}
      - SECURITY_URL_ALLOWLIST_UPSTREAM_HOSTS=\${SECURITY_URL_ALLOWLIST_UPSTREAM_HOSTS:-}
      - UPDATE_PROXY_URL=\${UPDATE_PROXY_URL:-}
      - GATEWAY_OPENAI_RESPONSE_HEADER_TIMEOUT=\${GATEWAY_OPENAI_RESPONSE_HEADER_TIMEOUT:-0}
      - GATEWAY_OPENAI_HTTP2_ENABLED=\${GATEWAY_OPENAI_HTTP2_ENABLED:-true}
      - GATEWAY_OPENAI_HTTP2_ALLOW_PROXY_FALLBACK_TO_HTTP1=\${GATEWAY_OPENAI_HTTP2_ALLOW_PROXY_FALLBACK_TO_HTTP1:-true}
      - GATEWAY_OPENAI_HTTP2_FALLBACK_ERROR_THRESHOLD=\${GATEWAY_OPENAI_HTTP2_FALLBACK_ERROR_THRESHOLD:-2}
      - GATEWAY_OPENAI_HTTP2_FALLBACK_WINDOW_SECONDS=\${GATEWAY_OPENAI_HTTP2_FALLBACK_WINDOW_SECONDS:-60}
      - GATEWAY_OPENAI_HTTP2_FALLBACK_TTL_SECONDS=\${GATEWAY_OPENAI_HTTP2_FALLBACK_TTL_SECONDS:-600}
      - GATEWAY_IMAGE_STREAM_DATA_INTERVAL_TIMEOUT=\${GATEWAY_IMAGE_STREAM_DATA_INTERVAL_TIMEOUT:-900}
      - GATEWAY_IMAGE_STREAM_KEEPALIVE_INTERVAL=\${GATEWAY_IMAGE_STREAM_KEEPALIVE_INTERVAL:-10}
      - GATEWAY_IMAGE_CONCURRENCY_ENABLED=\${GATEWAY_IMAGE_CONCURRENCY_ENABLED:-false}
      - GATEWAY_IMAGE_CONCURRENCY_MAX_CONCURRENT_REQUESTS=\${GATEWAY_IMAGE_CONCURRENCY_MAX_CONCURRENT_REQUESTS:-0}
      - GATEWAY_IMAGE_CONCURRENCY_OVERFLOW_MODE=\${GATEWAY_IMAGE_CONCURRENCY_OVERFLOW_MODE:-reject}
      - GATEWAY_IMAGE_CONCURRENCY_WAIT_TIMEOUT_SECONDS=\${GATEWAY_IMAGE_CONCURRENCY_WAIT_TIMEOUT_SECONDS:-30}
      - GATEWAY_IMAGE_CONCURRENCY_MAX_WAITING_REQUESTS=\${GATEWAY_IMAGE_CONCURRENCY_MAX_WAITING_REQUESTS:-100}
    networks:
      - sub2api-network
    healthcheck:
      test: ["CMD", "wget", "-q", "-T", "5", "-O", "/dev/null", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
EOF

    # 动态追加本地 Postgres 的声明和启动依赖
    if [[ "$use_local_db" == "true" ]]; then
        cat <<EOF >> "$COMPOSE_FILE"
    depends_on:
      postgres:
        condition: service_healthy
EOF
        cat <<EOF >> "$COMPOSE_FILE"

  postgres:
    image: postgres:18-alpine
    container_name: sub2api-postgres
    restart: unless-stopped
    ulimits:
      nofile:
        soft: 100000
        hard: 100000
    volumes:
      - ./postgres_data:/var/lib/postgresql/data:Z
    environment:
      - POSTGRES_USER=\${POSTGRES_USER:-sub2api}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}
      - POSTGRES_DB=\${POSTGRES_DB:-sub2api}
      - PGDATA=/var/lib/postgresql/data
      - TZ=\${TZ:-Asia/Shanghai}
    networks:
      - sub2api-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER:-sub2api} -d \${POSTGRES_DB:-sub2api}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
EOF
    fi

    # 动态追加本地 Redis 的声明和启动依赖
    if [[ "$use_local_redis" == "true" ]]; then
        # 兼容处理：如果没有依赖于 postgres 就不加 depends_on 关键字
        if [[ "$use_local_db" != "true" ]]; then
            cat <<EOF >> "$COMPOSE_FILE"
    depends_on:
EOF
        fi
        cat <<EOF >> "$COMPOSE_FILE"
      redis:
        condition: service_healthy
EOF
        cat <<EOF >> "$COMPOSE_FILE"

  redis:
    image: redis:8-alpine
    container_name: sub2api-redis
    restart: unless-stopped
    ulimits:
      nofile:
        soft: 100000
        hard: 100000
    volumes:
      - ./redis_data:/data:Z
    command: >
        sh -c '
          redis-server
          --save 60 1
          --appendonly yes
          --appendfsync everysec
          \${REDIS_PASSWORD:+--requirepass "\$REDIS_PASSWORD"}'
    environment:
      - TZ=\${TZ:-Asia/Shanghai}
      - REDISCLI_AUTH=\${REDIS_PASSWORD:-}
    networks:
      - sub2api-network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 5s
EOF
    fi

    # 追加底部专用的虚拟局域网拓扑
    cat <<EOF >> "$COMPOSE_FILE"

networks:
  sub2api-network:
    driver: bridge
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动容器群落...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务健康检查就绪并同步初始化 (约5秒)...${RESET}"
    sleep 5

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${GREEN}                 Sub2API 全套服务部署成功！                      ${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}管理员账号     : ${admin_email}${RESET}"
    echo -e "${YELLOW}管理员初始密码 : ${admin_pass}${RESET}"
    echo -e "${CYAN}----------------------------------------------------------------${RESET}"
    echo -e "${YELLOW}数据库路由形态 : PostgreSQL -> [Host: ${db_host} | Port: ${db_port}]${RESET}"
    echo -e "${YELLOW}缓存路由与编号 : Redis -> [Host: ${redis_host} | DB Index: ${redis_db_index}]${RESET}"
    echo -e "${YELLOW}系统工作目录   : $BASE_DIR${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
}

# 更新集群
update_sub2api() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到编排配置文件，请先执行选项 1 部署服务！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新 Sub2API 及内置依赖镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}升级完成！当前所有活跃中的容器均已升级至最新状态。${RESET}"
}

# 彻底下线卸载
uninstall_sub2api() {
    echo -ne "${YELLOW}确定要完全下线并移除所有 Sub2API 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}服务集群已成功停止并被悉数销毁。${RESET}"
            echo -ne "${YELLOW}是否同步将所有持久化物理数据（如本地数据库文件、缓存、.env）彻底删除？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}所有物理路径及数据底座已彻底擦除。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" sub2api-postgres sub2api-redis 2>/dev/null
        fi
        echo -e "${GREEN}完全卸载结束！${RESET}"
    fi
}

start_sub2api() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}全套容器已被唤醒启动。${RESET}"; }
stop_sub2api() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}全套容器已被安全挂起停止。${RESET}"; }
restart_sub2api() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}全套容器集群已顺利完成平滑重启。${RESET}"; }
logs_sub2api() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${YELLOW}当前主控状态 : $status"
    echo -e "${YELLOW}核心镜像版本 : ${img_version}"
    if [ "$server_port" != "N/A" ]; then
        echo -e "${YELLOW}服务外部地址 : http://${DETECT_IP}:${server_port}"
    fi
    if [ -f "$ENV_FILE" ]; then
        local current_db_host=$(grep -E '^POSTGRES_USER=' -A0 "$ENV_FILE" | head -n 1) # 简单验证配置文件存在
        echo -e "${YELLOW}环境配置文件 : ${ENV_FILE}"
        echo -e "${CYAN}提示: 可通过查看该 .env 文件确认当前生效的远程数据库与 Redis 编号。${RESET}"
    fi
    echo -e "${GREEN}================================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  Sub2API 管理面板 ◈       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${server_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_sub2api ;;
        2) update_sub2api ;;
        3) uninstall_sub2api ;;
        4) start_sub2api ;;
        5) stop_sub2api ;;
        6) restart_sub2api ;;
        7) logs_sub2api ;;
        8) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
