#!/bin/bash
# =================================================================
# DuJiaoNext (独角数卡) Docker Compose 统一管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/dujiao-next"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
CONFIG_FILE="$BASE_DIR/config/config.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 提取运行状态和端口
get_status_info() {
    if [ -f "$COMPOSE_FILE" ] && [ "$(cd "$BASE_DIR" && docker compose ps -q 2>/dev/null)" ]; then
        status="${GREEN}运行中${RESET}"
        
        # 抓取单实例服务的映射端口
        app_p=$(docker inspect --format='{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' dujiaonext-server 2>/dev/null)
    else
        if [ -f "$ENV_FILE" ]; then status="${RED}已停止${RESET}"; else status="${RED}未部署${RESET}" ; fi
    fi

    if [ -z "$app_p" ] || [ "$app_p" = "<no value>" ]; then
        if [ -f "$ENV_FILE" ]; then
            app_p=$(grep "APP_PORT=" "$ENV_FILE" | cut -d'=' -f2)
        else
            app_p="N/A"
        fi
    fi
}

# 产生随机字符串
generate_random_str() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w "${1:-32}" | head -n 1
}

# 部署 DuJiaoNext 核心逻辑
install_dujiao() {
    check_dependencies
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  请选择 DuJiaoNext 数据库架构: ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${CYAN}1. 方案 A：SQLite + Redis (轻量本地化推荐)${RESET}"
    echo -e "${CYAN}2. 方案 B：PostgreSQL + Redis (本地容器自建集群)${RESET}"
    echo -e "${CYAN}3. 方案 C：连接远程/外部独立 PostgreSQL (本地带 Redis)${RESET}"
    echo -e "${CYAN}4. 方案 D：远程 PostgreSQL + 远程 Redis (完全分离模式)${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${YELLOW}请输入编号 [1-4]: ${RESET}"
    read -r db_choice

    if [[ "$db_choice" != "1" && "$db_choice" != "2" && "$db_choice" != "3" && "$db_choice" != "4" ]]; then
        echo -e "${RED}输入有误，取消部署。${RESET}"
        return
    fi

    local remote_dsn=""
    if [[ "$db_choice" == "3" || "$db_choice" == "4" ]]; then
        echo -e "${CYAN}--- 远程 PostgreSQL 数据库连接配置 ---${RESET}"
        echo -ne "${YELLOW}请输入远程数据库 主机IP/域名: ${RESET}"
        read -r remote_host
        echo -ne "${YELLOW}请输入远程数据库 端口 [默认: 5432]: ${RESET}"
        read -r remote_port
        [[ -z "$remote_port" ]] && remote_port="5432"
        echo -ne "${YELLOW}请输入远程数据库 用户名: ${RESET}"
        read -r remote_user
        echo -ne "${YELLOW}请输入远程数据库 密码: ${RESET}"
        read -r remote_pass
        echo -ne "${YELLOW}请输入远程数据库 数据库名: ${RESET}"
        read -r remote_dbname

        remote_dsn="host=${remote_host} user=${remote_user} password=${remote_pass} dbname=${remote_dbname} port=${remote_port} sslmode=disable TimeZone=Asia/Shanghai"
    fi

    local redis_host_cfg="redis"
    local redis_port_cfg="6379"
    local redis_pass_cfg=$(generate_random_str 16)
    local redis_db_cfg="0"
    local redis_queue_db_cfg="1"

    if [[ "$db_choice" == "4" ]]; then
        echo -e "${CYAN}--- 远程 Redis 缓存连接配置 ---${RESET}"
        echo -ne "${YELLOW}请输入远程 Redis 主机IP/域名 [默认: 127.0.0.1]: ${RESET}"
        read -r redis_host_cfg
        [[ -z "$redis_host_cfg" ]] && redis_host_cfg="127.0.0.1"

        echo -ne "${YELLOW}请输入远程 Redis 端口 [默认: 6379]: ${RESET}"
        read -r redis_port_cfg
        [[ -z "$redis_port_cfg" ]] && redis_port_cfg="6379"

        echo -ne "${YELLOW}请输入远程 Redis 密码 (若无密码请直接回车): ${RESET}"
        read -r redis_pass_cfg

        echo -ne "${YELLOW}请输入远程 Redis 缓存型数据库号 (DB ID) [默认: 0]: ${RESET}"
        read -r redis_db_cfg
        [[ -z "$redis_db_cfg" ]] && redis_db_cfg="0"

        echo -ne "${YELLOW}请输入远程 Redis 队列型数据库号 (DB ID) [默认: 1]: ${RESET}"
        read -r redis_queue_db_cfg
        [[ -z "$redis_queue_db_cfg" ]] && redis_queue_db_cfg="1"
    fi

    echo -e "${CYAN}====== 自定义基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入安装绝对路径 [默认: /opt/dujiao-next]: ${RESET}"
    read -r custom_dir
    [[ -z "$custom_dir" ]] && custom_dir="/opt/dujiao-next"
    BASE_DIR="$custom_dir"
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
    CONFIG_FILE="$BASE_DIR/config/config.yml"
    ENV_FILE="$BASE_DIR/.env"

    echo -ne "${YELLOW}请输入单进程服务映射端口 [默认: 8080]: ${RESET}"
    read -r app_port
    [[ -z "$app_port" ]] && app_port="8080"

    echo -ne "${YELLOW}请输入自定义后台安全路径 [默认: /admin]: ${RESET}"
    read -r admin_path
    [[ -z "$admin_path" ]] && admin_path="/admin"

    echo -ne "${YELLOW}设置首次初始化管理员密码 [默认: admin123]: ${RESET}"
    read -r admin_pwd
    [[ -z "$admin_pwd" ]] && admin_pwd="admin123"

    # 1. 创建持久化目录
    echo -e "${YELLOW}正在建立并授权本地持久化目录...${RESET}"
    mkdir -p "$BASE_DIR/config" "$BASE_DIR/data/db" "$BASE_DIR/data/uploads" "$BASE_DIR/data/logs" "$BASE_DIR/data/redis" "$BASE_DIR/data/postgres"
    chmod -R 0777 "$BASE_DIR/data"

    # 2. 生成必需的三组独立强密钥
    local app_secret_key=$(generate_random_str 32)
    local jwt_secret=$(generate_random_str 32)
    local user_jwt_secret=$(generate_random_str 32)
    local local_pg_pass=$(generate_random_str 16)

    # 3. 动态配置 config.yml 
    echo -e "${YELLOW}正在安全加密并生成统一生产配置文件 (config.yml)...${RESET}"
    cat <<EOF > "$CONFIG_FILE"
app:
  env: production
  secret_key: "${app_secret_key}"
  totp_issuer: "Dujiao-Next"

server:
  host: "0.0.0.0"
  port: 8080
  mode: "release"

log:
  dir: ""
  filename: "app.log"
  max_size_mb: 100
  max_backups: 7
  max_age_days: 30
  compress: true

jwt:
  secret: "${jwt_secret}"
  expire_hours: 24

user_jwt:
  secret: "${user_jwt_secret}"
  expire_hours: 24
  remember_me_expire_hours: 168

redis:
  enabled: true
  host: "${redis_host_cfg}"
  port: ${redis_port_cfg}
  password: "${redis_pass_cfg}"
  db: ${redis_db_cfg}
  prefix: "dj"

queue:
  enabled: true
  host: "${redis_host_cfg}"
  port: ${redis_port_cfg}
  password: "${redis_pass_cfg}"
  db: ${redis_queue_db_cfg}
  concurrency: 10
  queues:
    default: 10
    critical: 5
  upstream_sync_interval: "5m"

upload:
  max_size: 10485760
  allowed_types:
    - image/jpeg
    - image/png
    - image/gif
    - image/webp
    - image/svg+xml
  allowed_extensions:
    - .jpg
    - .jpeg
    - .png
    - .gif
    - .webp
    - .svg
  max_width: 4096
  max_height: 4096

cors:
  allowed_origins:
    - "*"
  allowed_methods:
    - GET
    - POST
    - PUT
    - PATCH
    - DELETE
    - OPTIONS
  allowed_headers:
    - Content-Type
    - Content-Length
    - Accept-Encoding
    - Authorization
    - Cache-Control
    - X-Requested-With
    - X-CSRF-Token
  allow_credentials: true
  max_age: 600

security:
  login_rate_limit:
    window_seconds: 300
    max_attempts: 5
    block_seconds: 900
  password_policy:
    min_length: 8
    require_upper: true
    require_lower: true
    require_number: true
    require_special: false

email:
  enabled: false
  host: ""
  port: 465
  username: ""
  password: ""
  from: ""
  from_name: ""
  use_tls: false
  use_ssl: true
  verify_code:
    expire_minutes: 10
    send_interval_seconds: 60
    max_attempts: 5
    length: 6

order:
  payment_expire_minutes: 15
  max_refund_days: 30

reseller:
  enabled: false
  main_hosts:
    - localhost
    - 127.0.0.1
    - "::1"
  trusted_forwarded_host: false
  subdomain_base: ""
  self_apply_enabled: true
  settlement_confirm_days: 7

web:
  admin_path: "${admin_path}"
EOF

    if [ "$db_choice" = "1" ]; then
        cat <<EOF >> "$CONFIG_FILE"
database:
  driver: sqlite
  dsn: /app/db/dujiao.db
EOF
    elif [ "$db_choice" = "2" ]; then
        cat <<EOF >> "$CONFIG_FILE"
database:
  driver: postgres
  dsn: host=postgres user=dujiao password=${local_pg_pass} dbname=dujiao_next port=5432 sslmode=disable TimeZone=Asia/Shanghai
EOF
    elif [[ "$db_choice" == "3" || "$db_choice" == "4" ]]; then
        cat <<EOF >> "$CONFIG_FILE"
database:
  driver: postgres
  dsn: "${remote_dsn}"
EOF
    fi

    # 4. 生成 .env 文件
    cat <<EOF > "$ENV_FILE"
TAG=latest
TZ=Asia/Shanghai
APP_PORT=${app_port}
DJ_DEFAULT_ADMIN_USERNAME=admin
DJ_DEFAULT_ADMIN_PASSWORD=${admin_pwd}
REDIS_PASSWORD=${redis_pass_cfg}
POSTGRES_DB=dujiao_next
POSTGRES_USER=dujiao
POSTGRES_PASSWORD=${local_pg_pass}
EOF

    # 5. 生成单实例交付的 docker-compose.yml
    local compose_content="services:"

    if [ "$db_choice" != "4" ]; then
        compose_content="${compose_content}
  redis:
    image: redis:7-alpine
    container_name: dujiaonext-redis
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: \${REDIS_PASSWORD}
    command: [\"redis-server\", \"--appendonly\", \"yes\", \"--requirepass\", \"\${REDIS_PASSWORD}\"]
    volumes:
      - ./data/redis:/data
    healthcheck:
      test: [\"CMD\", \"redis-cli\", \"-a\", \"\${REDIS_PASSWORD}\", \"ping\"]
      interval: 10s
      timeout: 3s
      retries: 10
    networks:
      - dujiao-net"
    fi

    if [ "$db_choice" = "2" ]; then
        compose_content="${compose_content}

  postgres:
    image: postgres:16-alpine
    container_name: dujiaonext-postgres
    restart: unless-stopped
    environment:
      TZ: \${TZ}
      POSTGRES_DB: \${POSTGRES_DB}
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: [\"CMD-SHELL\", \"pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}\"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - dujiao-net"
    fi

    # 单二进制主服务定义 (合并前后端为单容器)
    compose_content="${compose_content}

  server:
    image: dujiaonext/dujiao-next:\${TAG}
    container_name: dujiaonext-server
    restart: unless-stopped
    environment:
      TZ: \${TZ}
      DJ_DEFAULT_ADMIN_USERNAME: \${DJ_DEFAULT_ADMIN_USERNAME}
      DJ_DEFAULT_ADMIN_PASSWORD: \${DJ_DEFAULT_ADMIN_PASSWORD}
    ports:
      - \"127.0.0.1:\${APP_PORT}:8080\"
    volumes:
      - ./config/config.yml:/app/config.yml:ro"

    if [ "$db_choice" = "1" ]; then
        compose_content="${compose_content}
      - ./data/db:/app/db"
    fi

    compose_content="${compose_content}
      - ./data/uploads:/app/uploads
      - ./data/logs:/app/logs"

    if [ "$db_choice" != "4" ]; then
        compose_content="${compose_content}
    depends_on:
      redis:
        condition: service_healthy"
        if [ "$db_choice" = "2" ]; then
            compose_content="${compose_content}
      postgres:
        condition: service_healthy"
        fi
    fi

    compose_content="${compose_content}
    healthcheck:
      test: [\"CMD\", \"wget\", \"-qO-\", \"http://127.0.0.1:8080/health\"]
      interval: 10s
      timeout: 3s
      retries: 10
    networks:
      - dujiao-net

networks:
  dujiao-net:
    driver: bridge"

    echo "$compose_content" > "$COMPOSE_FILE"

    # 6. 启动容器
    echo -e "${YELLOW}正在启动 DuJiaoNext 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务健康自检 (约8秒)...${RESET}"
    sleep 8

    # 从 config.yml 中安全读取创建好的动态 admin_path
    local current_admin_path=$(grep "admin_path:" "$CONFIG_FILE" | awk '{print $2}' | tr -d '"')

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     DuJiaoNext 部署成功！      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}前台访问 (本机) : http://127.0.0.1:${app_port}${RESET}"
    echo -e "${YELLOW}后台访问 (本机) : http://127.0.0.1:${app_port}${current_admin_path}${RESET}"
    echo -e "${RED}🔒 核心提示：服务默认仅监听 127.0.0.1。${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${YELLOW}初始管理员账号 : admin${RESET}"
    echo -e "${YELLOW}初始管理员密码 : ${admin_pwd}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_dujiao() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！请注意清除浏览器缓存以加载新版前端。${RESET}"
}

# 彻底卸载
uninstall_dujiao() {
    echo -ne "${RED}警告：确认要完全卸载并停止独角数卡服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器集群已安全销毁。${RESET}"
            echo -ne "${YELLOW}是否同时抹除本地数据库、上传资源和日志？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}所有物理持久化数据已彻底抹除。${RESET}"
            fi
        else
            docker rm -f dujiaonext-server dujiaonext-redis dujiaonext-postgres 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_dujiao() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}集群已恢复启动${RESET}"; }
stop_dujiao() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}集群已受控停止${RESET}"; }
restart_dujiao() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}集群已完整重启${RESET}"; }

# 查看日志
logs_dujiao() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到部署集群，无法提取日志。${RESET}"
        return
    fi
    cd "$BASE_DIR" && docker compose logs -f server
}

# 安全清理旧配置辅助
safe_remove_old_conf() {
    local domain=$1
    local paths=("/etc/nginx/sites-enabled/$domain" "/etc/nginx/sites-available/$domain" "/etc/nginx/conf.d/$domain.conf")
    sudo mkdir -p /tmp/nginx_bak/ 2>/dev/null

    for path in "${paths[@]}"; do
        if [ -f "$path" ] || [ -L "$path" ]; then
            local filename=$(basename "$path")
            local parent_dir=$(basename "$(dirname "$path")")
            echo -e "${YELLOW}发现冲突旧配置: $path，正在备份至 /tmp/nginx_bak/ ...${RESET}"
            sudo mv "$path" "/tmp/nginx_bak/${parent_dir}_${filename}" 2>/dev/null
        fi
    done
}

# 自动配置 Nginx 反代逻辑
configure_nginx() {
    get_status_info
    if [ "$app_p" = "N/A" ]; then
        echo -e "${RED}错误: 未检测到有效的部署参数，请先执行选项 1 部署服务。${RESET}"
        return
    fi

    clear
    echo -e "${GREEN}=====================================================${RESET}"
    echo -e "${GREEN}         DuJiaoNext  Nginx配置          ${RESET}"
    echo -e "${GREEN}=====================================================${RESET}"
    echo -ne "${CYAN}确认继续操作吗？(y/n): ${RESET}"
    read -r cert_confirm
    if [[ "$cert_confirm" != "y" && "$cert_confirm" != "Y" ]]; then
        echo -e "${YELLOW}已取消配置。${RESET}"
        return
    fi

    echo ""
    echo -ne "${YELLOW}请输入你的访问主域名 (例如: shop.example.com): ${RESET}"
    read -r main_domain

    if [ -z "$main_domain" ]; then
        echo -e "${RED}域名不能为空，取消配置！${RESET}"
        return
    fi

    safe_remove_old_conf "$main_domain"

    local AVAILABLE_DIR="/etc/nginx/sites-available"
    local ENABLED_DIR="/etc/nginx/sites-enabled"
    local CONF_D_DIR="/etc/nginx/conf.d"
    local USE_SYMLINK=false

    if [ -d "$AVAILABLE_DIR" ] && [ -d "$ENABLED_DIR" ]; then
        MAIN_CONF="$AVAILABLE_DIR/$main_domain"
        USE_SYMLINK=true
    else
        sudo mkdir -p "$CONF_D_DIR"
        MAIN_CONF="$CONF_D_DIR/${main_domain}.conf"
        USE_SYMLINK=false
    fi

    echo -e "${YELLOW}正在写入 Nginx 反代配置到 $MAIN_CONF ...${RESET}"
    sudo tee "$MAIN_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $main_domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name $main_domain;

    ssl_certificate /etc/letsencrypt/live/$main_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$main_domain/privkey.pem;

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:$app_p;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    if [ "$USE_SYMLINK" = true ]; then
        sudo ln -sf "$MAIN_CONF" "$ENABLED_DIR/$main_domain"
    fi

    if command -v nginx &> /dev/null; then
        echo -e "${YELLOW}正在进行 Nginx 语法安全检查...${RESET}"
        if sudo nginx -t; then
            echo -e "${YELLOW}语法检查成功，正在重载 Nginx 服务...${RESET}"
            sudo nginx -s reload
            echo -e "${GREEN}✔ Nginx 配置成功生效！${RESET}"
        else
            echo -e "${RED}❌ Nginx 语法检查失败！请确认 SSL 证书路径是否存在。${RESET}"
        fi
    else
        echo -e "${YELLOW}提示: 未检测到本地 Nginx 物理命令，文件已保存。${RESET}"
    fi
}

show_info() {
    get_status_info
    
    # 尝试从 config.yml 提取当前后台路径
    local current_admin_path="/admin"
    if [ -f "$CONFIG_FILE" ]; then
        local extracted_path=$(grep "admin_path:" "$CONFIG_FILE" | awk '{print $2}' | tr -d '"')
        [ -n "$extracted_path" ] && current_admin_path="$extracted_path"
    fi

    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}集群运行状态 : $status"
    echo -e "${YELLOW}应用服务端口 : 127.0.0.1:${app_p}"
    echo -e "${YELLOW}后台安全路径 : ${current_admin_path}"
    echo -e "${YELLOW}本地安装路径 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} ◈ DuJiaoNext (独角数卡) 面板 ◈  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}核心状态 :${RESET} $status"
    echo -e "${GREEN}服务端口 :${RESET} ${YELLOW}${app_p}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新服务${RESET}"
    echo -e "${GREEN}3. 卸载服务${RESET}"
    echo -e "${GREEN}4. 启动集群${RESET}"
    echo -e "${GREEN}5. 停止集群${RESET}"
    echo -e "${GREEN}6. 重启集群${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}9. 反向代理${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_dujiao ;;
        2) update_dujiao ;;
        3) uninstall_dujiao ;;
        4) start_dujiao ;;
        5) stop_dujiao ;;
        6) restart_dujiao ;;
        7) logs_dujiao ;;
        8) show_info ;;
        9) configure_nginx ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
