#!/bin/bash
# ========================================
# flux-panel 管理
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="flux"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2，请升级 Docker${RESET}"
        exit 1
    fi
}

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用！${RESET}"
        return 1
    fi
    return 0
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。" && return
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Flux 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker
    mkdir -p "$APP_DIR"

    echo -e "${GREEN}=== Flux 安装 ===${RESET}"

    read -p "面板端口 [默认6366]: " input_port
    PORT=${input_port:-6366}
    check_port "$PORT" || return

    read -p "DB名称 [默认flux_db]: " DB_NAME
    DB_NAME=${DB_NAME:-flux_db}

    read -p "DB用户 [默认flux_user]: " DB_USER
    DB_USER=${DB_USER:-flux_user}

    DB_PASSWORD=$(openssl rand -hex 16)
    JWT_SECRET=$(openssl rand -hex 32)

    echo -e "${GREEN}已自动生成数据库密码和JWT密钥${RESET}"
    echo -e "${YELLOW}DB_PASSWORD: $DB_PASSWORD${RESET}"
    echo -e "${YELLOW}JWT_SECRET: $JWT_SECRET${RESET}"

    read -p "启用IPv6? true/false [默认true]: " IPV6
    ENABLE_IPV6=${IPV6:-true}

    PANEL_LISTEN="0.0.0.0"

    cat > "$ENV_FILE" <<EOF
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
JWT_SECRET=$JWT_SECRET
PANEL_PORT=$PORT
ENABLE_IPV6=$ENABLE_IPV6
PANEL_LISTEN=$PANEL_LISTEN
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  mysql:
    image: mysql:5.7
    container_name: flux-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_PASSWORD}
      MYSQL_DATABASE: ${DB_NAME}
      MYSQL_USER: ${DB_USER}
      MYSQL_PASSWORD: ${DB_PASSWORD}
      TZ: Asia/Shanghai
    volumes:
      - mysql_data:/var/lib/mysql
    command: >
      --default-authentication-plugin=mysql_native_password
      --character-set-server=utf8mb4
      --collation-server=utf8mb4_unicode_ci
      --max_connections=1000
      --innodb_buffer_pool_size=256M
    networks:
      - flux-network
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h localhost -uroot -p\${MYSQL_ROOT_PASSWORD} --silent"]
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 40s

  node-binary-init:
    image: 0xnetuser/node-binary:2.1.25
    container_name: node-binary-init
    restart: "no"
    volumes:
      - node_binary:/data/node

  backend:
    image: 0xnetuser/go-backend:2.1.25
    container_name: go-backend
    restart: unless-stopped
    environment:
      DB_HOST: mysql
      DB_NAME: ${DB_NAME}
      DB_USER: ${DB_USER}
      DB_PASSWORD: ${DB_PASSWORD}
      JWT_SECRET: ${JWT_SECRET}
      ALLOWED_ORIGINS: \${ALLOWED_ORIGINS:-}
      LOG_DIR: /app/logs
    expose:
      - "6365"
    volumes:
      - backend_logs:/app/logs
      - node_binary:/data/node
      - /var/run/docker.sock:/var/run/docker.sock
      - .:/data/compose
    depends_on:
      mysql:
        condition: service_started
      node-binary-init:
        condition: service_completed_successfully
    networks:
      - flux-network

  frontend:
    image: 0xnetuser/nextjs-frontend:2.1.25
    container_name: nextjs-frontend
    restart: unless-stopped
    ports:
      - "\${PANEL_LISTEN:-0.0.0.0}:${PORT}:80"
    depends_on:
      backend:
        condition: service_started
    networks:
      - flux-network

volumes:
  mysql_data:
  backend_logs:
  node_binary:

networks:
  flux-network:
    driver: bridge
    enable_ipv6: \${ENABLE_IPV6:-false}
EOF

    cd "$APP_DIR" || exit

    echo -e "${YELLOW}启动 MySQL...${RESET}"
    docker compose up -d mysql

    echo -e "${YELLOW}等待 MySQL 完全就绪...${RESET}"

    # ⭐ 关键修复：阻塞等待 MySQL ready
    for i in {1..60}; do
        if docker exec flux-mysql mysqladmin ping -uroot -p"$DB_PASSWORD" --silent >/dev/null 2>&1; then
            echo -e "${GREEN}MySQL 已就绪${RESET}"
            break
        fi
        sleep 2
    done

    echo -e "${YELLOW}启动完整服务...${RESET}"
    docker compose up -d

    echo -e "${YELLOW}等待 backend 启动...${RESET}"
    for i in {1..30}; do
        if curl -s "http://127.0.0.1:${PORT}/flow/test" >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    SERVER_IP=$(get_public_ip)

    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN}✅ Flux 安装完成${RESET}"
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${YELLOW}访问: http://${SERVER_IP}:${PORT}${RESET}"
    echo -e "${YELLOW}用户名: admin_user${RESET}"
    echo -e "${YELLOW}密码: 查看日志${RESET}"
    echo -e "${YELLOW}数据目录: $APP_DIR${RESET}"
    echo -e "${GREEN}=================================${RESET}"

    read -p "按回车返回菜单..."
}


update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Flux 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    cd "$APP_DIR" || return
    docker compose restart
    echo -e "${GREEN}✅ Flux 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f go-backend
}

check_status() {
    docker ps --filter "name=flux"
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Flux 已卸载完成${RESET}"
    read -p "按回车返回菜单..."
}

menu
