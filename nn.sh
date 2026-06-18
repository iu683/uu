#!/bin/bash
# =================================================================
# New-API 聚合接口管理面板 (PostgreSQL 内置/远程双模隔离版)
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/new-api"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
CONFIG_FILE="$BASE_DIR/newapi.env"
DEFAULT_IMAGE="calciumion/new-api:latest"

# 检测依赖环境
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        # 强制获取 IPv4
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        # 强制获取 IPv6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        # auto 模式：双栈环境优先获取 IPv4 (更适合大众网络)，纯 v6 环境自动fallback到 v6
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        # 如果获取 v4 失败，说明可能是纯 v6 机器，尝试获取 v6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    # 兜底处理：所有接口都失败时，直接输出 127.0.0.1，不报错
    echo "127.0.0.1" && return 0
}
# 动态获取容器整体状态和端口
get_status_info() {
    if [ -f "$COMPOSE_FILE" ]; then
        if [ "$(docker ps -q -f name=new-api)" ]; then
            status="${GREEN}运行中${RESET}"
            web_port=$(docker ps -f name=new-api --format "{{.Ports}}" | sed -E 's/.*:([0-9]+)->.*/\1/' | head -n 1)
            if ! [[ "$web_port" =~ ^[0-9]+$ ]]; then
                web_port=$(sed -n '/new-api:/,/^[[:space:]]*[a-zA-Z]/p' "$COMPOSE_FILE" | grep -E '\-[[:space:]]*["'\'']?[0-9]+:' | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"''-')
            fi
        elif [ "$(docker ps -aq -f name=new-api)" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' new-api 2>/dev/null)
        else
            status="${RED}未部署${RESET}"
        fi
        [[ -z "$web_port" ]] && web_port="3000"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署 New-API
install_newapi() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    # 1. 基础参数配置
    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 New-API 宿主机映射访问端口 [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"

    echo -ne "${YELLOW}请输入节点名称 NODE_NAME [默认: default]: ${RESET}"
    read -r node_name
    [[ -z "$node_name" ]] && node_name="default"

    # 自动生成本地缓存 Redis 高强度密码
    local redis_pass=$(openssl rand -hex 16)

    # 2. 数据库运行模式选择
    echo -e "\n${CYAN}====== PostgreSQL 数据库运行模式选择 ======${RESET}"
    echo -e " 1) 直接部署全新的 PostgreSQL 15 容器 (包含本地持久化卷)"
    echo -e " 2) 使用已有的外部/远程 PostgreSQL 数据库 (需提前手动建好空库)"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    local db_host="postgres"
    local db_port="5432"
    local db_name="new-api"
    local db_user="root"
    local db_pass=""

    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}使用全新内置 PostgreSQL 容器，正在生成高强度随机密码...${RESET}"
        db_pass=$(openssl rand -hex 16)
    else
        echo -ne "${YELLOW}请输入远程 PostgreSQL 的 IP 或域名: ${RESET}"
        read -r ext_db_ip
        echo -ne "${YELLOW}请输入远程 PostgreSQL 端口 [默认: 5432]: ${RESET}"
        read -r ext_db_port
        [[ -z "$ext_db_port" ]] && ext_db_port="5432"
        db_host="$ext_db_ip"
        db_port="$ext_db_port"
        echo -ne "${YELLOW}请输入远程 PostgreSQL 用户名 [默认: root]: ${RESET}"
        read -r db_user
        [[ -z "$db_user" ]] && db_user="root"
        echo -ne "${YELLOW}请输入远程 PostgreSQL 密码: ${RESET}"
        read -r db_pass
        echo -ne "${YELLOW}请输入远程已存在的数据库名 [默认: new-api]: ${RESET}"
        read -r db_name
        [[ -z "$db_name" ]] && db_name="new-api"
        
        # 兼容本地宿主机回环网关
        if [[ "$ext_db_ip" == "127.0.0.1" || "$ext_db_ip" == "localhost" ]]; then
            db_host="172.17.0.1"
        fi
    fi

    # 3. 动态拼接生成强连接串 DSN
    local sql_dsn="postgresql://${db_user}:${db_pass}@${db_host}:${db_port}/${db_name}"
    local redis_conn="redis://:${redis_pass}@redis:6379"

    # 4. 备份保留凭证配置文件 newapi.env (全双引号死锁防截断)
    cat << EOF > "$CONFIG_FILE"
PORT="${custom_port}"
NODE_NAME="${node_name}"
REDIS_PASS="${redis_pass}"
DB_HOST="${db_host}"
DB_PORT="${db_port}"
PG_USER="${db_user}"
PG_PASS="${db_pass}"
PG_DB="${db_name}"
SQL_DSN="${sql_dsn}"
EOF

    # 5. 创建基础持久化目录
    mkdir -p "$BASE_DIR/data" "$BASE_DIR/logs"

    # 6. 生成规范化 Docker Compose 配置文件
    echo -e "${YELLOW}正在生成规范化 Docker Compose 配置文件...${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        # 模式 1：本地完整三容器拓扑 (包含本地 PG)
        mkdir -p "$BASE_DIR/pg_data"
        cat << EOF > "$COMPOSE_FILE"
networks:
  new-api-network:
    driver: bridge

services:
  new-api:
    image: ${DEFAULT_IMAGE}
    container_name: new-api
    restart: always
    command: --log-dir /app/logs
    ports:
      - "127.0.0.1:${custom_port}:3000"
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    environment:
      - SQL_DSN=${sql_dsn}
      - REDIS_CONN_STRING=${redis_conn}
      - TZ=Asia/Shanghai
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
      - NODE_NAME=${node_name}
    depends_on:
      - redis
      - postgres
    networks:
      - new-api-network

  redis:
    image: redis:latest
    container_name: redis
    restart: always
    command: ["redis-server", "--requirepass", "${redis_pass}"]
    networks:
      - new-api-network

  postgres:
    image: postgres:15
    container_name: postgres
    restart: always
    environment:
      POSTGRES_USER: "${db_user}"
      POSTGRES_PASSWORD: "${db_pass}"
      POSTGRES_DB: "${db_name}"
    volumes:
      - ./pg_data:/var/lib/postgresql/data
    networks:
      - new-api-network
EOF
    else
        # 模式 2：远程 PG 模式，移除本地 postgres 容器与节点依赖，但保留本地 redis 与网络
        cat << EOF > "$COMPOSE_FILE"
networks:
  new-api-network:
    driver: bridge

services:
  new-api:
    image: ${DEFAULT_IMAGE}
    container_name: new-api
    restart: always
    command: --log-dir /app/logs
    ports:
      - "127.0.0.1:${custom_port}:3000"
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    environment:
      - SQL_DSN=${sql_dsn}
      - REDIS_CONN_STRING=${redis_conn}
      - TZ=Asia/Shanghai
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
      - NODE_NAME=${node_name}
    depends_on:
      - redis
    networks:
      - new-api-network

  redis:
    image: redis:latest
    container_name: redis
    restart: always
    command: ["redis-server", "--requirepass", "${redis_pass}"]
    networks:
      - new-api-network
EOF
    fi

    # 7. 清理残余并重新拉起集群
    echo -e "${YELLOW}正在通过 Docker Compose 部署聚合系统...${RESET}"
    cd "$BASE_DIR"
    docker compose down -v 2>/dev/null
    docker compose up -d --force-recreate

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 服务拉起失败，请检查端口 ${custom_port} 是否被占用。${RESET}"
        return
    fi

    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             New-API 系统部署成功！                   ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}内部提取端口   : ${custom_port} (绑定在 127.0.0.1)${RESET}"
    echo -e "${YELLOW}本地 Nginx 反代: http://127.0.0.1:${custom_port}${RESET}"
    echo -e "${YELLOW}默认初始账号   : root${RESET}"
    echo -e "${YELLOW}默认初始密码   : 123456 (登录后请立即进入设置修改)${RESET}"
    echo -e "----------------------------------------------------"
    echo -e "${CYAN}[数据库与中间件凭据回显]${RESET}"
    echo -e "${YELLOW}本地 Redis 状态: ${GREEN}独立运行 (密码已锁固)${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}PGSQL 运行模式 : ${GREEN}全新内置容器 (PostgreSQL 15)${RESET}"
        echo -e "${YELLOW}分配实例密码   : ${GREEN}${db_pass}${RESET}"
    else
        echo -e "${YELLOW}PGSQL 运行模式 : ${CYAN}外部远程连接${RESET}"
        echo -e "${YELLOW}远程目标节点   : ${db_host}:${db_port}${RESET}"
        echo -e "${YELLOW}连接指定库名   : ${db_name}${RESET}"
    fi
    echo -e "----------------------------------------------------"
    echo -e "${YELLOW}持久化工作目录 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新服务
update_newapi() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 New-API 镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}升级完成！${RESET}"
}

# 卸载服务
uninstall_newapi() {
    echo -ne "${RED}确定要完全卸载并删除 New-API 服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            rm -rf "$BASE_DIR"
        else
            docker rm -f new-api redis postgres 2>/dev/null
        fi
        echo -e "${GREEN}完全卸载成功，数据已彻底清理。${RESET}"
    fi
}

start_newapi() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已拉起运行${RESET}"; }
stop_newapi() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止运行${RESET}"; }
restart_newapi() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已成功重启${RESET}"; }
logs_newapi() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态   : $status"
    echo -e "${YELLOW}外部提取端口   : ${web_port}${RESET}"
    echo -e "${YELLOW}安装绝对路径   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 主菜单管理
menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}       ◈  New-API 管理面板  ◈        ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN} 当前状态 :${RESET} $status"
    echo -e "${GREEN} 映射端口 :${RESET} ${YELLOW}${web_port}${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN} 1. 部署启动${RESET}"
    echo -e "${GREEN} 2. 更新服务${RESET}"
    echo -e "${GREEN} 3. 卸载服务${RESET}"
    echo -e "${GREEN} 4. 启动服务${RESET}"
    echo -e "${GREEN} 5. 停止服务${RESET}"
    echo -e "${GREEN} 6. 重启服务${RESET}"
    echo -e "${GREEN} 7. 查看日志${RESET}"
    echo -e "${GREEN} 8. 查看配置${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_newapi ;;
        2) update_newapi ;;
        3) uninstall_newapi ;;
        4) start_newapi ;;
        5) stop_newapi ;;
        6) restart_newapi ;;
        7) logs_newapi ;;
        8) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
