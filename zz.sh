#!/bin/bash
# =================================================================
# GPT Image Panel Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="gpt-image-panel-web"
BASE_DIR="/opt/gpt-image-panel"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口和数据目录
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取镜像名称/版本
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 从容器状态提取前端绑定的端口（默认监听的是 9090 端口）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "9090/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        # 兜底获取第一个绑定的端口
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="9090"

        # 从容器状态提取数据目录（挂载路径）
        data_dir=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$data_dir" ]] && data_dir="/opt/gpt-image-panel/data"
    else
        # 容器未安装/未部署时的返回值
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        data_dir="N/A"
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

# 部署 GPT Image Panel
install_gpt_image() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}1. 请输入 GPT Image Panel 访问端口 (宿主机端口) [默认: 9090]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="9090"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 默认生成一个 32 位的强安全访问密钥
    default_access_key=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
    echo -ne "${YELLOW}2. 请输入您的 Access Key 面板访问密码 [默认随机生成: ${default_access_key}]: ${RESET}"
    read -r access_key
    [[ -z "$access_key" ]] && access_key="$default_access_key"

    echo -ne "${YELLOW}3. 请输入默认上游 API 地址 (例: https://api.openai.com) [可留空]: ${RESET}"
    read -r default_api_url

    echo -ne "${YELLOW}4. 请输入默认上游 API 密钥 (Key) [可留空]: ${RESET}"
    read -r default_api_key

    # 1. 创建所需的宿主机持久化目录
    mkdir -p "$BASE_DIR/images" "$BASE_DIR/data" "$BASE_DIR/data/logs"
    chmod -R 777 "$BASE_DIR"

    # 2. 动态生成 .env 配置文件
    echo -e "${YELLOW}正在生成 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
# Published application image used by Docker Compose.
GPT_IMAGE_PANEL_IMAGE=ghcr.io/z1rconium/gpt-image-linux:v1.1.0

# -- Default upstream API preset ----------------------------------
DEFAULT_API_URL=${default_api_url}
DEFAULT_API_KEY=${default_api_key}
DEFAULT_API_PATH=/v1/images/generations
DEFAULT_RESPONSES_MODEL=gpt-5.4
DEFAULT_UPSTREAM_SOCKS5_PROXY=
AIOHTTP_CONNECTION_LIMIT=100
AIOHTTP_CONNECTION_LIMIT_PER_HOST=20

# -- App version / update check / observability -------------------
APP_VERSION=
GITHUB_REPO=Z1rconium/gpt-image-linux
ENABLE_VERSION_CHECK=true
VERSION_CHECK_TIMEOUT_SECONDS=3
VERSION_CHECK_BRANCH=main
ENABLE_METRICS=false
SLOW_GALLERY_QUERY_MS=200
ENABLE_NGINX_ACCEL_REDIRECT=false
PUBLIC_IMAGE_BASE_URL=
PUBLIC_THUMBNAIL_BASE_URL=

# -- Prompt Optimizer ---------------------------------------------
PROMPT_OPTIMIZER_ENABLED=false
PROMPT_OPTIMIZER_API_URL=
PROMPT_OPTIMIZER_API_KEY=
PROMPT_OPTIMIZER_MODEL=gpt-4o-mini
PROMPT_OPTIMIZER_TIMEOUT_SECONDS=60
PROMPT_OPTIMIZER_MAX_OUTPUT_CHARS=4000
PROMPT_OPTIMIZER_MAX_RESPONSE_MB=8
PROMPT_OPTIMIZER_HOST_ALLOWLIST=

# -- Cloudflare R2 Gallery backup sync ----------------------------
R2_BACKUP_ENABLED=false
R2_ENDPOINT_URL=
R2_ENDPOINT_HOST_ALLOWLIST=
R2_BUCKET_NAME=
R2_REGION=auto
R2_KEY_PREFIX=gallery/
R2_SYNC_INTERVAL_HOURS=0
R2_SYNC_CONCURRENCY=4
R2_ACCESS_KEY_ID=
R2_SECRET_ACCESS_KEY=

# -- Access gate / reverse proxy / browser security ---------------
ACCESS_KEY=${access_key}
ALLOW_UNAUTHENTICATED=false
ACCESS_KEY_COOKIE_NAME=gpt_image_access
ACCESS_COOKIE_SECURE=true
ACCESS_MAX_FAILURES=5
ACCESS_LOCKOUT_SECONDS=300
IP_ALLOWLIST=
TRUST_PROXY_HEADERS=false
TRUSTED_PROXY_IPS=
PUBLIC_ORIGIN=
ALLOWED_HOSTS=
CSRF_ORIGIN_CHECK_ENABLED=true
UPSTREAM_HOST_ALLOWLIST=
WEBHOOK_HOST_ALLOWLIST=

# -- Secret persistence / webhooks --------------------------------
ALLOW_PLAINTEXT_SECRETS=false
WEBHOOK_SIGNING_SECRET=
WEBHOOK_TIMEOUT_SECONDS=5
WEBHOOK_MAX_ATTEMPTS=3

# -- Upload, import, image, and upstream response limits ----------
MAX_FILE_SIZE_MB=50
MAX_JSON_BODY_MB=1
MAX_UPSTREAM_JSON_MB=128
MAX_IMAGE_PIXELS=100000000
IMPORT_ARCHIVE_MAX_MB=1000
IMPORT_MAX_FILES=500
IMPORT_MAX_UNCOMPRESSED_MB=1024
IMPORT_MAX_METADATA_BYTES=2097152
IMPORT_MAX_COMPRESSION_RATIO=100

# -- Job queue / SSE limits ---------------------------------------
GRANIAN_WORKERS=1
GRANIAN_RUNTIME_THREADS=2
GRANIAN_LOOP=uvloop
GRANIAN_BACKPRESSURE=100
GRANIAN_BACKLOG=2048
GRANIAN_STATIC_PATH_ROUTE=/_app/immutable
GRANIAN_STATIC_PATH_MOUNT=/app/frontend/build/_app/immutable
GRANIAN_STATIC_PATH_EXPIRES=31536000
MAX_ACTIVE_GENERATE_JOBS=2
MAX_QUEUED_GENERATE_JOBS=20
IMAGE_JOB_UNIT_LEASE_SECONDS=120
IMAGE_JOB_UNIT_POLL_INTERVAL_SECONDS=0.35
MAX_PENDING_EDIT_SOURCE_MB=200
MAX_SSE_SUBSCRIBERS_GLOBAL=200
MAX_SSE_SUBSCRIBERS_PER_IP=10
SSE_CONNECTION_TTL_SECONDS=3600

# -- Runtime storage paths ----------------------------------------
IMAGES_DIR=./images
THUMBNAILS_DIR=./images/thumbs
THUMBNAIL_MAX_SIDE=512
THUMBNAIL_CPU_CONCURRENCY=1
DATA_DIR=./data
DATABASE_FILE=./data/app.sqlite3
LOG_DIR=./data/logs
LOG_LEVEL=INFO
LOG_RETENTION_HOURS=24

# -- Docker build images ------------------------------------------
PYTHON_BASE_IMAGE=python:3.11-slim
NODE_BASE_IMAGE=node:24-alpine
EOF

    # 3. 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  web:
    image: \${GPT_IMAGE_PANEL_IMAGE:-ghcr.io/z1rconium/gpt-image-linux:v1.1.0}
    container_name: ${CONTAINER_NAME}
    ports:
      - "${custom_port}:9090"
    volumes:
      - ./images:/app/images
      - ./data:/app/data
      - ./data/logs:/app/data/logs
    environment:
      - DEFAULT_API_URL=\${DEFAULT_API_URL:-}
      - DEFAULT_API_KEY=\${DEFAULT_API_KEY:-}
      - DEFAULT_API_PATH=\${DEFAULT_API_PATH:-/v1/images/generations}
      - DEFAULT_RESPONSES_MODEL=\${DEFAULT_RESPONSES_MODEL:-gpt-5.4}
      - DEFAULT_UPSTREAM_SOCKS5_PROXY=\${DEFAULT_UPSTREAM_SOCKS5_PROXY:-}
      - AIOHTTP_CONNECTION_LIMIT=\${AIOHTTP_CONNECTION_LIMIT:-100}
      - AIOHTTP_CONNECTION_LIMIT_PER_HOST=\${AIOHTTP_CONNECTION_LIMIT_PER_HOST:-20}
      - APP_VERSION=\${APP_VERSION:-}
      - GITHUB_REPO=\${GITHUB_REPO:-Z1rconium/gpt-image-linux}
      - ENABLE_VERSION_CHECK=\${ENABLE_VERSION_CHECK:-true}
      - VERSION_CHECK_TIMEOUT_SECONDS=\${VERSION_CHECK_TIMEOUT_SECONDS:-3}
      - VERSION_CHECK_BRANCH=\${VERSION_CHECK_BRANCH:-main}
      - ENABLE_METRICS=\${ENABLE_METRICS:-false}
      - SLOW_GALLERY_QUERY_MS=\${SLOW_GALLERY_QUERY_MS:-200}
      - ENABLE_NGINX_ACCEL_REDIRECT=\${ENABLE_NGINX_ACCEL_REDIRECT:-false}
      - PUBLIC_IMAGE_BASE_URL=\${PUBLIC_IMAGE_BASE_URL:-}
      - PUBLIC_THUMBNAIL_BASE_URL=\${PUBLIC_THUMBNAIL_BASE_URL:-}
      - GRANIAN_WORKERS=\${GRANIAN_WORKERS:-1}
      - GRANIAN_RUNTIME_THREADS=\${GRANIAN_RUNTIME_THREADS:-2}
      - GRANIAN_LOOP=\${GRANIAN_LOOP:-uvloop}
      - GRANIAN_BACKPRESSURE=\${GRANIAN_BACKPRESSURE:-100}
      - GRANIAN_BACKLOG=\${GRANIAN_BACKLOG:-2048}
      - GRANIAN_STATIC_PATH_ROUTE=\${GRANIAN_STATIC_PATH_ROUTE:-/_app/immutable}
      - GRANIAN_STATIC_PATH_MOUNT=\${GRANIAN_STATIC_PATH_MOUNT:-/app/frontend/build/_app/immutable}
      - GRANIAN_STATIC_PATH_EXPIRES=\${GRANIAN_STATIC_PATH_EXPIRES:-31536000}
      - ALLOW_PLAINTEXT_SECRETS=\${ALLOW_PLAINTEXT_SECRETS:-false}
      - PROMPT_OPTIMIZER_ENABLED=\${PROMPT_OPTIMIZER_ENABLED:-false}
      - PROMPT_OPTIMIZER_API_URL=\${PROMPT_OPTIMIZER_API_URL:-}
      - PROMPT_OPTIMIZER_API_KEY=\${PROMPT_OPTIMIZER_API_KEY:-}
      - PROMPT_OPTIMIZER_MODEL=\${PROMPT_OPTIMIZER_MODEL:-gpt-4o-mini}
      - PROMPT_OPTIMIZER_TIMEOUT_SECONDS=\${PROMPT_OPTIMIZER_TIMEOUT_SECONDS:-60}
      - PROMPT_OPTIMIZER_MAX_OUTPUT_CHARS=\${PROMPT_OPTIMIZER_MAX_OUTPUT_CHARS:-4000}
      - PROMPT_OPTIMIZER_MAX_RESPONSE_MB=\${PROMPT_OPTIMIZER_MAX_RESPONSE_MB:-8}
      - PROMPT_OPTIMIZER_HOST_ALLOWLIST=\${PROMPT_OPTIMIZER_HOST_ALLOWLIST:-}
      - R2_BACKUP_ENABLED=\${R2_BACKUP_ENABLED:-false}
      - R2_ENDPOINT_URL=\${R2_ENDPOINT_URL:-}
      - R2_ENDPOINT_HOST_ALLOWLIST=\${R2_ENDPOINT_HOST_ALLOWLIST:-}
      - R2_BUCKET_NAME=\${R2_BUCKET_NAME:-}
      - R2_REGION=\${R2_REGION:-auto}
      - R2_KEY_PREFIX=\${R2_KEY_PREFIX:-gallery/}
      - R2_SYNC_INTERVAL_HOURS=\${R2_SYNC_INTERVAL_HOURS:-0}
      - R2_SYNC_CONCURRENCY=\${R2_SYNC_CONCURRENCY:-4}
      - R2_ACCESS_KEY_ID=\${R2_ACCESS_KEY_ID:-}
      - R2_SECRET_ACCESS_KEY=\${R2_SECRET_ACCESS_KEY:-}
      - ACCESS_KEY=\${ACCESS_KEY:-}
      - ALLOW_UNAUTHENTICATED=\${ALLOW_UNAUTHENTICATED:-false}
      - ACCESS_KEY_COOKIE_NAME=\${ACCESS_KEY_COOKIE_NAME:-gpt_image_access}
      - ACCESS_COOKIE_SECURE=\${ACCESS_COOKIE_SECURE:-true}
      - ACCESS_MAX_FAILURES=\${ACCESS_MAX_FAILURES:-5}
      - ACCESS_LOCKOUT_SECONDS=\${ACCESS_LOCKOUT_SECONDS:-300}
      - IP_ALLOWLIST=\${IP_ALLOWLIST:-}
      - TRUST_PROXY_HEADERS=\${TRUST_PROXY_HEADERS:-false}
      - TRUSTED_PROXY_IPS=\${TRUSTED_PROXY_IPS:-}
      - PUBLIC_ORIGIN=\${PUBLIC_ORIGIN:-}
      - ALLOWED_HOSTS=\${ALLOWED_HOSTS:-}
      - CSRF_ORIGIN_CHECK_ENABLED=\${CSRF_ORIGIN_CHECK_ENABLED:-true}
      - UPSTREAM_HOST_ALLOWLIST=\${UPSTREAM_HOST_ALLOWLIST:-}
      - WEBHOOK_HOST_ALLOWLIST=\${WEBHOOK_HOST_ALLOWLIST:-}
      - WEBHOOK_SIGNING_SECRET=\${WEBHOOK_SIGNING_SECRET:-}
      - WEBHOOK_TIMEOUT_SECONDS=\${WEBHOOK_TIMEOUT_SECONDS:-5}
      - WEBHOOK_MAX_ATTEMPTS=\${WEBHOOK_MAX_ATTEMPTS:-3}
      - MAX_FILE_SIZE_MB=\${MAX_FILE_SIZE_MB:-50}
      - MAX_JSON_BODY_MB=\${MAX_JSON_BODY_MB:-1}
      - MAX_UPSTREAM_JSON_MB=\${MAX_UPSTREAM_JSON_MB:-128}
      - MAX_IMAGE_PIXELS=\${MAX_IMAGE_PIXELS:-100000000}
      - IMPORT_ARCHIVE_MAX_MB=\${IMPORT_ARCHIVE_MAX_MB:-1000}
      - IMPORT_MAX_FILES=\${IMPORT_MAX_FILES:-500}
      - IMPORT_MAX_UNCOMPRESSED_MB=\${IMPORT_MAX_UNCOMPRESSED_MB:-1024}
      - IMPORT_MAX_METADATA_BYTES=\${IMPORT_MAX_METADATA_BYTES:-2097152}
      - IMPORT_MAX_COMPRESSION_RATIO=\${IMPORT_MAX_COMPRESSION_RATIO:-100}
      - MAX_ACTIVE_GENERATE_JOBS=\${MAX_ACTIVE_GENERATE_JOBS:-2}
      - MAX_QUEUED_GENERATE_JOBS=\${MAX_QUEUED_GENERATE_JOBS:-20}
      - IMAGE_JOB_UNIT_LEASE_SECONDS=\${IMAGE_JOB_UNIT_LEASE_SECONDS:-120}
      - IMAGE_JOB_UNIT_POLL_INTERVAL_SECONDS=\${IMAGE_JOB_UNIT_POLL_INTERVAL_SECONDS:-0.35}
      - MAX_PENDING_EDIT_SOURCE_MB=\${MAX_PENDING_EDIT_SOURCE_MB:-200}
      - MAX_SSE_SUBSCRIBERS_GLOBAL=\${MAX_SSE_SUBSCRIBERS_GLOBAL:-200}
      - MAX_SSE_SUBSCRIBERS_PER_IP=\${MAX_SSE_SUBSCRIBERS_PER_IP:-10}
      - SSE_CONNECTION_TTL_SECONDS=\${SSE_CONNECTION_TTL_SECONDS:-3600}
      - IMAGES_DIR=\${IMAGES_DIR:-./images}
      - THUMBNAILS_DIR=\${THUMBNAILS_DIR:-./images/thumbs}
      - THUMBNAIL_MAX_SIDE=\${THUMBNAIL_MAX_SIDE:-512}
      - THUMBNAIL_CPU_CONCURRENCY=\${THUMBNAIL_CPU_CONCURRENCY:-1}
      - DATA_DIR=\${DATA_DIR:-./data}
      - DATABASE_FILE=\${DATABASE_FILE:-./data/app.sqlite3}
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:9090/health')"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 GPT Image Panel 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化并进行健康检查检测 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    GPT Image Panel 部署成功！   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}Access Key 密码: ${access_key}${RESET}"
    echo -e "${YELLOW}宿主机工作目录 : ${BASE_DIR}${RESET}"
    echo -e "${YELLOW}提示: 首次进入面板解锁时需输入上方的 Access Key 密码。${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_gpt_image() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 GPT Image Panel 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载容器
uninstall_gpt_image() {
    echo -ne "${YELLOW}确定要卸载并删除 GPT Image Panel 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有持久化数据（图片、数据库与日志）？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}所有配置及图片数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_gpt_image() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_gpt_image() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_gpt_image() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_gpt_image() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}Access Key 密码: ${access_key}${RESET}"
    echo -e "${YELLOW}宿主机数据路径 : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}◈  GPT Image Panel 管理面板  ◈${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
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
        1) install_gpt_image ;;
        2) update_gpt_image ;;
        3) uninstall_gpt_image ;;
        4) start_gpt_image ;;
        5) stop_gpt_image ;;
        6) restart_gpt_image ;;
        7) logs_gpt_image ;;
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
