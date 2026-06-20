#!/bin/bash
# =================================================================
# MoviePilot V2 (端口映射 3合1全能版) Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="moviepilot-v2"
BASE_DIR="/opt/moviepilot-v2"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 生成随机密钥的辅助函数
generate_random_password() {
    if command -v openssl &> /dev/null; then
        openssl_rand=$(openssl rand -hex 12 2>/dev/null)
        if [[ -n "$openssl_rand" ]]; then
            echo "$openssl_rand"
            return 0
        fi
    fi
    echo "pwd_$((RANDOM % 899999 + 100000))"
}


# 动态获取容器状态、映射端口（双端口）和数据目录
get_status_info() {
    # 1. 检查核心 Web 容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中提取端口信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 提取 WebUI 映射出来的宿主机端口 (内部默认 3000)
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3000"

        # 【新增】提取 API 映射出来的宿主机端口 (内部默认 3001)
        api_port_show=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3001/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$api_port_show" ]] && api_port_show="3001"

        # 提取宿主机配置路径
        data_dir=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$data_dir" ]] && data_dir="$BASE_DIR/config"
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        api_port_show="N/A"
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

# 部署核心逻辑
install_translate() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 请选择 MoviePilot V2 数据库部署模式 ======${RESET}"
    echo -e "${GREEN}1. 本地轻量模式 (使用内置 SQLite 数据库，单容器运行) ${RESET}"
    echo -e "${GREEN}2. 自带集成模式 (自动安装并关联 PostgreSQL + Redis 容器集群) ${RESET}"
    echo -e "${GREEN}3. 远程/外部数据库模式 (关联您现有的独立 PG 和 Redis 数据库) ${RESET}"
    echo -ne "${YELLOW}请输入模式序号 [1-3, 默认 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    echo -e "\n${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入后台 WebUI 访问映射端口 (宿主机) [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"

    echo -ne "${YELLOW}请输入 API 通讯映射端口 (宿主机) [默认: 3001]: ${RESET}"
    read -r api_port
    [[ -z "$api_port" ]] && api_port="3001"

    # 【新增自定义】超级管理员用户名自定义
    echo -ne "${YELLOW}请输入超级管理员用户名 (SUPERUSER) [默认: admin]: ${RESET}"
    read -r mp_user
    [[ -z "$mp_user" ]] && mp_user="admin"

    echo -ne "${YELLOW}请输入初始登录超级密码 (SUPERUSER_PASSWORD) [默认: moviepilot123]: ${RESET}"
    read -r mp_password
    [[ -z "$mp_password" ]] && mp_password="moviepilot123"

    echo -e "\n${CYAN}--- 目录挂载配置 (若不存在会自动创建) ---${RESET}"
    echo -ne "${YELLOW}请输入持久化配置目录 [默认: $BASE_DIR/config]: ${RESET}"
    read -r path_config
    [[ -z "$path_config" ]] && path_config="$BASE_DIR/config"

    echo -ne "${YELLOW}请输入媒体文件根目录 [默认: /media]: ${RESET}"
    read -r path_media
    [[ -z "$path_media" ]] && path_media="/media"

    # 初始化基础目录
    mkdir -p "$path_config" "$path_media" "$BASE_DIR/core"
    chmod -R 777 "$BASE_DIR" "$path_config" "$path_media"

    echo -e "\n${YELLOW}正在生成规范化 docker-compose.yml 配置文件...${RESET}"

    if [[ "$db_mode" == "1" ]]; then
        # ==================== 1. SQLite 本地轻量版 ====================
        cat <<EOF > "$COMPOSE_FILE"
services:
  moviepilot:
    stdin_open: true
    tty: true
    container_name: ${CONTAINER_NAME}
    hostname: ${CONTAINER_NAME}
    ports:
      - '${custom_port}:3000'
      - '${api_port}:3001'
    volumes:
      - '${path_media}:/media'
      - '${path_config}:/config'
      - '${BASE_DIR}/core:/moviepilot/.cloakbrowser'
      - '/var/run/docker.sock:/var/run/docker.sock:ro'
    environment:
      - 'NGINX_PORT=3000'
      - 'PORT=3001'
      - 'PUID=0'
      - 'PGID=0'
      - 'UMASK=000'
      - 'TZ=Asia/Shanghai'
      - 'SUPERUSER=${mp_user}'
      - 'SUPERUSER_PASSWORD=${mp_password}'
    restart: always
    image: jxxghp/moviepilot-v2:latest
EOF

    elif [[ "$db_mode" == "2" ]]; then
        # ==================== 2. PostgreSQL + Redis 自带集成版 ====================
        RAND_REDIS_PWD=$(generate_random_password)
        RAND_PG_PWD=$(generate_random_password)
        mkdir -p "$BASE_DIR/redis_data" "$BASE_DIR/pg_data"

        cat <<EOF > "$COMPOSE_FILE"
services:
  moviepilot:
    stdin_open: true
    tty: true
    container_name: ${CONTAINER_NAME}
    hostname: ${CONTAINER_NAME}
    ports:
      - '${custom_port}:3000'
      - '${api_port}:3001'
    volumes:
      - '${path_media}:/media'
      - '${path_config}:/config'
      - '${BASE_DIR}/core:/moviepilot/.cloakbrowser'
      - '/var/run/docker.sock:/var/run/docker.sock:ro'
    environment:
      - 'NGINX_PORT=3000'
      - 'PORT=3001'
      - 'PUID=0'
      - 'PGID=0'
      - 'UMASK=000'
      - 'TZ=Asia/Shanghai'
      - 'SUPERUSER=${mp_user}'
      - 'SUPERUSER_PASSWORD=${mp_password}'
      - 'DB_TYPE=postgresql'
      - 'DB_POSTGRESQL_HOST=moviepilot-pg'
      - 'DB_POSTGRESQL_PORT=5432'
      - 'DB_POSTGRESQL_DATABASE=moviepilot'
      - 'DB_POSTGRESQL_USERNAME=moviepilot'
      - 'DB_POSTGRESQL_PASSWORD=${RAND_PG_PWD}'
      - 'CACHE_BACKEND_TYPE=redis'
      - 'CACHE_BACKEND_URL=redis://:${RAND_REDIS_PWD}@moviepilot-redis:6379'
    restart: always
    depends_on:
      moviepilot-pg:
        condition: service_healthy
      moviepilot-redis:
        condition: service_healthy
    image: jxxghp/moviepilot-v2:latest

  moviepilot-redis:
    container_name: moviepilot-redis
    image: redis:alpine
    restart: always
    volumes:
      - ${BASE_DIR}/redis_data:/data
    command: redis-server --save 600 1 --requirepass ${RAND_REDIS_PWD}
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${RAND_REDIS_PWD}", "--raw", "incr", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  moviepilot-pg:
    container_name: moviepilot-pg
    image: postgres:17-alpine
    restart: always
    environment:
      POSTGRES_DB: moviepilot
      POSTGRES_USER: moviepilot
      POSTGRES_PASSWORD: ${RAND_PG_PWD}
    volumes:
      - ${BASE_DIR}/pg_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U moviepilot -d moviepilot"]
      interval: 10s
      timeout: 5s
      retries: 5
EOF

    elif [[ "$db_mode" == "3" ]]; then
        # ==================== 3. 远程/外部数据库连接版 ====================
        echo -e "\n${CYAN}--- 远程/外部 PostgreSQL 配置 ---${RESET}"
        echo -ne "${YELLOW}请输入外部 PG 数据库 IP/域名: ${RESET}"
        read -r rem_pg_host
        echo -ne "${YELLOW}请输入外部 PG 数据库端口 [默认: 5432]: ${RESET}"
        read -r rem_pg_port
        [[ -z "$rem_pg_port" ]] && rem_pg_port="5432"
        echo -ne "${YELLOW}请输入外部 PG 数据库库名 [默认: moviepilot]: ${RESET}"
        read -r rem_pg_db
        [[ -z "$rem_pg_db" ]] && rem_pg_db="moviepilot"
        echo -ne "${YELLOW}请输入外部 PG 用户名 [默认: moviepilot]: ${RESET}"
        read -r rem_pg_user
        [[ -z "$rem_pg_user" ]] && rem_pg_user="moviepilot"
        echo -ne "${YELLOW}请输入外部 PG 密码 [必填]: ${RESET}"
        read -r rem_pg_pwd

        echo -e "\n${CYAN}--- 远程/外部 Redis 配置 ---${RESET}"
        echo -ne "${YELLOW}请输入外部 Redis 连接 URL [格式示例: redis://:密码@IP:端口/0]: ${RESET}"
        read -r rem_redis_url

        cat <<EOF > "$COMPOSE_FILE"
services:
  moviepilot:
    stdin_open: true
    tty: true
    container_name: ${CONTAINER_NAME}
    hostname: ${CONTAINER_NAME}
    ports:
      - '${custom_port}:3000'
      - '${api_port}:3001'
    volumes:
      - '${path_media}:/media'
      - '${path_config}:/config'
      - '${BASE_DIR}/core:/moviepilot/.cloakbrowser'
      - '/var/run/docker.sock:/var/run/docker.sock:ro'
    environment:
      - 'NGINX_PORT=3000'
      - 'PORT=3001'
      - 'PUID=0'
      - 'PGID=0'
      - 'UMASK=000'
      - 'TZ=Asia/Shanghai'
      - 'SUPERUSER=${mp_user}'
      - 'SUPERUSER_PASSWORD=${mp_password}'
      - 'DB_TYPE=postgresql'
      - 'DB_POSTGRESQL_HOST=${rem_pg_host}'
      - 'DB_POSTGRESQL_PORT=${rem_pg_port}'
      - 'DB_POSTGRESQL_DATABASE=${rem_pg_db}'
      - 'DB_POSTGRESQL_USERNAME=${rem_pg_user}'
      - 'DB_POSTGRESQL_PASSWORD=${rem_pg_pwd}'
      - 'CACHE_BACKEND_TYPE=redis'
      - 'CACHE_BACKEND_URL=${rem_redis_url}'
    restart: always
    image: jxxghp/moviepilot-v2:latest
EOF
    fi

    echo -e "\n${YELLOW}正在通过 Docker Compose 启动部署集群...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务容器群启动初始化 (约5秒)...${RESET}"
    sleep 5

    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    MoviePilot V2 部署成功！    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}部署模式       : 模式 ${db_mode}${RESET}"
    echo -e "${YELLOW}WEB 访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}超级管理员账号 : ${mp_user}${RESET}"
    echo -e "${YELLOW}超级管理员密码 : ${mp_password}${RESET}"
    echo -e "${YELLOW}持久化配置路径 : ${path_config}${RESET}"
    echo -e "${YELLOW}网络访问模式   : 端口映射模式 (宿主机 ${custom_port} -> 容器 3000)${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新集群镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已安全重启并保持最新。${RESET}"
}

# 卸载集群
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 MoviePilot V2 运行环境吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}所有关联容器已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地配置和数据库运行缓存？(绝不会删除您的电影媒体视频)(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}主配置与数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" moviepilot-redis moviepilot-pg 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务集群已启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务集群已停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务集群已重启${RESET}"; }
logs_translate() { cd "$BASE_DIR" && docker compose logs -f --tail=100 moviepilot; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}核心镜像       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}宿主机配置路径 : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈  MoviePilot V2 管理面板  ◈ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态    :${RESET} $status"
    echo -e "${GREEN}Web端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}API端口 :${RESET} ${YELLOW}${api_port_show}${RESET}"
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
        1) install_translate ;;
        2) update_translate ;;
        3) uninstall_translate ;;
        4) start_translate ;;
        5) stop_translate ;;
        6) restart_translate ;;
        7) logs_translate ;;
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
