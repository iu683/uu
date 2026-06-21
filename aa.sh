#!/bin/bash
# =================================================================
# MediaStationGo 工具箱 Docker Compose 多模式管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="mediastation-go"
BASE_DIR="/opt/mediastation_go"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口和数据目录
get_status_info() {
    # 1. 检查主容器状态
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

        # 从容器状态提取 Web 端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="18080"
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
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

# 部署 MediaStationGo
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 目录挂载自定义配置 ======${RESET}"
    echo -e "${YELLOW}提示: 如果路径不存在，将自动创建。可以直接回车使用默认值。${RESET}"
    
    # 路径 1: 运行数据
    echo -ne "${YELLOW}请输入运行数据目录 [默认: ./data]: ${RESET}"
    read -r path_data
    [[ -z "$path_data" ]] && path_data="./data"

    # 路径 2: 缓存目录
    echo -ne "${YELLOW}请输入缓存目录 [默认: ./cache]: ${RESET}"
    read -r path_cache
    [[ -z "$path_cache" ]] && path_cache="./cache"

    # 路径 3: 媒体库目录
    echo -ne "${YELLOW}请输入媒体库真实路径 [默认:./Media]: ${RESET}"
    read -r path_media
    [[ -z "$path_media" ]] && path_media="./Media"

    # 路径 4: 下载目录
    echo -ne "${YELLOW}请输入下载库真实路径 [默认:./Downloads]: ${RESET}"
    read -r path_downloads
    [[ -z "$path_downloads" ]] && path_downloads="./Downloads"

    # 预创建目录（如果是相对路径如 ./data 则在 $BASE_DIR 下创建）
    [[ "$path_data" == "./"* ]] && mkdir -p "$BASE_DIR/${path_data#./}" || mkdir -p "$path_data"
    [[ "$path_cache" == "./"* ]] && mkdir -p "$BASE_DIR/${path_cache#./}" || mkdir -p "$path_cache"
    [[ "$path_media" == "./"* ]] && mkdir -p "$BASE_DIR/${path_media#./}" || mkdir -p "$path_media"
    [[ "$path_downloads" == "./"* ]] && mkdir -p "$BASE_DIR/${path_downloads#./}" || mkdir -p "$path_downloads"

    echo -e "\n${CYAN}====== 2. 架构模式选择 ======${RESET}"
    echo -e "${GREEN}1.${RESET} 本地 PostgreSQL (轻量推荐)"
    echo -e "${GREEN}2.${RESET} 本地 PostgreSQL + 本地 Redis (多用户高并发推荐)"
    echo -e "${GREEN}3.${RESET} 远程/外部 PostgreSQL (免建库模式)"
    echo -ne "${YELLOW}请选择模式编号 [默认: 1]: ${RESET}"
    read -r mode_choice
    [[ -z "$mode_choice" ]] && mode_choice="1"

    echo -e "\n${CYAN}====== 3. 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入服务访问端口 (宿主机端口) [默认: 18080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="18080"

    # 初始化变量
    local depends_block=""
    local redis_env=""
    local db_dsn="postgres://mediastation:mediastation@postgres:5432/mediastation?sslmode=disable"
    local extra_services=""

    # 模式判断与参数拼装
    if [[ "$mode_choice" == "1" ]]; then
        mkdir -p "$BASE_DIR/postgres"
        docker pull postgres:16-alpine
        depends_block="depends_on:
      postgres:
        condition: service_healthy"
        extra_services="  postgres:
    image: postgres:16-alpine
    pull_policy: never
    restart: unless-stopped
    environment:
      POSTGRES_DB: mediastation
      POSTGRES_USER: mediastation
      POSTGRES_PASSWORD: mediastation
      TZ: Asia/Shanghai
    volumes:
      - ./postgres:/var/lib/postgresql/data
    healthcheck:
      test: [\"CMD-SHELL\", \"pg_isready -h 127.0.0.1 -U mediastation -d mediastation\"]
      interval: 10s
      timeout: 5s
      retries: 10
    logging:
      driver: json-file
      options:
        max-size: \"10m\"
        max-file: \"3\""

    elif [[ "$mode_choice" == "2" ]]; then
        mkdir -p "$BASE_DIR/postgres" "$BASE_DIR/redis"
        docker pull postgres:16-alpine
        docker pull redis:7-alpine
        depends_block="depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy"
        redis_env="MEDIASTATION_CACHE_REDIS_URL: redis://redis:6379/0"
        extra_services="  postgres:
    image: postgres:16-alpine
    pull_policy: never
    restart: unless-stopped
    environment:
      POSTGRES_DB: mediastation
      POSTGRES_USER: mediastation
      POSTGRES_PASSWORD: mediastation
      TZ: Asia/Shanghai
    volumes:
      - ./postgres:/var/lib/postgresql/data
    healthcheck:
      test: [\"CMD-SHELL\", \"pg_isready -h 127.0.0.1 -U mediastation -d mediastation\"]
      interval: 10s
      timeout: 5s
      retries: 10
    logging:
      driver: json-file
      options:
        max-size: \"10m\"
        max-file: \"3\"

  redis:
    image: redis:7-alpine
    pull_policy: never
    restart: unless-stopped
    command:
      - redis-server
      - --appendonly
      - \"yes\"
      - --maxmemory
      - 256mb
      - --maxmemory-policy
      - allkeys-lru
    volumes:
      - ./redis:/data
    healthcheck:
      test: [\"CMD\", \"redis-cli\", \"ping\"]
      interval: 10s
      timeout: 5s
      retries: 10
    logging:
      driver: json-file
      options:
        max-size: \"10m\"
        max-file: \"3\""

    elif [[ "$mode_choice" == "3" ]]; then
        echo -e "\n${CYAN}====== 远程/外部 PostgreSQL 信息输入 ======${RESET}"
        echo -ne "${YELLOW}请输入外部 PostgreSQL 的 IP 或域名 [默认: 127.0.0.1]: ${RESET}"
        read -r ext_host
        [[ -z "$ext_host" ]] && ext_host="127.0.0.1"
        
        echo -ne "${YELLOW}请输入 PostgreSQL 端口 [默认: 5432]: ${RESET}"
        read -r ext_port
        [[ -z "$ext_port" ]] && ext_port="5432"
        
        echo -ne "${YELLOW}请输入数据库用户名 [默认: MediaStationGo]: ${RESET}"
        read -r ext_user
        [[ -z "$ext_user" ]] && ext_user="MediaStationGo"
        
        echo -ne "${YELLOW}请输入数据库密码 (必填): ${RESET}"
        read -r ext_pass
        if [[ -z "$ext_pass" ]]; then
            echo -e "${RED}错误: 密码不能为空！${RESET}"
            return
        fi
        
        echo -ne "${YELLOW}请输入目标数据库名 [默认: MediaStationGo]: ${RESET}"
        read -r ext_dbname
        [[ -z "$ext_dbname" ]] && ext_dbname="MediaStationGo"

        # 拼接成 DSN 字符串
        db_dsn="postgres://${ext_user}:${ext_pass}@${ext_host}:${ext_port}/${ext_dbname}?sslmode=disable"
    else
        echo -e "${RED}错误: 无效的选择！${RESET}"
        return
    fi

    # 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成规范的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  mediastation-go:
    image: ghcr.io/shukebta/mediastation-go:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    init: true
    ${depends_block}
    ports:
      - "${custom_port}:8080"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ${path_data}:/data
      - ${path_cache}:/cache
      - ${path_media}:/media
      - ${path_downloads}:/downloads
    environment:
      TZ: Asia/Shanghai
      PUID: "1000"
      PGID: "1000"
      MEDIASTATION_APP_HOST: 0.0.0.0
      MEDIASTATION_APP_PORT: 8080
      MEDIASTATION_APP_WEB_DIR: /app/web/dist
      MEDIASTATION_APP_DATA_DIR: /data
      MEDIASTATION_LOGGING_LEVEL: warn
      MEDIASTATION_LOGGING_FORMAT: console
      MEDIASTATION_LOGGING_OUTPUT_PATH: /data/logs
      MEDIASTATION_DATABASE_TYPE: postgres
      MEDIASTATION_DATABASE_DSN: "${db_dsn}"
      ${redis_env}
      MEDIASTATION_DATABASE_DB_PATH: /data/mediastation.db
      MEDIASTATION_CACHE_CACHE_DIR: /cache
      MEDIASTATION_MEDIA_DIR: ${path_media}
      MEDIASTATION_MEDIA_CONTAINER_DIR: /media
      MEDIASTATION_DOWNLOAD_DIR: ${path_downloads}
      MEDIASTATION_DOWNLOAD_CONTAINER_DIR: /downloads
      MEDIASTATION_TRANSCODER_ENABLED: "true"
      MEDIASTATION_TRANSCODER_HARDWARE_ACCEL: "false"
      MEDIASTATION_TRANSCODER_REALTIME: "true"
      MEDIASTATION_TRANSCODER_THREADS: "2"
      MEDIASTATION_TRANSCODER_MAX_CONCURRENT: "1"
      MEDIASTATION_TRANSCODER_IDLE_TIMEOUT_SECONDS: "120"
    healthcheck:
      test: ["CMD-SHELL", "busybox wget -qO- http://127.0.0.1:8080/api/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

${extra_services}
EOF

    echo -e "${YELLOW}正在启动 Docker 容器集群...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务初始化完成 (约5秒)...${RESET}"
    sleep 5

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    MediaStationGo 部署成功！    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前模式       : 模式 ${mode_choice}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}默认账号/密码  : admin/admin123${RESET}"
    echo -e "${YELLOW}运行数据路径   : ${path_data}${RESET}"
    echo -e "${YELLOW}影视媒体路径   : ${path_media}${RESET}"
    echo -e "${YELLOW}配置文件存储   : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在更新 MediaStationGo 镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull mediastation-go
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！${RESET}"
}

# 卸载
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 MediaStationGo 服务集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时清理脚本主配置目录 (不会主动删除非/opt下的独立媒体库)？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}数据彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务集群已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务集群已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务集群已重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}默认管理账号   : admin / admin123${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} ◈  MediaStationGo 媒体面板  ◈  ${RESET}"
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
        1) install_utils ;;
        2) update_utils ;;
        3) uninstall_utils ;;
        4) start_utils ;;
        5) stop_utils ;;
        6) restart_utils ;;
        7) logs_utils ;;
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
