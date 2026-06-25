#!/bin/bash
# =================================================================
# Remnawave Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="remnawave"
BASE_DIR="/opt/remnawave"
COMPOSE_FILE="$BASE_DIR/docker-compose.yaml"
ENV_FILE="$BASE_DIR/.env"

# Nginx 路径缺省值配置
NGINX_AVAILABLE_DIR="${NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
NGINX_ENABLED_DIR="${NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
USE_SITES_STRUCTURE="${USE_SITES_STRUCTURE:-true}"

if [ "$USE_SITES_STRUCTURE" = false ] || [ ! -d "$NGINX_AVAILABLE_DIR" ]; then
    NGINX_AVAILABLE_DIR="/etc/nginx/conf.d"
fi

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态和端口
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 优先从容器元数据获取 3000/tcp 映射到宿主机的实际端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        # 如果获取失败，则尝试从本地 .env 文件读取
        if [[ -z "$webui_port" && -f "$ENV_FILE" ]]; then
            webui_port=$(grep "^APP_PORT=" "$ENV_FILE" | cut -d'=' -f2)
        fi
        [[ -z "$webui_port" ]] && webui_port="3000"
    else
        webui_port="N/A"
    fi
}

# 部署 Remnawave
install_remnawave() {
    check_dependencies
    if [ -d "$BASE_DIR" ] && [ -f "$COMPOSE_FILE" ]; then
        echo -e "${RED}提示: 检测到目录 $BASE_DIR 已存在配置文件！${RESET}"
        echo -ne "${YELLOW}是否覆盖重新部署？(y/n): ${RESET}"
        read -r re_confirm
        if [[ "$re_confirm" != "y" && "$re_confirm" != "Y" ]]; then return; fi
    fi

    mkdir -p "$BASE_DIR"
    echo -e "${CYAN}====== 1. 数据库 (PostgreSQL) 类型选择 ======${RESET}"
    echo -e "${GREEN}1. 本地容器模式 (自动创建内置的 PostgreSQL 17)${RESET}"
    echo -e "${GREEN}2. 远程数据库模式 (连接外部/云 PostgreSQL 数据库)${RESET}"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    echo -e "${CYAN}====== 2. 缓存 (Redis) 类型选择 ======${RESET}"
    echo -e "${GREEN}1. 本地容器模式 (自动创建内置的高性能 Valkey/Redis)${RESET}"
    echo -e "${GREEN}2. 远程 Redis 模式 (连接外部公用/云 Redis)${RESET}"
    echo -ne "${YELLOW}请选择 Redis 模式 [默认: 1]: ${RESET}"
    read -r redis_mode
    [[ -z "$redis_mode" ]] && redis_mode="1"

    echo -e "${CYAN}====== 3. 自定义宿主机端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入面板访问映射端口 (APP_PORT) [默认: 3000]: ${RESET}"
    read -r custom_app_port
    [[ -z "$custom_app_port" ]] && custom_app_port="3000"

    echo -ne "${YELLOW}请输入指标监控映射端口 (METRICS_PORT) [默认: 3001]: ${RESET}"
    read -r custom_metrics_port
    [[ -z "$custom_metrics_port" ]] && custom_metrics_port="3001"

    echo -e "${CYAN}====== 4. 核心域名配置 ======${RESET}"
    echo -ne "${YELLOW}请输入面板访问域名 (FRONT_END_DOMAIN) [例如: panel.example.com]: ${RESET}"
    read -r front_domain
    if [[ -z "$front_domain" ]]; then echo -e "${RED}错误: 域名不能为空！${RESET}"; return; fi
    sub_domain="${front_domain}/api/sub"

    local db_url="" local has_local_db="true" local db_user="postgres"
    local db_pass=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1) local db_name="postgres"

    if [[ "$db_mode" == "2" ]]; then
        has_local_db="false"
        echo -e "${CYAN}====== 远程 PostgreSQL 配置 ======${RESET}"
        echo -ne "${YELLOW}请输入远程数据库 IP/域名: ${RESET}"
        read -r r_host
        echo -ne "${YELLOW}请输入远程数据库 端口 [默认: 5432]: ${RESET}"
        read -r r_port
        [[ -z "$r_port" ]] && r_port="5432"
        echo -ne "${YELLOW}请输入远程数据库 用户名 [默认: postgres]: ${RESET}"
        read -r r_user
        [[ -z "$r_user" ]] && r_user="postgres"
        echo -ne "${YELLOW}请输入远程数据库 密码: ${RESET}"
        read -r r_pass
        echo -ne "${YELLOW}请输入远程数据库 数据库名 [默认: postgres]: ${RESET}"
        read -r r_name
        [[ -z "$r_name" ]] && r_name="postgres"
        if [[ -z "$r_host" || -z "$r_pass" ]]; then echo -e "${RED}错误: 远程数据库地址和密码不能为空！${RESET}"; return; fi
        db_url="postgresql://${r_user}:${r_pass}@${r_host}:${r_port}/${r_name}"
        db_user="$r_user"; db_pass="$r_pass"; db_name="$r_name"
    else
        db_url="postgresql://postgres:${db_pass}@remnawave-db:5432/postgres"
    fi

    local has_local_redis="true" local env_redis_cfg=""
    if [[ "$redis_mode" == "2" ]]; then
        has_local_redis="false"
        echo -e "${CYAN}====== 远程 Redis 配置 ======${RESET}"
        echo -ne "${YELLOW}请输入远程 Redis IP/域名: ${RESET}"
        read -r rd_host
        echo -ne "${YELLOW}请输入远程 Redis 端口 [默认: 6379]: ${RESET}"
        read -r rd_port
        [[ -z "$rd_port" ]] && rd_port="6379"
        echo -ne "${YELLOW}请输入远程 Redis 密码 (无密码直接回车): ${RESET}"
        read -r rd_pass
        echo -ne "${YELLOW}请输入 Redis 分区编号 (DB Index) [0-15, 默认: 0]: ${RESET}"
        read -r rd_db
        [[ -z "$rd_db" ]] && rd_db="0"
        if [[ -z "$rd_host" ]]; then echo -e "${RED}错误: 远程 Redis 地址不能为空！${RESET}"; return; fi
        env_redis_cfg="REDIS_HOST=${rd_host}\nREDIS_PORT=${rd_port}\nREDIS_DB=${rd_db}"
        if [[ -n "$rd_pass" ]]; then env_redis_cfg="${env_redis_cfg}\nREDIS_PASSWORD=${rd_pass}"; fi
    else
        env_redis_cfg="REDIS_SOCKET=/var/run/valkey/valkey.sock"
    fi

    jwt_secret_1=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
    jwt_secret_2=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)

    echo -e "${YELLOW}正在定制创建 docker-compose.yaml...${RESET}"
    
    local ext_remnawave_volumes=""
    local ext_depends_on=""
    local ext_redis_service=""
    local ext_db_service=""
    local ext_volumes_footer=""

    if [[ "$has_local_redis" == "true" ]]; then
        ext_remnawave_volumes="    volumes:
      - valkey-socket:/var/run/valkey"
        
        ext_redis_service="  remnawave-redis:
    image: valkey/valkey:9-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    <<: [*common, *logging]
    volumes:
      - valkey-socket:/var/run/valkey
    command: >
      valkey-server --save \"\" --appendonly no --maxmemory-policy noeviction --loglevel warning
      --unixsocket /var/run/valkey/valkey.sock --unixsocketperm 777 --port 0
    healthcheck:
      test: ['CMD', 'valkey-cli', '-s', '/var/run/valkey/valkey.sock', 'ping']
      interval: 3s
      timeout: 3s
      retries: 3"
        ext_volumes_footer="${ext_volumes_footer}\n  valkey-socket:\n    name: valkey-socket\n    driver: local"
    fi

    if [[ "$has_local_db" == "true" ]]; then
        ext_db_service="  remnawave-db:
    image: postgres:17.6
    container_name: remnawave-db
    hostname: remnawave-db
    <<: [*common, *logging, *env]
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports:
      - 127.0.0.1:6767:5432
    volumes:
      - remnawave-db-data:/var/lib/postgresql/data
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3"
        ext_volumes_footer="${ext_volumes_footer}\n  remnawave-db-data:\n    name: remnawave-db-data\n    driver: local"
    fi

    if [[ "$has_local_db" == "true" || "$has_local_redis" == "true" ]]; then
        ext_depends_on="    depends_on:"
        [[ "$has_local_db" == "true" ]] && ext_depends_on="${ext_depends_on}\n      remnawave-db:\n        condition: service_healthy"
        [[ "$has_local_redis" == "true" ]] && ext_depends_on="${ext_depends_on}\n      remnawave-redis:\n        condition: service_healthy"
    fi

    # 最终的单次完整写入
    cat << EOF > "$COMPOSE_FILE"
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always
  networks:
    - remnawave-network

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: 5

x-env: &env
  env_file: .env

services:
  remnawave:
    image: remnawave/backend:2
    container_name: remnawave
    hostname: remnawave
    <<: [*common, *logging, *env]
$(echo -e "$ext_remnawave_volumes")
    ports:
      - 127.0.0.1:\${APP_PORT:-3000}:3000
      - 127.0.0.1:\${METRICS_PORT:-3001}:3001
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:3001/health']
      interval: 3s
      timeout: 5s
      retries: 3
      start_period: 30s
$(echo -e "$ext_depends_on")

$(echo -e "$ext_redis_service")

$(echo -e "$ext_db_service")

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: false

volumes:
$(echo -e "$ext_volumes_footer")
EOF

    echo -e "${YELLOW}正在创建 .env 配置文件...${RESET}"
    cat << EOF > "$ENV_FILE"
APP_PORT=${custom_app_port}
METRICS_PORT=${custom_metrics_port}
API_INSTANCES=1
DATABASE_URL="${db_url}"
$(echo -e "$env_redis_cfg")
JWT_AUTH_SECRET=${jwt_secret_1}
JWT_API_TOKENS_SECRET=${jwt_secret_2}
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
PANEL_DOMAIN=${front_domain}
FRONT_END_DOMAIN=${front_domain}
SUB_PUBLIC_DOMAIN=${sub_domain}
SWAGGER_PATH=/docs
SCALAR_PATH=/scalar
IS_DOCS_ENABLED=false
METRICS_USER=admin
METRICS_PASS=admin
WEBHOOK_ENABLED=false
POSTGRES_USER=${db_user}
POSTGRES_PASSWORD=${db_pass}
POSTGRES_DB=${db_name}
EOF

    cd "$BASE_DIR" && docker compose up -d
    echo -e "${GREEN}Remnawave 核心服务部署成功！${RESET}"
}

configure_nginx_proxy() {
    get_status_info
    if [[ "$webui_port" == "N/A" ]]; then
        echo -e "${RED}错误: Remnawave 容器未运行，请先执行选项 1 部署服务！${RESET}"
        return
    fi

    echo -e "${CYAN}====== 配置 Remnawave 面板 Nginx 反向代理 ======${RESET}"
    echo -ne "${YELLOW}请输入 Remnawave 面板规划域名 (如: panel.example.com): ${RESET}"
    read -r domain
    if [[ -z "$domain" ]]; then echo -e "${RED}域名不能为空！${RESET}"; return; fi

    local default_cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
    local default_key="/etc/letsencrypt/live/${domain}/privkey.pem"

    echo -ne "${YELLOW}请输入 SSL 证书路径 [直接回车使用默认: ${default_cert}]: ${RESET}"
    read -r app_cert
    [[ -z "$app_cert" ]] && app_cert="$default_cert"

    echo -ne "${YELLOW}请输入 SSL 私钥路径 [直接回车使用默认: ${default_key}]: ${RESET}"
    read -r app_key
    [[ -z "$app_key" ]] && app_key="$default_key"

    local panel_conf_file="${NGINX_AVAILABLE_DIR}/${domain}"
    [[ "$USE_SITES_STRUCTURE" = false ]] && panel_conf_file="${panel_conf_file}.conf"

    cat << EOF > "$panel_conf_file"
# =============================================================
# 自动生成：Remnawave 面板的 Nginx 反向代理与安全配置
# =============================================================
upstream remnawave {
    server 127.0.0.1:${webui_port};
}

server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    server_name ${domain};

    listen 443 ssl http2;
    listen [::]:443 ssl http2;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    ssl_protocols          TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;

    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets    off;

    ssl_certificate "${app_cert}";
    ssl_certificate_key "${app_key}";

    resolver               1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 valid=60s;
    resolver_timeout       2s;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_min_length 256;
    gzip_types
        application/atom+xml
        application/geo+json
        application/javascript
        application/x-javascript
        application/json
        application/ld+json
        application/manifest+json
        application/rdf+xml
        application/rss+xml
        application/xhtml+xml
        application/xml
        font/eot
        font/otf
        font/ttf
        image/svg+xml
        text/css
        text/javascript
        text/plain
        text/xml;
}
EOF

    if [ "$USE_SITES_STRUCTURE" = true ] && [ -d "$NGINX_ENABLED_DIR" ]; then
        ln -sf "$panel_conf_file" "${NGINX_ENABLED_DIR}/${domain}"
    fi

    echo -e "${GREEN}Remnawave 代理配置文件已成功写入: $panel_conf_file${RESET}"
    
    if nginx -t &>/dev/null; then
        systemctl reload nginx
        echo -e "${GREEN}Nginx 验证通过并已顺利热重载！面板代理全面上线！${RESET}"
        echo -e "${YELLOW}面板安全访问地址: https://${domain}${RESET}"
    else
        echo -e "${RED}警告: Nginx 语法测试失败！请确保刚刚填写的证书路径文件存在且 Nginx 有读取权限！${RESET}"
    fi
}

update_remnawave() { cd "$BASE_DIR" && docker compose pull && docker compose up -d --remove-orphans && echo -e "${GREEN}更新完成！${RESET}"; }
uninstall_remnawave() {
    echo -ne "${YELLOW}确定要卸载吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        cd "$BASE_DIR" 2>/dev/null && docker compose down -v 2>/dev/null
        rm -rf "$BASE_DIR"
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_remnawave() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_remnawave() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_remnawave() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_remnawave() { cd "$BASE_DIR" && docker compose logs -f; }

how_info() {
    get_status_info
    if [ -f "$ENV_FILE" ]; then
        f_dom=$(grep FRONT_END_DOMAIN "$ENV_FILE" | cut -d'=' -f2)
        s_dom=$(grep SUB_PUBLIC_DOMAIN "$ENV_FILE" | cut -d'=' -f2)
    fi
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}内部映射端口   : ${webui_port}${RESET}"
    echo -e "${YELLOW}面板前端域名   : ${f_dom:-N/A}${RESET}"
    echo -e "${YELLOW}订阅公开域名   : ${s_dom:-N/A}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear; get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  Remnawave 容器管理面板 ◈    ${RESET}"
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
    echo -e "${GREEN}9. 反向代理${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_remnawave ;;
        2) update_remnawave ;;
        3) uninstall_remnawave ;;
        4) start_remnawave ;;
        5) stop_remnawave ;;
        6) restart_remnawave ;;
        7) logs_remnawave ;;
        8) show_info ;;
        9) configure_nginx_proxy ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do menu; echo -ne "${YELLOW}按回车键继续...${RESET}"; read -r; done
