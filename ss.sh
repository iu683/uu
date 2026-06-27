#!/bin/bash
# =================================================================
# FlClouds 云盘工具箱 Docker Compose 管理面板 (本地/远程DB可选版)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="flclouds-backend"
BASE_DIR="/opt/flclouds"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口等
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

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "flclouds-frontend" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="47832"
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

# 部署 FlClouds
install_utils() {
    check_dependencies
    
    if [ ! -d "frontend" ] || [ ! -d "backend" ]; then
        echo -e "${YELLOW}当前目录下未检测到源码，正在从 GitHub 克隆 FlClouds 仓库...${RESET}"
        git clone https://github.com/hicocos/FlClouds.git ./tmp_repo
        mv ./tmp_repo/* ./tmp_repo/.* . 2>/dev/null
        rm -rf ./tmp_repo
    fi

    mkdir -p "$BASE_DIR/file_storage"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 基础端口及路由配置
    echo -ne "${YELLOW}请输入前端访问端口 [默认: 47832]: ${RESET}"
    read -r custom_fe_port
    [[ -z "$custom_fe_port" ]] && custom_fe_port="47832"

    echo -ne "${YELLOW}请输入后端服务端口 [默认: 51947]: ${RESET}"
    read -r custom_be_port
    [[ -z "$custom_be_port" ]] && custom_be_port="51947"

    echo -ne "${YELLOW}请输入应用主域名 DOMAIN [默认: cloud.example.com]: ${RESET}"
    read -r app_domain
    [[ -z "$app_domain" ]] && app_domain="cloud.example.com"

    echo -ne "${YELLOW}请输入前端访问后端的 API 地址 VITE_API_URL [默认: https://api.example.com]: ${RESET}"
    read -r vite_api_url
    [[ -z "$vite_api_url" ]] && vite_api_url="https://api.example.com"

    echo -ne "${YELLOW}请输入跨域允许来源 CORS_ORIGIN [默认: https://cloud.example.com]: ${RESET}"
    read -r cors_origin
    [[ -z "$cors_origin" ]] && cors_origin="https://cloud.example.com"

    # 2. 第三方 Telegram 配置
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -ne "${YELLOW}是否配置 Telegram Bot 集成？(y/n) [默认: n]: ${RESET}"
    read -r tg_choice
    if [[ "$choice" == "y" || "$tg_choice" == "y" || "$tg_choice" == "Y" ]]; then
        echo -ne "${YELLOW}请输入 TELEGRAM_BOT_TOKEN: ${RESET}"
        read -r tg_bot_token
        echo -ne "${YELLOW}请输入 TELEGRAM_API_ID: ${RESET}"
        read -r tg_api_id
        echo -ne "${YELLOW}请输入 TELEGRAM_API_HASH: ${RESET}"
        read -r tg_api_hash
        echo -ne "${YELLOW}请输入 TELEGRAM_USER_API_ID (账号级下载器): ${RESET}"
        read -r tg_user_api_id
        echo -ne "${YELLOW}请输入 TELEGRAM_USER_API_HASH (账号级下载器): ${RESET}"
        read -r tg_user_api_hash
    fi

    # 3. 数据库模式交互选择 (新增)
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${YELLOW}请选择 PostgreSQL 数据库类型:${RESET}"
    echo -e "  ${GREEN}1) 安装本地 PostgreSQL (数据挂载至 $BASE_DIR/postgres_data)${RESET}"
    echo -e "  ${GREEN}2) 连接远程/已有 PostgreSQL (通过参数交互连结)${RESET}"
    echo -ne "${YELLOW}请选择 [默认: 1]: ${RESET}"
    read -r db_choice
    [[ -z "$db_choice" ]] && db_choice="1"

    local database_url=""
    local has_extra_host="false"

    if [[ "$db_choice" == "2" ]]; then
        # 远程数据库精细交互输入
        echo -ne "${YELLOW}请输入远程 PostgreSQL 的 IP 或域名: ${RESET}"
        read -r ext_db_ip
        if [[ -z "$ext_db_ip" ]]; then
            echo -e "${RED}错误: 数据库地址不能为空！${RESET}"
            return
        fi
        echo -ne "${YELLOW}请输入远程 PostgreSQL 端口 [默认: 5432]: ${RESET}"
        read -r ext_db_port
        [[ -z "$ext_db_port" ]] && ext_db_port="5432"

        db_host="$ext_db_ip"
        db_port="$ext_db_port"

        echo -ne "${YELLOW}请输入远程 PostgreSQL 用户名 [默认: flclouds]: ${RESET}"
        read -r db_user
        [[ -z "$db_user" ]] && db_user="flclouds"

        echo -ne "${YELLOW}请输入远程 PostgreSQL 密码: ${RESET}"
        read -r db_pass

        echo -ne "${YELLOW}请输入远程 PostgreSQL 数据库名 [默认: flclouds]: ${RESET}"
        read -r db_name
        [[ -z "$db_name" ]] && db_name="flclouds"

        # 兼容本地宿主机回环网关
        if [[ "$ext_db_ip" == "127.0.0.1" || "$ext_db_ip" == "localhost" ]]; then
            db_host="host.docker.internal"
            has_extra_host="true"
        fi

        # 组装标准数据库连接串
        database_url="postgresql://${db_user}:${db_pass}@${db_host}:${db_port}/${db_name}?schema=public"
    else
        # 本地数据库初始化
        mkdir -p "$BASE_DIR/postgres_data"
        echo -ne "${YELLOW}请为即将生成的本地数据库设置一个密码 (DB_PASSWORD) [默认: flclouds123]: ${RESET}"
        read -r db_password
        [[ -z "$db_password" ]] && db_password="flclouds123"
        database_url="postgresql://flclouds:${db_password}@postgres:5432/flclouds"
    fi

    # 4. 动态写入本地隐藏的编译用 .env 文件
    cat <<EOF > .env
PORT=${custom_be_port}
DOMAIN=${app_domain}
UPLOAD_DIR=/data/uploads
THUMBNAIL_DIR=/data/thumbnails
CHUNK_DIR=/data/chunks
STORAGE_CLASSIFY_BY_PATH=true
STORAGE_PATH_BY_SOURCE=true
STORAGE_PATH_BY_TYPE=true
DUPLICATE_FILE_MODE=copy
AUTO_CLEANUP_ORPHANS=true
VITE_API_URL=${vite_api_url}
CORS_ORIGIN=${cors_origin}
TELEGRAM_BOT_TOKEN=${tg_bot_token}
TELEGRAM_API_ID=${tg_api_id}
TELEGRAM_API_HASH=${tg_api_hash}
TELEGRAM_USER_API_ID=${tg_user_api_id}
TELEGRAM_USER_API_HASH=${tg_user_api_hash}
TELEGRAM_USER_SESSION_FILE=/data/telegram_user_session.txt
TELEGRAM_DOWNLOAD_WORKERS=4
EOF

    # 5. 前后端打包构建
    echo -e "${YELLOW}正在构建前端镜像，请稍候...${RESET}"
    docker build --build-arg VITE_API_URL="${vite_api_url}" -t flclouds-frontend:latest ./frontend

    echo -e "${YELLOW}正在构建后端镜像...${RESET}"
    docker build -t flclouds-backend:latest ./backend

    # 6. 核心：按选择有条件生成 docker-compose.yml 
    echo -e "${YELLOW}正在生成对应的生产 docker-compose.yml...${RESET}"
    
    if [[ "$db_choice" == "2" ]]; then
        # 远程数据库模式（去掉了本地 postgres 容器声明）
        cat <<EOF > "$COMPOSE_FILE"
name: flclouds

services:
  frontend:
    image: flclouds-frontend:latest
    container_name: flclouds-frontend
    ports:
      - "${custom_fe_port}:80"
    networks:
      - flclouds-network
    restart: unless-stopped

  backend:
    image: flclouds-backend:latest
    container_name: flclouds-backend
    ports:
      - "${custom_be_port}:${custom_be_port}"
    environment:
      - DATABASE_URL=${database_url}
      - PORT=${custom_be_port}
      - UPLOAD_DIR=/data/uploads
      - THUMBNAIL_DIR=/data/thumbnails
      - CHUNK_DIR=/data/chunks
      - STORAGE_CLASSIFY_BY_PATH=true
      - STORAGE_PATH_BY_SOURCE=true
      - STORAGE_PATH_BY_TYPE=true
      - DUPLICATE_FILE_MODE=copy
      - AUTO_CLEANUP_ORPHANS=true
      - VITE_API_URL=${vite_api_url}
      - CORS_ORIGIN=${cors_origin}
      - DOMAIN=${app_domain}
      - TELEGRAM_BOT_TOKEN=${tg_bot_token}
      - TELEGRAM_API_ID=${tg_api_id}
      - TELEGRAM_API_HASH=${tg_api_hash}
      - TELEGRAM_USER_API_ID=${tg_user_api_id}
      - TELEGRAM_USER_API_HASH=${tg_user_api_hash}
      - TELEGRAM_USER_SESSION_FILE=/data/telegram_user_session.txt
      - TELEGRAM_DOWNLOAD_WORKERS=4
    volumes:
      - ${BASE_DIR}/file_storage:/data
    networks:
      - flclouds-network
    restart: unless-stopped
EOF
        if [[ "$has_extra_host" == "true" ]]; then
            cat <<EOF >> "$COMPOSE_FILE"
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF
        fi

        cat <<EOF >> "$COMPOSE_FILE"

networks:
  flclouds-network:
    driver: bridge
EOF

    else
        # 本地数据库模式
        cat <<EOF > "$COMPOSE_FILE"
name: flclouds

services:
  frontend:
    image: flclouds-frontend:latest
    container_name: flclouds-frontend
    ports:
      - "${custom_fe_port}:80"
    networks:
      - flclouds-network
    restart: unless-stopped

  backend:
    image: flclouds-backend:latest
    container_name: flclouds-backend
    ports:
      - "${custom_be_port}:${custom_be_port}"
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - DATABASE_URL=${database_url}
      - PORT=${custom_be_port}
      - UPLOAD_DIR=/data/uploads
      - THUMBNAIL_DIR=/data/thumbnails
      - CHUNK_DIR=/data/chunks
      - STORAGE_CLASSIFY_BY_PATH=true
      - STORAGE_PATH_BY_SOURCE=true
      - STORAGE_PATH_BY_TYPE=true
      - DUPLICATE_FILE_MODE=copy
      - AUTO_CLEANUP_ORPHANS=true
      - VITE_API_URL=${vite_api_url}
      - CORS_ORIGIN=${cors_origin}
      - DOMAIN=${app_domain}
      - TELEGRAM_BOT_TOKEN=${tg_bot_token}
      - TELEGRAM_API_ID=${tg_api_id}
      - TELEGRAM_API_HASH=${tg_api_hash}
      - TELEGRAM_USER_API_ID=${tg_user_api_id}
      - TELEGRAM_USER_API_HASH=${tg_user_api_hash}
      - TELEGRAM_USER_SESSION_FILE=/data/telegram_user_session.txt
      - TELEGRAM_DOWNLOAD_WORKERS=4
    volumes:
      - ${BASE_DIR}/file_storage:/data
    networks:
      - flclouds-network
    restart: unless-stopped

  postgres:
    image: postgres:16-alpine
    container_name: flclouds-postgres
    environment:
      - POSTGRES_DB=flclouds
      - POSTGRES_USER=flclouds
      - POSTGRES_PASSWORD=${db_password}
    volumes:
      - ${BASE_DIR}/postgres_data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql
    networks:
      - flclouds-network
    restart: unless-stopped
    healthcheck:
      test: [ "CMD-SHELL", "pg_isready -U flclouds -d flclouds" ]
      interval: 5s
      timeout: 5s
      retries: 5

networks:
  flclouds-network:
    driver: bridge
EOF
    fi

    echo -e "${YELLOW}正在通过 Docker Compose 启动服务堆栈...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     FlClouds 部署成功！        ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}前端访问地址   : http://${DETECT_IP}:${custom_fe_port}${RESET}"
    echo -e "${YELLOW}后端接口端口   : ${custom_be_port}${RESET}"
    echo -e "${YELLOW}本地存储路径   : $BASE_DIR/file_storage${RESET}"
    [[ "$db_choice" == "2" ]] && echo -e "${YELLOW}数据库连结状态 : 远程关联数据库 (${db_host})${RESET}"
    [[ "$db_choice" == "1" ]] && echo -e "${YELLOW}本地数据挂载点 : $BASE_DIR/postgres_data${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新项目
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到部署配置，请先执行选项 1 部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}从远端获取最新代码...${RESET}"
    git pull origin main

    if [ -f ".env" ]; then
        set -a
        source .env
        set +a
    fi

    echo -e "${YELLOW}重新构建前端镜像...${RESET}"
    docker build --build-arg VITE_API_URL="${VITE_API_URL}" -t flclouds-frontend:latest ./frontend
    echo -e "${YELLOW}重新构建后端镜像...${RESET}"
    docker build -t flclouds-backend:latest ./backend

    cd "$BASE_DIR" && docker compose up -d --remove-orphans
    echo -e "${GREEN}更新成功并已重启堆栈！${RESET}"
}

# 登录 Telegram 生成 Session
login_tg_user() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 请先完成选项 1 部署服务后再生成 Session！${RESET}"
        return
    fi
    echo -e "${YELLOW}准备启动交互登录，请根据屏幕提示输入你的 Telegram 手机号及验证码:${RESET}"
    cd "$BASE_DIR" && docker compose run --rm --no-deps backend npm run login:telegram-user
}

# 卸载容器
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载 FlClouds 容器栈吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已全部停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时彻底清空本地配置及持久化挂载文件目录 ($BASE_DIR)？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地数据卷已彻底清理。${RESET}"
            fi
        else
            docker rm -f flclouds-frontend flclouds-backend flclouds-postgres 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务栈已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务栈已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务栈已重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}前端访问端口   : ${webui_port}"
    echo -e "${YELLOW}数据本地根路径 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  FlClouds 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}WebUI端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新项目${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看后端日志${RESET}"
    echo -e "${GREEN}8. 查看面板配置${RESET}"
    echo -e "${GREEN}9. 生成/登录 Telegram User Session${RESET}"
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
        9) login_tg_user ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
