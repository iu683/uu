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
    echo -e "${GREEN}    请选择 DuJiaoNext 数据库架构: ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${CYAN}1. 方案 A：SQLite + Redis (轻量本地化推荐)${RESET}"
    echo -e "${CYAN}2. 方案 B：PostgreSQL + Redis (本地容器自建集群)${RESET}"
    echo -e "${CYAN}3. 方案 C：连接远程/外部独立数据库 + Redis (分离式架构推荐)${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${YELLOW}请输入编号 [1-3]: ${RESET}"
    read -r db_choice

    if [[ "$db_choice" != "1" && "$db_choice" != "2" && "$db_choice" != "3" ]]; then
        echo -e "${RED}输入有误，取消部署。${RESET}"
        return
    fi

    # 如果是远程数据库，先交互获取数据库凭据
    local remote_driver="postgres"
    local remote_dsn=""
    if [ "$db_choice" = "3" ]; then
        echo -e "${CYAN}--- 远程数据库连接配置 ---${RESET}"
        echo -ne "${YELLOW}请选择数据库类型 ([1] PostgreSQL [2] MySQL): ${RESET}"
        read -r db_type
        if [ "$db_type" = "2" ]; then remote_driver="mysql"; else remote_driver="postgres"; fi

        echo -ne "${YELLOW}请输入远程数据库 主机IP/域名: ${RESET}"
        read -r remote_host
        echo -ne "${YELLOW}请输入远程数据库 端口 (默认 Postgres:5432 / MySQL:3306): ${RESET}"
        read -r remote_port
        if [ -z "$remote_port" ]; then
            if [ "$remote_driver" = "mysql" ]; then remote_port="3306"; else remote_port="5432"; fi
        fi
        echo -ne "${YELLOW}请输入远程数据库 用户名: ${RESET}"
        read -r remote_user
        echo -ne "${YELLOW}请输入远程数据库 密码: ${RESET}"
        read -r remote_pass
        echo -ne "${YELLOW}请输入远程数据库 数据库名: ${RESET}"
        read -r remote_dbname

        # 封装不同驱动的 DSN
        if [ "$remote_driver" = "mysql" ]; then
            remote_dsn="${remote_user}:${remote_pass}@tcp(${remote_host}:${remote_port})/${remote_dbname}?charset=utf8mb4&parseTime=True&loc=Local"
        else
            remote_dsn="host=${remote_host} user=${remote_user} password=${remote_pass} dbname=${remote_dbname} port=${remote_port} sslmode=disable TimeZone=Asia/Shanghai"
        fi
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
  driver: ${remote_driver}
  dsn: "${remote_dsn}"
EOF
    fi

    # 4. 生成高内聚的 .env 变量文件
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
    # 基础公共服务定义开始 (不含本地自建数据库组件)
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
    echo -e "${GREEN}      DuJiaoNext 部署命令成功提交！${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}用户前台 (本机) : http://127.0.0.1:${user_port}${RESET}"
    echo -e "${YELLOW}管理后台 (本机) : http://127.0.0.1:${admin_port}${RESET}"
    echo -e "${RED}🔒 核心安全提示：所有服务绑口仅监听 127.0.0.1。本地中间件无任何公网暴露。${RESET}"
    if [ "$db_choice" = "3" ]; then
        echo -e "${GREEN}当前模式       : 远程数据库连接模式 (${remote_driver})${RESET}"
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
logs_dujiao() { cd "$BASE_DIR" && docker compose logs -f api; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}集群运行状态 : $status"
    echo -e "${YELLOW}前台映射端点 : 127.0.0.1:${user_port}"
    echo -e "${YELLOW}后台映射端点 : 127.0.0.1:${admin_port}"
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
    echo -e "${GREEN}前/后台绑口:${RESET} ${YELLOW}${user_p} / ${admin_p}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新镜像${RESET}"
    echo -e "${GREEN}3. 卸载服务${RESET}"
    echo -e "${GREEN}4. 启动集群${RESET}"
    echo -e "${GREEN}5. 停止集群${RESET}"
    echo -e "${GREEN}6. 重启集群${RESET}"
    echo -e "${GREEN}7. 追踪日志(API)${RESET}"
    echo -e "${GREEN}8. 查看详细配置${RESET}"
    echo -e "${GREEN}. 退出${RESET}"
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
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
