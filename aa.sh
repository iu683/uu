#!/bin/bash
# ========================================
# GOST 一键管理脚本 (哆啦A梦转发面板)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="flux-panel"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
GOST_SQL_URL="https://github.com/bqlpfy/flux-panel/releases/download/1.4.3/gost.sql"
NODE_SCRIPT_URL="https://github.com/bqlpfy/flux-panel/raw/main/install.sh"

DOCKER_CMD="docker compose"

# GitHub 代理前缀列表（第一个为空代表直连尝试）
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

# 依赖检查：确保安装了 jq 和 openssl
check_dependencies() {
    if ! command -v jq &>/dev/null; then
        echo -e "${YELLOW}未检测到 jq，正在尝试安装...${RESET}"
        apt-get update && apt-get install -y jq || yum install -y jq
    fi
    if ! command -v openssl &>/dev/null; then
        echo -e "${YELLOW}未检测到 openssl，正在尝试安装...${RESET}"
        apt-get update && apt-get install -y openssl || yum install -y openssl
    fi
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! $DOCKER_CMD version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2，请升级 Docker${RESET}"
        exit 1
    fi
}

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

check_ipv6_support() {
    if ping6 -c 1 ::1 &>/dev/null; then
        return 0
    else
        return 1
    fi
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

configure_docker_ipv6() {
    if [ ! -f /etc/docker/daemon.json ]; then
        echo '{}' > /etc/docker/daemon.json
    fi

    # 兼容处理非标准或空白 json
    if ! jq '.' /etc/docker/daemon.json &>/dev/null; then
        echo '{}' > /etc/docker/daemon.json
    fi

    local IPV6_ENABLED
    # 避免 jq 读取 null 报错
    纯IPV6_ENABLED=$(jq '.ipv6 // false' /etc/docker/daemon.json 2>/dev/null)
    if [ "$IPV6_ENABLED" = "true" ]; then
        echo -e "${GREEN}✅ Docker 已启用 IPv6，无需重复配置${RESET}"
        return
    fi

    jq '. + {ipv6:true, "fixed-cidr-v6":"fd00:dead:beef::/48"}' /etc/docker/daemon.json > /tmp/daemon.json.tmp
    mv /tmp/daemon.json.tmp /etc/docker/daemon.json

    systemctl restart docker
    echo -e "${GREEN}✅ Docker IPv6 已启用并重启服务${RESET}"
}

# 代理轮询下载通用函数
download_file() {
    local url="$1"
    local output="$2"
    local success=false

    for proxy in "${GITHUB_PROXY[@]}"; do
        local target_url="${proxy}${url}"
        if [ -n "$proxy" ]; then
            echo "📡 正在尝试通过代理下载: ${proxy}"
        else
            echo "📡 正在尝试直连下载..."
        fi
        
        curl -L -k --max-time 15 -o "$output" "$target_url"
        
        if [ -s "$output" ]; then
            success=true
            break
        else
            rm -f "$output"
        fi
    done

    if [ "$success" = true ]; then
        return 0
    else
        return 1
    fi
}

install_app() {
    check_dependencies
    check_docker
    mkdir -p "$APP_DIR"
    cd "$APP_DIR" || exit

    # 下载数据库初始化文件
    echo "📡 准备下载数据库初始化文件..."
    if [ ! -f gost.sql ] || [ ! -s gost.sql ]; then
        if ! download_file "$GOST_SQL_URL" "gost.sql"; then
            echo -e "${RED}❌ 数据库文件所有下载通道均失败，请检查网络或 URL: $GOST_SQL_URL${RESET}"
            read -p "按回车返回菜单..."
            return
        fi
    fi
    echo -e "${GREEN}✅ 数据库文件准备完成${RESET}"

    # 设置端口
    read -p "请输入前端端口 [默认:6366]: " input_front
    FRONTEND_PORT=${input_front:-6366}
    check_port "$FRONTEND_PORT" || return

    read -p "请输入后端端口 [默认:6365]: " input_back
    BACKEND_PORT=${input_back:-6365}
    check_port "$BACKEND_PORT" || return

    # 设置数据库账户
    read -p "请输入数据库用户名 [默认:gost]: " input_user
    DB_USER=${input_user:-gost}
    read -p "请输入数据库名 [默认:gost]: " input_db
    DB_NAME=${input_db:-gost}
    read -p "请输入数据库密码 [默认:123456]: " input_pass
    DB_PASSWORD=${input_pass:-123456}

    # JWT secret
    JWT_SECRET=$(openssl rand -hex 16)

    # 检测 IPv6
    ENABLE_IPV6=true # 显式初始化默认值
    if check_ipv6_support; then
        echo -e "${GREEN}🚀 系统支持 IPv6，自动启用 IPv6 配置...${RESET}"
        configure_docker_ipv6
    else
        echo -e "${YELLOW}⚠️ 系统不支持 IPv6，跳过配置${RESET}"
        ENABLE_IPV6=false
    fi

    # 用户手动确认 IPv6 开关
    read -p "是否启用 Docker 内部容器 IPv6 网络? [Y/n] (默认开启): " ipv6_input
    if [[ "$ipv6_input" =~ ^[Nn]$ ]]; then
        ENABLE_IPV6=false
    fi

    # 生成 .env
    cat > .env <<EOF
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
JWT_SECRET=$JWT_SECRET
FRONTEND_PORT=$FRONTEND_PORT
BACKEND_PORT=$BACKEND_PORT
EOF
    echo -e "${GREEN}✅ .env 文件生成完成${RESET}"

    # 生成 docker-compose.yml (注意转义了 \$ 符号，以便正确读取 .env 文件)
    cat > "$COMPOSE_FILE" <<EOF
services:
  mysql:
    image: mysql:5.7
    container_name: gost-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: \${DB_PASSWORD}
      MYSQL_DATABASE: \${DB_NAME}
      MYSQL_USER: \${DB_USER}
      MYSQL_PASSWORD: \${DB_PASSWORD}
      TZ: Asia/Shanghai
    volumes:
      - mysql_data:/var/lib/mysql
      - ./gost.sql:/docker-entrypoint-initdb.d/init.sql:ro
    command: >
      --default-authentication-plugin=mysql_native_password
      --character-set-server=utf8mb4
      --collation-server=utf8mb4_unicode_ci
      --max_connections=1000
      --innodb_buffer_pool_size=256M
    networks:
      - gost-network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      timeout: 10s
      retries: 10

  backend:
    image: bqlpfy/springboot-backend:1.4.3
    container_name: springboot-backend
    restart: unless-stopped
    environment:
      DB_HOST: mysql
      DB_NAME: \${DB_NAME}
      DB_USER: \${DB_USER}
      DB_PASSWORD: \${DB_PASSWORD}
      JWT_SECRET: \${JWT_SECRET}
      LOG_DIR: /app/logs
      JAVA_OPTS: "-Xms256m -Xmx512m -Dfile.encoding=UTF-8 -Duser.timezone=Asia/Shanghai"
    ports:
      - "\${BACKEND_PORT}:6365"
    volumes:
      - backend_logs:/app/logs
    depends_on:
      mysql:
        condition: service_healthy
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
      - "\${FRONTEND_PORT}:80"
    depends_on:
      backend:
        condition: service_healthy
    networks:
      - gost-network

volumes:
  mysql_data:
    name: mysql_data
    driver: local
  backend_logs:
    name: backend_logs
    driver: local
EOF

    # 动态追加网络配置
    if [ "$ENABLE_IPV6" = true ]; then
cat >> "$COMPOSE_FILE" <<EOF

networks:
  gost-network:
    name: gost-network
    driver: bridge
    enable_ipv6: true
    ipam:
      config:
        - subnet: 172.20.0.0/16
        - subnet: fd00:dead:beef::/48
EOF
    else
cat >> "$COMPOSE_FILE" <<EOF

networks:
  gost-network:
    name: gost-network
    driver: bridge
EOF
    fi

    $DOCKER_CMD up -d

    SERVER_IP=$(get_public_ip)

    echo -e "${GREEN}✅ 哆啦A梦转发面板 已启动${RESET}"
    echo -e "${YELLOW}🌐 前端访问: http://${SERVER_IP}:${FRONTEND_PORT}${RESET}"
    echo -e "${YELLOW}🌐 后端访问: http://${SERVER_IP}:${BACKEND_PORT}${RESET}"
    echo -e "${YELLOW}🌐 默认账号: admin_user${RESET}"
    echo -e "${YELLOW}🌐 默认密码: admin_user${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    $DOCKER_CMD pull
    $DOCKER_CMD up -d
    echo -e "${GREEN}✅ 哆啦A梦转发面板 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart gost-mysql springboot-backend vite-frontend
    echo -e "${GREEN}✅ 哆啦A梦转发面板 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${GREEN}选择容器查看日志:${RESET}"
    echo "1) MySQL"
    echo "2) Backend"
    echo "3) Frontend"
    read -p "选择: " c
    case $c in
        1) docker logs -f gost-mysql ;;
        2) docker logs -f springboot-backend ;;
        3) docker logs -f vite-frontend ;;
        *) echo -e "${RED}无效选择${RESET}" ;;
    esac
}

check_status() {
    docker ps | grep -E "gost-mysql|springboot-backend|vite-frontend"
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    $DOCKER_CMD down -v
    cd /opt && rm -rf "$APP_DIR"
    echo -e "${RED}✅ 哆啦A梦转发面板 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

manage_nodes() {
    echo "📡 正在获取节点管理..."
    if download_file "$NODE_SCRIPT_URL" "node_install.sh"; then
        chmod +x node_install.sh
        ./node_install.sh
        rm -f node_install.sh
    else
        echo -e "${RED}❌ 无法安装节点管理，请检查网络！${RESET}"
        read -p "按回车返回菜单..."
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}============================${RESET}"
        echo -e "${GREEN}  ◈   哆啦A梦转发面板   ◈   ${RESET}"
        echo -e "${GREEN}============================${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${YELLOW}7) 节点管理${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        echo -e "${GREEN}============================${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            7) manage_nodes ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

# 启动菜单
menu
