#!/bin/bash
# =================================================================
# New-API 聚合接口管理面板
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
        
        if [[ "$ext_db_ip" == "127.0.0.1" || "$ext_db_ip" == "localhost" ]]; then
            db_host="172.17.0.1"
        fi
    fi

    # 3. Redis 运行模式与分区选择
    echo -e "\n${CYAN}====== Redis 缓存运行模式选择 ======${RESET}"
    echo -e " 1) 直接部署全新的 Redis 容器 (自动生成高强度密码)"
    echo -e " 2) 使用已有的外部/远程 Redis 服务"
    echo -ne "${YELLOW}请选择 Redis 模式 [默认: 1]: ${RESET}"
    read -r redis_mode
    [[ -z "$redis_mode" ]] && redis_mode="1"

    local redis_host="redis"
    local redis_port="6379"
    local redis_pass=""
    local redis_db="0"

    if [[ "$redis_mode" == "1" ]]; then
        echo -e "${YELLOW}使用全新内置 Redis 容器，正在生成高强度随机密码...${RESET}"
        redis_pass=$(openssl rand -hex 16)
    else
        echo -ne "${YELLOW}请输入远程 Redis 的 IP 或域名: ${RESET}"
        read -r ext_redis_ip
        echo -ne "${YELLOW}请输入远程 Redis 端口 [默认: 6379]: ${RESET}"
        read -r ext_redis_port
        [[ -z "$ext_redis_port" ]] && ext_redis_port="6379"
        redis_host="$ext_redis_ip"
        redis_port="$ext_redis_port"
        echo -ne "${YELLOW}请输入远程 Redis 密码 (若无密码请直接回车): ${RESET}"
        read -r redis_pass
        
        if [[ "$ext_redis_ip" == "127.0.0.1" || "$ext_redis_ip" == "localhost" ]]; then
            redis_host="172.17.0.1"
        fi
    fi

    echo -ne "${YELLOW}请输入 Redis 分区编号 (DB Index) [0-15] [默认: 0]: ${RESET}"
    read -r redis_db
    [[ -z "$redis_db" || ! "$redis_db" =~ ^[0-9]+$ ]] && redis_db="0"

    # 4. 动态拼接生成强连接串 DSN 和 Redis 连接串
    local sql_dsn="postgresql://${db_user}:${db_pass}@${db_host}:${db_port}/${db_name}"
    local redis_conn="redis://:${redis_pass}@${redis_host}:${redis_port}/${redis_db}"
    # 如果远程 Redis 没有密码，格式化连接串
    if [[ "$redis_mode" == "2" && -z "$redis_pass" ]]; then
        redis_conn="redis://${redis_host}:${redis_port}/${redis_db}"
    fi

    # 5. 备份保留凭证配置文件 newapi.env
    cat << EOF > "$CONFIG_FILE"
PORT="${custom_port}"
NODE_NAME="${node_name}"
REDIS_MODE="${redis_mode}"
REDIS_HOST="${redis_host}"
REDIS_PORT="${redis_port}"
REDIS_PASS="${redis_pass}"
REDIS_DB="${redis_db}"
DB_HOST="${db_host}"
DB_PORT="${db_port}"
PG_USER="${db_user}"
PG_PASS="${db_pass}"
PG_DB="${db_name}"
SQL_DSN="${sql_dsn}"
REDIS_CONN="${redis_conn}"
EOF

    # 6. 创建基础持久化目录
    mkdir -p "$BASE_DIR/data" "$BASE_DIR/logs"

    # 7. 生成规范化 Docker Compose 配置文件
    echo -e "${YELLOW}正在生成规范化 Docker Compose 配置文件...${RESET}"
    
    # 初始化 compose 内容
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
      - "${custom_port}:3000"
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
EOF

    # 根据依赖动态追加 depends_on 声明
    if [[ "$redis_mode" == "1" ]]; then
        echo "      - redis" >> "$COMPOSE_FILE"
    fi
    if [[ "$db_mode" == "1" ]]; then
        echo "      - postgres" >> "$COMPOSE_FILE"
    fi
    # 如果都是外部服务，移除没有子项的 depends_on:
    if [[ "$redis_mode" == "2" && "$db_mode" == "2" ]]; then
        sed -i '/depends_on:/d' "$COMPOSE_FILE"
    fi

    # 追加网络模块到 new-api
    cat << EOF >> "$COMPOSE_FILE"
    networks:
      - new-api-network
EOF

    # 如果是内置 Redis，追加 Redis 容器拓扑
    if [[ "$redis_mode" == "1" ]]; then
        cat << EOF >> "$COMPOSE_FILE"

  redis:
    image: redis:latest
    container_name: redis
    restart: always
    command: ["redis-server", "--requirepass", "${redis_pass}"]
    networks:
      - new-api-network
EOF
    fi

    # 如果是内置 Postgres，追加 Postgres 容器拓扑
    if [[ "$db_mode" == "1" ]]; then
        mkdir -p "$BASE_DIR/pg_data"
        cat << EOF >> "$COMPOSE_FILE"

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
    fi

    # 8. 清理残余并重新拉起集群
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
    echo -e "${GREEN}           New-API 系统部署成功！                    ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "----------------------------------------------------"
    echo -e "${CYAN}[中间件凭据回显]${RESET}"
    if [[ "$redis_mode" == "1" ]]; then
        echo -e "${YELLOW}Redis 运行模式 : ${GREEN}全新内置容器 (DB: ${redis_db})${RESET}"
    else
        echo -e "${YELLOW}Redis 运行模式 : ${CYAN}外部远程连接 (目标: ${redis_host}:${redis_port} / DB: ${redis_db})${RESET}"
    fi

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
    echo -e "${GREEN}更新完成！${RESET}"
}

# 卸载服务
# 卸载服务
uninstall_newapi() {
    echo -ne "${RED}确定要卸载并删除 New-API 相关的容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            echo -e "${YELLOW}正在停止并移除 Docker Compose 关联的容器及网络...${RESET}"
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            
            # 交互提示：是否清理本地持久化数据
            echo -ne "${YELLOW}是否同时删除本地所有配置文件和持久化数据目录 (包含本地数据库/日志)？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                cd /opt # 先切出目录，防止在目录内删除导致行为异常
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}安装目录 $BASE_DIR 已彻底清理，数据已完全卸载。${RESET}"
            else
                echo -e "${YELLOW}已保留本地配置文件及持久化数据，后续可通过相同配置重新拉起。${RESET}"
            fi
        else
            # 兜底：如果 compose 文件丢失，尝试强制删除可能残留的内置容器名称
            echo -e "${YELLOW}未检测到 Docker Compose 配置文件，尝试强制清理可能残留的内置容器...${RESET}"
            docker rm -f new-api redis postgres 2>/dev/null
            echo -e "${GREEN}清理残余容器完成。${RESET}"
        fi
        echo -e "${GREEN}卸载流程执行完毕！${RESET}"
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
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${YELLOW}Redis 连接串   : ${CYAN}${REDIS_CONN}${RESET}"
        echo -e "${YELLOW}SQL DSN 串     : ${CYAN}${SQL_DSN}${RESET}"
    fi
    echo -e "${GREEN}====================================================${RESET}"
}

# 主菜单管理
menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}        ◈ New-API 管理面板 ◈        ${RESET}"
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
