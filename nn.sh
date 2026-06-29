#!/bin/bash
# =================================================================
# 哆啦A梦转发面板 Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

APP_NAME="flux-panel"
BASE_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
GOST_SQL_URL="https://github.com/bqlpfy/flux-panel/releases/download/1.4.3/gost.sql"
NODE_SCRIPT_URL="https://github.com/bqlpfy/flux-panel/raw/main/install.sh"

DOCKER_CMD="docker compose"

# 代理前缀列表（第一个留空代表直连尝试）
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! $DOCKER_CMD version &>/dev/null; then
        echo -e "${RED}错误: 未检测到 Docker Compose v2，请升级 Docker！${RESET}"
        exit 1
    fi
}

# 代理轮询下载通用函数
download_file() {
    local url="$1" local output="$2" local success=false
    for proxy in "${GITHUB_PROXY[@]}"; do
        local target_url="${proxy}${url}"
        echo -e "${YELLOW}📡 正在尝试通过 [${proxy:-直连}] 下载...${RESET}"
        curl -L -k --max-time 15 -o "$output" "$target_url"
        if [ -s "$output" ]; then success=true; break; else rm -f "$output"; fi
    done
    [[ "$success" = true ]] && return 0 || return 1
}

# 动态获取容器状态、映射端口
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/vite-frontend$)" ]; then
        status_front="${GREEN}运行中${RESET}"
    else
        status_front="${RED}已停止/未创建${RESET}"
    fi

    if [ "$(docker ps -q -f name=^/springboot-backend$)" ]; then
        status_back="${GREEN}运行中${RESET}"
    else
        status_back="${RED}已停止/未创建${RESET}"
    fi

    if [ "$(docker ps -q -f name=^/gost-mysql$)" ]; then
        status_mysql="${GREEN}运行中${RESET}"
    else
        status_mysql="${YELLOW}未创建或外部数据库${RESET}"
    fi

    # 2. 从环境变量或容器中提取端口
    if [ -f "$ENV_FILE" ]; then
        web_front=$(grep 'FRONTEND_PORT=' "$ENV_FILE" | cut -d= -f2)
        web_back=$(grep 'BACKEND_PORT=' "$ENV_FILE" | cut -d= -f2)
    else
        web_front="-"
        web_back="-"
    fi
}

# 获取公网 IP (兼容双栈环境)
get_public_ip() {
    local mode=${1:-"auto"} local ip=""
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

# 检测本地 IPv6 支持
check_ipv6_support() {
    ping6 -c 1 ::1 &>/dev/null && return 0 || return 1
}

# 部署 哆啦A梦转发面板
install_app() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 数据库模式配置 ======${RESET}"
    echo -e "${GREEN}1) 使用本地 Docker 自动安装 MySQL${RESET}"
    echo -e "${GREEN}2) 连接已有的远程外部 MySQL 数据库 (自动导入结构)${RESET}"
    echo -ne "${YELLOW}请选择数据库部署模式 [默认 1]: ${RESET}"
    read -r db_mode
    db_mode=${db_mode:-1}

    echo -e "${YELLOW}📡 准备下载数据库初始化文件...${RESET}"
    if [ ! -f "$BASE_DIR/gost.sql" ] || [ ! -s "$BASE_DIR/gost.sql" ]; then
        if ! download_file "$GOST_SQL_URL" "$BASE_DIR/gost.sql"; then
            echo -e "${RED}❌ 数据库文件下载失败，请检查网络通道${RESET}"
            return 1
        fi
    fi

    if [ "$db_mode" == "2" ]; then
        echo -ne "${YELLOW}请输入远程数据库 IP/域名: ${RESET}"
        read -r DB_HOST
        echo -ne "${YELLOW}请输入远程数据库端口 [默认: 3306]: ${RESET}"
        read -r DB_PORT
        DB_PORT=${DB_PORT:-3306}
    else
        DB_HOST="mysql"
        DB_PORT="3306"
    fi

    echo -ne "${YELLOW}请输入前端访问端口 [默认: 6366]: ${RESET}"
    read -r FRONTEND_PORT
    FRONTEND_PORT=${FRONTEND_PORT:-6366}

    echo -ne "${YELLOW}请输入后端访问端口 [默认: 6365]: ${RESET}"
    read -r BACKEND_PORT
    BACKEND_PORT=${BACKEND_PORT:-6365}

    echo -ne "${YELLOW}请输入数据库用户名 [默认: gost]: ${RESET}"
    read -r DB_USER
    DB_USER=${DB_USER:-gost}

    echo -ne "${YELLOW}请输入数据库名称 [默认: gost]: ${RESET}"
    read -r DB_NAME
    DB_NAME=${DB_NAME:-gost}

    echo -ne "${YELLOW}请输入数据库密码 [默认: 123456]: ${RESET}"
    read -r DB_PASSWORD
    DB_PASSWORD=${DB_PASSWORD:-123456}

    if [ "$db_mode" == "2" ]; then
        echo -e "${YELLOW}🔄 正在尝试连接远程数据库并自动导入结构...${RESET}"
        docker run --rm -i --net=host mysql:5.7 mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" < "$BASE_DIR/gost.sql" 2>/tmp/gost_db_err.log
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ 远程数据库导入失败！错误信息如下：${RESET}"
            cat /tmp/gost_db_err.log
            return 1
        fi
    fi

    JWT_SECRET=$(openssl rand -hex 16 2>/dev/null || echo "gost_jwt_secret_$(date +%s)")

    ENABLE_IPV6=false
    if check_ipv6_support; then
        echo -e "${GREEN}🚀 系统支持 IPv6，默认开启 Docker IPv6 支持${RESET}"
        ENABLE_IPV6=true
    fi

    # 生成 .env
    cat <<EOF > "$ENV_FILE"
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
JWT_SECRET=$JWT_SECRET
FRONTEND_PORT=$FRONTEND_PORT
BACKEND_PORT=$BACKEND_PORT
EOF

    # 生成 docker-compose.yml
    cat <<EOF > "$COMPOSE_FILE"
services:
EOF

    if [ "$db_mode" == "1" ]; then
    cat <<EOF >> "$COMPOSE_FILE"
  mysql:
    image: mysql:5.7
    container_name: gost-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_PASSWORD}
      MYSQL_DATABASE: ${DB_NAME}
      MYSQL_USER: ${DB_USER}
      MYSQL_PASSWORD: ${DB_PASSWORD}
      TZ: Asia/Shanghai
    volumes:
      - mysql_data:/var/lib/mysql
      - ./gost.sql:/docker-entrypoint-initdb.d/init.sql:ro
    command: >
      --default-authentication-plugin=mysql_native_password
      --character-set-server=utf8mb4
      --collation-server=utf8mb4_unicode_ci
      --max_connections=1000
    networks:
      - gost-network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      timeout: 10s
      retries: 10
EOF
    fi

    cat <<EOF >> "$COMPOSE_FILE"
  backend:
    image: bqlpfy/springboot-backend:1.4.3
    container_name: springboot-backend
    restart: unless-stopped
    environment:
      DB_HOST: ${DB_HOST}
      DB_PORT: ${DB_PORT}
      DB_NAME: ${DB_NAME}
      DB_USER: ${DB_USER}
      DB_PASSWORD: ${DB_PASSWORD}
      JWT_SECRET: ${JWT_SECRET}
      LOG_DIR: /app/logs
      JAVA_OPTS: "-Xms256m -Xmx512m -Dfile.encoding=UTF-8 -Duser.timezone=Asia/Shanghai"
    ports:
      - "${BACKEND_PORT}:6365"
    volumes:
      - backend_logs:/app/logs
$( [ "$db_mode" == "1" ] && echo "    depends_on:
      mysql:
        condition: service_healthy" )
    networks:
      - gost-network
    healthcheck:
      test: ["CMD", "sh", "-c", "wget --no-verbose --tries=1 --spider http://localhost:6365/flow/test || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s

  frontend:
    image: bqlpfy/vite-frontend:1.4.3
    container_name: vite-frontend
    restart: unless-stopped
    ports:
      - "${FRONTEND_PORT}:80"
$( [ "$db_mode" == "1" ] && echo "    depends_on:
      backend:
        condition: service_healthy" )
    networks:
      - gost-network

volumes:
$( [ "$db_mode" == "1" ] && echo "  mysql_data:
    name: mysql_data
    driver: local" )
  backend_logs:
    name: backend_logs
    driver: local

networks:
  gost-network:
    name: gost-network
    driver: bridge
$( [ "$ENABLE_IPV6" = true ] && echo "    enable_ipv6: true
    ipam:
      config:
        - subnet: 172.20.0.0/16
        - subnet: fd00:dead:beef::/48" )
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动面板...${RESET}"
    cd "$BASE_DIR" && $DOCKER_CMD up -d --force-recreate

    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    哆啦A梦转发面板 部署成功！  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}前端访问: http://${DETECT_IP}:${FRONTEND_PORT}${RESET}"
    echo -e "${YELLOW}后端访问: http://${DETECT_IP}:${BACKEND_PORT}${RESET}"
    echo -e "${YELLOW}默认账号: admin_user / 密码: admin_user${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

update_app() { [[ -f "$COMPOSE_FILE" ]] && cd "$BASE_DIR" && $DOCKER_CMD pull && $DOCKER_CMD up -d && echo -e "${GREEN}更新完成！${RESET}" || echo -e "${RED}错误: 未部署！${RESET}"; }
uninstall_app() {
    echo -ne "${YELLOW}确定要卸载并删除容器吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && $DOCKER_CMD down
            echo -ne "${YELLOW}是否同时删除本地所有挂载数据及目录？(y/n): ${RESET}"
            read -r clean_data
            [[ "$clean_data" == "y" || "$clean_data" == "Y" ]] && rm -rf "$BASE_DIR" && echo -e "${GREEN}本地数据已彻底清理。${RESET}"
        else
            docker rm -f vite-frontend springboot-backend gost-mysql 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

check_compose_exist() { [[ -f "$COMPOSE_FILE" ]] && return 0 || { echo -e "${RED}错误: 未检测到配置文件！${RESET}"; return 1; }; }
start_app() { check_compose_exist && cd "$BASE_DIR" && $DOCKER_CMD start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_app() { check_compose_exist && cd "$BASE_DIR" && $DOCKER_CMD stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_app() { check_compose_exist && cd "$BASE_DIR" && $DOCKER_CMD restart && echo -e "${GREEN}服务已重启${RESET}"; }

view_logs() {
    echo -e "${GREEN}选择容器查看日志:${RESET}"
    echo "1) MySQL"
    echo "2) Backend (后端)"
    echo "3) Frontend (前端)"
    read -p "选择: " c
    case $c in
        1) docker logs -f gost-mysql 2>/dev/null || echo -e "${RED}容器未创建${RESET}" ;;
        2) docker logs -f springboot-backend 2>/dev/null || echo -e "${RED}容器未创建${RESET}" ;;
        3) docker logs -f vite-frontend 2>/dev/null || echo -e "${RED}容器未创建${RESET}" ;;
        *) echo -e "${RED}无效选择${RESET}" ;;
    esac
}

manage_nodes() {
    echo "📡 正在获取节点管理..."
    if download_file "$NODE_SCRIPT_URL" "$BASE_DIR/node_install.sh"; then
        chmod +x "$BASE_DIR/node_install.sh"
        "$BASE_DIR/node_install.sh"
        rm -f "$BASE_DIR/node_install.sh"
    else
        echo -e "${RED}❌ 无法下载节点管理，请检查网络！${RESET}"
    fi
}

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}前端状态 : $status_front"
    echo -e "${YELLOW}后端状态 : $status_back"
    echo -e "${YELLOW}数据状态 : $status_mysql"
    echo -e "${YELLOW}前端地址 : http://${DETECT_IP}:${web_front}${RESET}"
    echo -e "${YELLOW}后端地址 : http://${DETECT_IP}:${web_back}${RESET}"
    echo -e "${YELLOW}配置目录 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} ◈    哆啦A梦转发面板管理    ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}前端状态 :${RESET} $status_front ${GREEN}端口 :${RESET} ${YELLOW}${web_front}${RESET}"
    echo -e "${GREEN}后端状态 :${RESET} $status_back ${GREEN}端口 :${RESET} ${YELLOW}${web_back}${RESET}"
    echo -e "${GREEN}数据状态 :${RESET} $status_mysql"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}9. 节点管理${RESET}  ${YELLOW}← 添加节点${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) start_app ;;
        5) stop_app ;;
        6) restart_app ;;
        7) view_logs ;;
        8) show_info ;;
        9) manage_nodes ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
