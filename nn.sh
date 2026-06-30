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

APP_NAME="flvx-panel"
BASE_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
NODE_SCRIPT_URL="https://raw.githubusercontent.com/Sagit-chu/flvx/main/install.sh"

DOCKER_CMD="docker compose"

# 代理前缀列表
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://ghfast.top/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
)

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

# 格式化 URL 中的 IP (如果是 IPv6 则加上方括号 [])
format_ip_for_url() {
    local ip="$1"
    if [[ "$ip" == *":"* ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

download_file() {
    local url="$1" local output="$2" local success=false
    for proxy in "${GITHUB_PROXY[@]}"; do
        local target_url="${proxy}${url}"
        echo -e "${YELLOW}📡 正在尝试通过 [${proxy:-直连}]...${RESET}"
        curl -L -k --max-time 15 -o "$output" "$target_url"
        if [ -s "$output" ]; then success=true; break; else rm -f "$output"; fi
    done
    [[ "$success" = true ]] && return 0 || return 1
}

get_status_info() {
    [ "$(docker ps -q -f name=^/vite-frontend$)" ] && status_front="${GREEN}运行中${RESET}" || status_front="${RED}已停止/未创建${RESET}"
    [ "$(docker ps -q -f name=^/flux-panel-backend$)" ] && status_back="${GREEN}运行中${RESET}" || status_back="${RED}已停止/未创建${RESET}"
    
    if [ -f "$ENV_FILE" ]; then
        db_type_curr=$(grep 'DB_TYPE=' "$ENV_FILE" | cut -d= -f2)
        db_type_curr=${db_type_curr:-sqlite}
        if [ "$db_type_curr" == "postgres" ]; then
            [ "$(docker ps -q -f name=^/flux-panel-postgres$)" ] && status_db="${GREEN}PostgreSQL 运行中${RESET}" || status_db="${RED}PostgreSQL 已停止${RESET}"
        else
            status_db="${GREEN}SQLite (内置模式)${RESET}"
        fi
        web_front=$(grep 'FRONTEND_PORT=' "$ENV_FILE" | cut -d= -f2)
        web_back=$(grep 'BACKEND_PORT=' "$ENV_FILE" | cut -d= -f2)
    else
        status_db="${YELLOW}未配置${RESET}"
        web_front="-"
        web_back="-"
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

check_ipv6_support() {
    ping6 -c 1 ::1 &>/dev/null && return 0 || return 1
}

install_app() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 数据库类型选择 ======${RESET}"
    echo -e "${GREEN}1) 使用内置轻量级 SQLite (推荐，免维护，占用小)${RESET}"
    echo -e "${GREEN}2) 使用独立 PostgreSQL 16 容器 (适合高并发/多节点数据同步)${RESET}"
    echo -ne "${YELLOW}请选择数据库类型 [默认 1]: ${RESET}"
    read -r db_select
    db_select=${db_select:-1}

    # 远程数据库支持扩展
    local remote_db_port_section=""
    if [ "$db_select" == "2" ]; then
        echo -ne "${YELLOW}是否允许 PostgreSQL 数据库支持远程连接？(y/n) [默认 n]: ${RESET}"
        read -r allow_remote
        if [[ "$allow_remote" == "y" || "$allow_remote" == "Y" ]]; then
            echo -ne "${YELLOW}请输入 PostgreSQL 远程访问端口 [默认 5432]: ${RESET}"
            read -r db_port
            db_port=${db_port:-5432}
            remote_db_port_section="ports:\n      - \"${db_port}:5432\""
            echo -e "${GREEN}已配置数据库远程映射端口: ${db_port}${RESET}"
        fi
    fi

    echo -ne "${YELLOW}请输入前端访问端口 [默认: 6366]: ${RESET}"
    read -r FRONTEND_PORT
    FRONTEND_PORT=${FRONTEND_PORT:-6366}

    echo -ne "${YELLOW}请输入后端访问端口 [默认: 6365]: ${RESET}"
    read -r BACKEND_PORT
    BACKEND_PORT=${BACKEND_PORT:-6365}

    JWT_SECRET=$(openssl rand -hex 16 2>/dev/null || echo "flux_jwt_secret_$(date +%s)")
    ENABLE_IPV6=false
    check_ipv6_support && ENABLE_IPV6=true

    # 根据选择初始化环境变量
    if [ "$db_select" == "2" ]; then
        DB_TYPE="postgres"
        PG_PASS=$(openssl rand -hex 12 2>/dev/null || echo "flux_pwd_$(date +%s)")
        DATABASE_URL="postgres://flux_panel:${PG_PASS}@postgres:5432/flux_panel?sslmode=disable"
        
        cat <<EOF > "$ENV_FILE"
JWT_SECRET=$JWT_SECRET
BACKEND_PORT=$BACKEND_PORT
FRONTEND_PORT=$FRONTEND_PORT
DB_TYPE=postgres
DATABASE_URL=$DATABASE_URL
POSTGRES_DB=flux_panel
POSTGRES_USER=flux_panel
POSTGRES_PASSWORD=$PG_PASS
FLUX_VERSION=latest
EOF
    else
        cat <<EOF > "$ENV_FILE"
JWT_SECRET=$JWT_SECRET
BACKEND_PORT=$BACKEND_PORT
FRONTEND_PORT=$FRONTEND_PORT
DB_TYPE=sqlite
FLUX_VERSION=latest
EOF
    fi

    # 动态写入全新的 docker-compose.yml
    cat <<EOF > "$COMPOSE_FILE"
services:
  backend:
    image: ghcr.io/sagit-chu/flux-panel-backend:\${FLUX_VERSION:-latest}
    container_name: flux-panel-backend
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
    environment:
      DB_TYPE: \${DB_TYPE:-sqlite}
      DB_PATH: /app/data/gost.db
      DATABASE_URL: \${DATABASE_URL:-}
      JWT_SECRET: \${JWT_SECRET}
      SERVER_ADDR: :6365
      TZ: Asia/Shanghai
      FLUX_VERSION: \${FLUX_VERSION:-dev}
      PANEL_DEPLOY_DIR: /opt/flux-panel
      PANEL_BACKEND_CONTAINER: flux-panel-backend
    ports:
      - "\${BACKEND_PORT}:6365"
    volumes:
      - sqlite_data:/app/data
      - /var/run/docker.sock:/var/run/docker.sock
      - ./:/opt/flux-panel
    networks:
      - gost-network
    stop_grace_period: 30s
    stop_signal: SIGTERM
    healthcheck:
      test: ["CMD", "sh", "-c", "wget --no-verbose --tries=1 --spider http://localhost:6365/flow/test || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

EOF

    # 如果选择 PostgreSQL，则注入 postgres 服务段
    if [ "$db_select" == "2" ]; then
    cat <<EOF >> "$COMPOSE_FILE"
  postgres:
    image: postgres:16-alpine
    container_name: flux-panel-postgres
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "20m"
    environment:
      POSTGRES_DB: \${POSTGRES_DB:-flux_panel}
      POSTGRES_USER: \${POSTGRES_USER:-flux_panel}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:-flux_panel_change_me}
      TZ: Asia/Shanghai
$( [ -n "$remote_db_port_section" ] && echo -e "    $remote_db_port_section" )
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - gost-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER:-flux_panel} -d \${POSTGRES_DB:-flux_panel}"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

EOF
    fi

    # 注入前端
    cat <<EOF >> "$COMPOSE_FILE"
  frontend:
    image: ghcr.io/sagit-chu/vite-frontend:\${FLUX_VERSION:-latest}
    container_name: vite-frontend
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
    ports:
      - "\${FRONTEND_PORT}:80"
    depends_on:
      backend:
        condition: service_healthy
    networks:
      - gost-network

volumes:
  sqlite_data:
    name: sqlite_data
    driver: local
$( [ "$db_select" == "2" ] && echo "  postgres_data:
    name: postgres_data
    driver: local" )

networks:
  gost-network:
    name: gost-network
    driver: bridge
$( if [ "$ENABLE_IPV6" = true ]; then echo "    enable_ipv6: true
    ipam:
      config:
        - subnet: 172.80.0.0/16
        - subnet: fd00:dead:beef::/48"
   else echo "    ipam:
      config:
        - subnet: 172.80.0.0/16"
   fi )
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动面板...${RESET}"
    cd "$BASE_DIR" && $DOCKER_CMD up -d --force-recreate

    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Flvx-Panel 部署成功！  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}前端访问: http://${DETECT_IP}:${FRONTEND_PORT}${RESET}"
    echo -e "${YELLOW}后端访问: http://${DETECT_IP}:${BACKEND_PORT}${RESET}"
    echo -e "${YELLOW}默认账号: admin_user / 密码: admin_user${RESET}"
    if [ -n "$remote_db_port_section" ]; then
        echo -e "${CYAN}数据库远程连接: ${RAW_IP}:${db_port} (用户: flux_panel)${RESET}"
    fi
    echo -e "${GREEN}================================${RESET}"
}

update_app() { [[ -f "$COMPOSE_FILE" ]] && cd "$BASE_DIR" && $DOCKER_CMD pull && $DOCKER_CMD up -d && echo -e "${GREEN}更新完成！${RESET}" || echo -e "${RED}错误: 未部署！${RESET}"; }
uninstall_app() {
    echo -ne "${YELLOW}确定要卸载吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && $DOCKER_CMD down
            echo -ne "${YELLOW}是否完全清理挂载数据？(y/n): ${RESET}"
            read -r clean_data
            [[ "$clean_data" == "y" || "$clean_data" == "Y" ]] && rm -rf "$BASE_DIR" && echo -e "${GREEN}数据已彻底清理。${RESET}"
        else
            docker rm -f vite-frontend flux-panel-backend flux-panel-postgres 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

check_compose_exist() { [[ -f "$COMPOSE_FILE" ]] && return 0 || { echo -e "${RED}错误: 未检测到配置文件！${RESET}"; return 1; }; }
start_app() { check_compose_exist && cd "$BASE_DIR" && $DOCKER_CMD start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_app() { check_compose_exist && cd "$BASE_DIR" && $DOCKER_CMD stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_app() { check_compose_exist && cd "$BASE_DIR" && $DOCKER_CMD restart && echo -e "${GREEN}服务已重启${RESET}"; }

view_logs() {
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}选择容器查看日志:${RESET}"
    echo -e "${YELLOW}1) Backend (后端)${RESET}"
    echo -e "${YELLOW}2) Frontend (前端)${RESET}"
    echo -e "${YELLOW}3) PostgreSQL (数据库)${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请选择 [1-3]: ${RESET}"
    read -r c
    case $c in
        1) docker logs -f flux-panel-backend ;;
        2) docker logs -f vite-frontend ;;
        3) docker logs -f flux-panel-postgres 2>/dev/null || echo -e "${RED}未处于 PostgreSQL 模式或容器未创建${RESET}" ;;
        *) echo -e "${RED}无效选择${RESET}" ;;
    esac
}

manage_nodes() {
    echo -e "${YELLOW}📡 正在获取节点管理管理...${RESET}"
    if download_file "$NODE_SCRIPT_URL" "$BASE_DIR/node_install.sh"; then
        chmod +x "$BASE_DIR/node_install.sh" && "$BASE_DIR/node_install.sh"
        rm -f "$BASE_DIR/node_install.sh"
    else
        echo -e "${RED}❌ 无法下载节点管理，请检查网络！${RESET}"
    fi
}

show_info() {
    get_status_info
    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}前端状态 : $status_front"
    echo -e "${YELLOW}后端状态 : $status_back"
    echo -e "${YELLOW}数据存储 : $status_db"
    echo -e "${YELLOW}前端地址 : http://${DETECT_IP}:${web_front}${RESET}"
    echo -e "${YELLOW}后端地址 : http://${DETECT_IP}:${web_back}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  Flvx-Panel 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}前端状态 :${RESET} $status_front  ${GREEN}端口 :${RESET} ${YELLOW}${web_front}${RESET}"
    echo -e "${GREEN}后端状态 :${RESET} $status_back  ${GREEN}端口 :${RESET} ${YELLOW}${web_back}${RESET}"
    echo -e "${GREEN}数据环境 :${RESET} $status_db"
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
