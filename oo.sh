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

# 动态获取容器状态、映射端口
get_status_info() {
    if [ -f "$COMPOSE_FILE" ] && [ "$(cd "$BASE_DIR" && docker compose ps -q 2>/dev/null)" ]; then
        status="${YELLOW}运行中${RESET}"
    else
        if [ -f "$ENV_FILE" ]; then status="${RED}已停止${RESET}"; else status="${RED}未部署${RESET}" ; fi
    fi

    # 从 .env 提取端口信息
    if [ -f "$ENV_FILE" ]; then
        api_p=$(grep "API_PORT=" "$ENV_FILE" | cut -d'=' -f2)
        user_p=$(grep "USER_PORT=" "$ENV_FILE" | cut -d'=' -f2)
        admin_p=$(grep "ADMIN_PORT=" "$ENV_FILE" | cut -d'=' -f2)
    else
        api_p="N/A"; user_p="N/A"; admin_p="N/A"
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
    echo -e "${CYAN}3. 方案 C：连接远程/外部独立 PostgreSQL${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${YELLOW}请输入编号 [1-3]: ${RESET}"
    read -r db_choice

    if [[ "$db_choice" != "1" && "$db_choice" != "2" && "$db_choice" != "3" ]]; then
        echo -e "${RED}输入有误，取消部署。${RESET}"
        return
    fi

    # 如果是远程数据库，交互获取远程 PostgreSQL 凭据
    local remote_dsn=""
    if [ "$db_choice" = "3" ]; then
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

        # 封装标准 Postgres DSN 格式
        remote_dsn="host=${remote_host} user=${remote_user} password=${remote_pass} dbname=${remote_dbname} port=${remote_port} sslmode=disable TimeZone=Asia/Shanghai"
    fi

    echo -e "${CYAN}====== 自定义基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入安装绝对路径 [默认: /opt/dujiao-next]: ${RESET}"
    read -r custom_dir
    [[ -z "$custom_dir" ]] && custom_dir="/opt/dujiao-next"
    BASE_DIR="$custom_dir"
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
    CONFIG_FILE="$BASE_DIR/config/config.yml"
    ENV_FILE="$BASE_DIR/.env"

    echo -ne "${YELLOW}请输入前台(User)端口 [默认: 8081]: ${RESET}"
    read -r user_port
    [[ -z "$user_port" ]] && user_port="8081"

    echo -ne "${YELLOW}请输入后台(Admin)端口 [默认: 8082]: ${RESET}"
    read -r admin_port
    [[ -z "$admin_port" ]] && admin_port="8082"

    echo -ne "${YELLOW}请输入API核心服务端口 [默认: 8080]: ${RESET}"
    read -r api_port
    [[ -z "$api_port" ]] && api_port="8080"

    echo -ne "${YELLOW}设置首次初始化管理员密码 [默认: admin123]: ${RESET}"
    read -r admin_pwd
    [[ -z "$admin_pwd" ]] && admin_pwd="admin123"

    # 1. 创建持久化目录
    echo -e "${YELLOW}正在建立并授权本地持久化目录...${RESET}"
    mkdir -p "$BASE_DIR/config" "$BASE_DIR/data/db" "$BASE_DIR/data/uploads" "$BASE_DIR/data/logs" "$BASE_DIR/data/redis" "$BASE_DIR/data/postgres"
    chmod -R 0777 "$BASE_DIR/data"

    # 2. 自动生成专属的高强度密码和 32 位双核心 JWT 安全密码
    local redis_pass=$(generate_random_str 16)
    local local_pg_pass=$(generate_random_str 16)
    local jwt_secret=$(generate_random_str 32)
    local user_jwt_secret=$(generate_random_str 32)

    # 3. 动态配置 config.yml
    echo -e "${YELLOW}正在安全加密并生成统一生产配置文件 (config.yml)...${RESET}"
    cat <<EOF > "$CONFIG_FILE"
app:
  env: production
jwt:
  secret: "${jwt_secret}"
user_jwt:
  secret: "${user_jwt_secret}"
redis:
  enabled: true
  host: redis
  port: 6379
  password: ${redis_pass}
  db: 0
  prefix: "dj"
queue:
  enabled: true
  host: redis
  port: 6379
  password: ${redis_pass}
  db: 1
  concurrency: 10
  queues:
    default: 10
    critical: 5
EOF

    # 追加入口对应的 database 配置
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
    elif [ "$db_choice" = "3" ]; then
        cat <<EOF >> "$CONFIG_FILE"
database:
  driver: postgres
  dsn: "${remote_dsn}"
EOF
    fi

    # 4. 生成高内聚的 .env 变量 file
    cat <<EOF > "$ENV_FILE"
TAG=latest
TZ=Asia/Shanghai
API_PORT=${api_port}
USER_PORT=${user_port}
ADMIN_PORT=${admin_port}
DJ_DEFAULT_ADMIN_USERNAME=admin
DJ_DEFAULT_ADMIN_PASSWORD=${admin_pwd}
REDIS_PASSWORD=${redis_pass}
POSTGRES_DB=dujiao_next
POSTGRES_USER=dujiao
POSTGRES_PASSWORD=${local_pg_pass}
EOF

    # 5. 生成对应的集群网络 docker-compose.yml 
    local compose_content="services:
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

    # 如果选本地自建方案 B，插入本地 postgres 容器声明
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

    # 追加拼装 API / User / Admin 容器定义
    compose_content="${compose_content}

  api:
    image: dujiaonext/api:\${TAG}
    container_name: dujiaonext-api
    restart: unless-stopped
    environment:
      TZ: \${TZ}
      DJ_DEFAULT_ADMIN_USERNAME: \${DJ_DEFAULT_ADMIN_USERNAME}
      DJ_DEFAULT_ADMIN_PASSWORD: \${DJ_DEFAULT_ADMIN_PASSWORD}
    ports:
      - \"127.0.0.1:\${API_PORT}:8080\"
    volumes:
      - ./config/config.yml:/app/config.yml:ro"

    if [ "$db_choice" = "1" ]; then
        compose_content="${compose_content}
      - ./data/db:/app/db"
    fi

    compose_content="${compose_content}
      - ./data/uploads:/app/uploads
      - ./data/logs:/app/logs
    depends_on:
      redis:
        condition: service_healthy"

    if [ "$db_choice" = "2" ]; then
        compose_content="${compose_content}
      postgres:
        condition: service_healthy"
    fi

    compose_content="${compose_content}
    healthcheck:
      test: [\"CMD\", \"wget\", \"-qO-\", \"http://127.0.0.1:8080/health\"]
      interval: 10s
      timeout: 3s
      retries: 10
    networks:
      - dujiao-net

  user:
    image: dujiaonext/user:\${TAG}
    container_name: dujiaonext-user
    restart: unless-stopped
    environment:
      TZ: \${TZ}
    ports:
      - \"127.0.0.1:\${USER_PORT}:80\"
    depends_on:
      api:
        condition: service_healthy
    networks:
      - dujiao-net

  admin:
    image: dujiaonext/admin:\${TAG}
    container_name: dujiaonext-admin
    restart: unless-stopped
    environment:
      TZ: \${TZ}
    ports:
      - \"127.0.0.1:\${ADMIN_PORT}:80\"
    depends_on:
      api:
        condition: service_healthy
    networks:
      - dujiao-net

networks:
  dujiao-net:
    driver: bridge"

    # 将组合出的内容写入 compose 物理文件
    echo "$compose_content" > "$COMPOSE_FILE"

    # 6. 容器启动
    echo -e "${YELLOW}正在启动 DuJiaoNext 容器群 (本地回环架构)...${RESET}"
    cd "$BASE_DIR" && docker compose up -d

    echo -e "${YELLOW}等待微服务集群健康自检 (约8秒)...${RESET}"
    sleep 8

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}       DuJiaoNext 部署成功！     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}用户前台 (本机) : http://127.0.0.1:${user_port}${RESET}"
    echo -e "${YELLOW}管理后台 (本机) : http://127.0.0.1:${admin_port}${RESET}"
    echo -e "${YELLOW}API 服务 (本机) : http://127.0.0.1:${api_port}${RESET}"
    echo -e "${RED}🔒 核心安全提示：所有服务绑口仅监听 127.0.0.1。本地中间件无任何公网暴露。${RESET}"
    if [ "$db_choice" = "3" ]; then
        echo -e "${GREEN}当前模式       : 远程独立 PostgreSQL 连接模式${RESET}"
    fi
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
    echo -e "${YELLOW}正在从远端拉取最新组件镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}集群更新完成！${RESET}"
}

# 彻底卸载
uninstall_dujiao() {
    echo -ne "${RED}警告：确认要完全卸载并停止独角数卡服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器集群已安全销毁。${RESET}"
            echo -ne "${YELLOW}是否同时抹除本地数据库、上传的资源文件和全部日志？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}所有物理持久化数据已彻底抹除。${RESET}"
            fi
        else
            docker rm -f dujiaonext-api dujiaonext-user dujiaonext-admin dujiaonext-redis dujiaonext-postgres 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_dujiao() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}集群已恢复启动${RESET}"; }
stop_dujiao() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}集群已受控停止${RESET}"; }
restart_dujiao() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}集群已完整重启${RESET}"; }


# 三选一交互式追踪日志核心逻辑
logs_dujiao() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到部署集群，无法提取日志。${RESET}"
        return
    fi
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      请选择要追踪日志的容器:     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${CYAN}1. 核心 API 服务 (dujiaonext-api)${RESET}"
    echo -e "${CYAN}2. 用户前台网站 (dujiaonext-user)${RESET}"
    echo -e "${CYAN}3. 管理后台管理 (dujiaonext-admin)${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${YELLOW}请输入选项 [1-3]: ${RESET}"
    read -r log_choice

    case "$log_choice" in
        1) cd "$BASE_DIR" && docker compose logs -f api ;;
        2) cd "$BASE_DIR" && docker compose logs -f user ;;
        3) cd "$BASE_DIR" && docker compose logs -f admin ;;
        *) echo -e "${RED}输入无效，返回主菜单。${RESET}" ;;
    esac
}

# 智能备份并完全【移出】Nginx 监控视线（修复 include 冲突 Bug）
safe_remove_old_conf() {
    local domain=$1
    local paths=("/etc/nginx/sites-enabled/$domain" "/etc/nginx/sites-available/$domain" "/etc/nginx/conf.d/$domain.conf")
    
    # 创建位于系统 tmp 目录的绝对隔离备份区
    sudo mkdir -p /tmp/nginx_bak/ 2>/dev/null

    for path in "${paths[@]}"; do
        if [ -f "$path" ] || [ -L "$path" ]; then
            local filename=$(basename "$path")
            local parent_dir=$(basename "$(dirname "$path")")
            echo -e "${YELLOW}发现冲突旧配置: $path，正在将其移出 Nginx 并备份至 /tmp/nginx_bak/${parent_dir}_${filename} ...${RESET}"
            # 使用 mv 直接移走，绝不在原目录留下任何后缀文件，彻底消除 Nginx 扫描
            sudo mv "$path" "/tmp/nginx_bak/${parent_dir}_${filename}" 2>/dev/null
        fi
    done
}

# 自动配置 Nginx 反代逻辑 
configure_nginx() {
    get_status_info
    if [ "$user_p" = "N/A" ] || [ "$admin_p" = "N/A" ] || [ "$api_p" = "N/A" ]; then
        echo -e "${RED}错误: 未检测到有效的部署参数，请先执行选项 1 部署服务。${RESET}"
        return
    fi

    clear
    echo -e "${GREEN}=====================================================${RESET}"
    echo -e "${GREEN}      DuJiaoNext Nginx 智能域名配置交割工具            ${RESET}"
    echo -e "${GREEN}=====================================================${RESET}"
    echo -e "${RED}🔔 智能交割提示：${RESET}"
    echo -e "${YELLOW}1. 脚本会自动检测并在 /etc/nginx/sites-enabled/ 下重写域名文件。${RESET}"
    echo -e "${YELLOW}2. 发现同名旧文件会无损移到 /tmp/nginx_bak/ 目录，绝不污染 Nginx 配置链。${RESET}"
    echo -e "${YELLOW}3. 写入前请确认你已提前生成好这两个域名的 SSL 证书文件。${RESET}"
    echo -e "${GREEN}=====================================================${RESET}"
    echo -ne "${CYAN}确认已知晓并继续操作吗？(y/n): ${RESET}"
    read -r cert_confirm
    if [[ "$cert_confirm" != "y" && "$cert_confirm" != "Y" ]]; then
        echo -e "${YELLOW}已取消配置。${RESET}"
        return
    fi

    echo ""
    echo -ne "${YELLOW}请输入前台(User)现有域名 (例如: user.example.com): ${RESET}"
    read -r user_domain
    echo -ne "${YELLOW}请输入后台(Admin)现有域名 (例如: admin.example.com): ${RESET}"
    read -r admin_domain

    if [ -z "$user_domain" ] || [ -z "$admin_domain" ]; then
        echo -e "${RED}域名不能为空，取消配置！${RESET}"
        return
    fi

    # 彻底移开冲突配置文件
    safe_remove_old_conf "$user_domain"
    safe_remove_old_conf "$admin_domain"

    # 定位 Nginx 配置写入路径
    local TARGET_DIR="/etc/nginx/sites-enabled"
    if [ ! -d "$TARGET_DIR" ]; then
        TARGET_DIR="/etc/nginx/conf.d"
    fi
    sudo mkdir -p "$TARGET_DIR"

    USER_CONF="$TARGET_DIR/$user_domain"
    ADMIN_CONF="$TARGET_DIR/$admin_domain"

    if [ "$TARGET_DIR" = "/etc/nginx/conf.d" ]; then
        USER_CONF="${USER_CONF}.conf"
        ADMIN_CONF="${ADMIN_CONF}.conf"
    fi

    echo -e "${YELLOW}正在写入前台配置到 $USER_CONF ...${RESET}"
    sudo tee "$USER_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $user_domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name $user_domain;

    ssl_certificate /etc/letsencrypt/live/$user_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$user_domain/privkey.pem;

    client_max_body_size 200M;

    location / {
        proxy_pass http://127.0.0.1:$user_p;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # SEO 文件
    location = /sitemap.xml {
        proxy_pass http://127.0.0.1:$api_p/sitemap.xml;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /robots.txt {
        proxy_pass http://127.0.0.1:$api_p/robots.txt;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:$api_p/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /uploads/ {
        proxy_pass http://127.0.0.1:$api_p/uploads/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    echo -e "${YELLOW}正在写入后台配置到 $ADMIN_CONF ...${RESET}"
    sudo tee "$ADMIN_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $admin_domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name $admin_domain;

    ssl_certificate /etc/letsencrypt/live/$admin_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$admin_domain/privkey.pem;

    client_max_body_size 200M;

    location / {
        proxy_pass http://127.0.0.1:$admin_p;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /api/ {
        proxy_pass http://127.0.0.1:$api_p/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /uploads/ {
        proxy_pass http://127.0.0.1:$api_p/uploads/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    echo -e "${GREEN}新配置文件成功生成！${RESET}"
    
    if command -v nginx &> /dev/null; then
        echo -e "${YELLOW}正在进行 Nginx 语法安全检查...${RESET}"
        if sudo nginx -t; then
            echo -e "${YELLOW}语法检查成功，正在重载 Nginx 服务...${RESET}"
            sudo nginx -s reload
            echo -e "${GREEN}✔ 成功无缝交接！旧配置已彻底移开，独角数卡全线生效！${RESET}"
        else
            echo -e "${RED}❌ Nginx 语法检查失败！请检查证书文件是否存在。${RESET}"
        fi
    else
        echo -e "${YELLOW}提示: 未检测到本地 Nginx 物理命令，文件已保存在: $TARGET_DIR${RESET}"
    fi
}


show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}集群运行状态 : $status"
    echo -e "${YELLOW}前台映射端点 : 127.0.0.1:${user_port}"
    echo -e "${YELLOW}后台映射端点 : 127.0.0.1:${admin_port}"
    echo -e "${YELLOW}API 核心端点 : 127.0.0.1:${api_p}"
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
    echo -e "${GREEN}前台端口 :${RESET} ${YELLOW}${user_p}${RESET}"
    echo -e "${GREEN}后台端口 :${RESET} ${YELLOW}${admin_p}${RESET}" 
    echo -e "${GREEN}API端口  :${RESET} ${YELLOW}${api_p}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新服务${RESET}"
    echo -e "${GREEN}3. 卸载服务${RESET}"
    echo -e "${GREEN}4. 启动集群${RESET}"
    echo -e "${GREEN}5. 停止集群${RESET}"
    echo -e "${GREEN}6. 重启集群${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}9. 配置反向代理${RESET}"
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
