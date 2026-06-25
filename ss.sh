#!/bin/bash
# =================================================================
# PPanel 聚合面板管理 (经典菜单 · 数据库权限隔离权限自愈版)
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/ppanel"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
CONFIG_DIR="$BASE_DIR/config"
CONFIG_FILE="$CONFIG_DIR/ppanel.yaml"
ENV_FILE="$BASE_DIR/ppanel.env"

# 检测依赖环境
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器整体状态和端口
get_status_info() {
    if [ -f "$COMPOSE_FILE" ]; then
        if [ "$(docker ps -q -f name=ppanel)" ]; then
            status="${GREEN}运行中${RESET}"
            web_port=$(docker ps -f name=ppanel --format "{{.Ports}}" | sed -E 's/.*:([0-9]+)->.*/\1/' | head -n 1)
            if ! [[ "$web_port" =~ ^[0-9]+$ ]]; then
                web_port=$(sed -n '/ppanel:/,/^[[:space:]]*[a-zA-Z]/p' "$COMPOSE_FILE" | grep -E '\-[[:space:]]*["'\'']?[0-9]+:' | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"''-')
            fi
        elif [ "$(docker ps -aq -f name=ppanel)" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' ppanel 2>/dev/null)
        else
            status="${RED}未部署${RESET}"
        fi
        [[ -z "$web_port" ]] && web_port="8080"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 获取公网 IP (兼容双栈环境)
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://4.ip.sb"; do
        ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
    done
    echo "127.0.0.1" && return 0
}

# 1. 部署启动 (注入原生健康检查与账户权限隔离)
install_ppanel() {
    check_dependencies
    mkdir -p "$BASE_DIR" "$CONFIG_DIR" "$BASE_DIR/web"

    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 PPanel 宿主机映射访问端口 [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"

    local jwt_secret=$(openssl rand -hex 16)

    echo -e "\n${CYAN}====== MySQL 数据库运行模式选择 ======${RESET}"
    echo -e " 1) 直接部署全新的 MySQL 8 容器 (自动隔离高权限+持久化)"
    echo -e " 2) 使用已有的外部/远程 MySQL 数据库 (需提前手动建好空库)"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    local db_host="mysql"
    local db_port="3306"
    local db_name="ppanel"
    local db_user="ppanel"  # 默认内置模式使用隔离的普通用户名
    local db_pass=""
    local root_pass=""

    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}使用全新内置 MySQL 容器，正在生成高强度随机凭证密码...${RESET}"
        db_pass=$(openssl rand -hex 16)     # 普通用户密码
        root_pass=$(openssl rand -hex 16)   # root 超级管理员密码
    else
        echo -ne "${YELLOW}请输入远程 MySQL 的 IP 或域名: ${RESET}"
        read -r ext_db_ip
        echo -ne "${YELLOW}请输入远程 MySQL 端口 [默认: 3306]: ${RESET}"
        read -r ext_db_port
        [[ -z "$ext_db_port" ]] && ext_db_port="3306"
        db_host="$ext_db_ip"
        db_port="$ext_db_port"
        echo -ne "${YELLOW}请输入远程 MySQL 用户名 [默认: root]: ${RESET}"
        read -r db_user
        [[ -z "$db_user" ]] && db_user="root"
        echo -ne "${YELLOW}请输入远程 MySQL 密码: ${RESET}"
        read -r db_pass
        echo -ne "${YELLOW}请输入远程已存在的数据库名 [默认: ppanel]: ${RESET}"
        read -r db_name
        [[ -z "$db_name" ]] && db_name="ppanel"
        
        if [[ "$ext_db_ip" == "127.0.0.1" || "$ext_db_ip" == "localhost" ]]; then
            db_host="172.17.0.1"
        fi
    fi

    echo -e "\n${CYAN}====== Redis 缓存运行模式选择 ======${RESET}"
    echo -e " 1) 直接部署全新的 Redis 7 容器 (自动生成高强度密码)"
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

    # 落地保存凭证
    cat << EOF > "$ENV_FILE"
PORT="${custom_port}"
DB_MODE="${db_mode}"
DB_HOST="${db_host}"
DB_PORT="${db_port}"
DB_USER="${db_user}"
DB_PASS="${db_pass}"
DB_NAME="${db_name}"
REDIS_MODE="${redis_mode}"
REDIS_HOST="${redis_host}"
REDIS_PORT="${redis_port}"
REDIS_PASS="${redis_pass}"
REDIS_DB="${redis_db}"
JWT_SECRET="${jwt_secret}"
EOF

    # 生成业务配置文件 ppanel.yaml (主程序连接使用的是安全的普通隔离账户)
    cat << EOF > "$CONFIG_FILE"
Host: 0.0.0.0
Port: 8080
TLS:
    Enable: false
Debug: false

Static:
  Admin:
    Enabled: true
    Prefix: /admin
    Path: ./static/admin
  User:
    Enabled: true
    Prefix: /
    Path: ./static/user

JwtAuth:
    AccessSecret: ${jwt_secret}
    AccessExpire: 604800

Logger:
    ServiceName: ApiService
    Mode: console
    Encoding: plain
    TimeFormat: "2006-01-02 15:04:05.000"
    Path: logs
    Level: info

MySQL:
    Addr: ${db_host}:${db_port}
    Username: ${db_user}
    Password: ${db_pass}
    Dbname: ${db_name}
    Config: charset=utf8mb4&parseTime=true&loc=Asia%2FShanghai

Redis:
    Host: ${redis_host}:${redis_port}
    Pass: ${redis_pass}
    DB: ${redis_db}
EOF

    # 生成规范化拓扑的 Docker Compose
    cat << EOF > "$COMPOSE_FILE"
networks:
  ppanel-network:
    driver: bridge

services:
  ppanel:
    image: ppanel/ppanel:latest
    container_name: ppanel
    restart: always
    ports:
      - "${custom_port}:8080"
    volumes:
      - ./config:/app/etc
      - ./web:/app/static
    networks:
      - ppanel-network
EOF

    # 依赖注入：如果是内置MySQL，开启原生健康检查阻塞等待
    if [[ "$db_mode" == "1" ]]; then
        cat << EOF >> "$COMPOSE_FILE"
    depends_on:
      mysql:
        condition: service_healthy
EOF
    fi

    # 续写 MySQL 节点与健康探测 (root与普通用户进行密码隔离)
    if [[ "$db_mode" == "1" ]]; then
        mkdir -p "$BASE_DIR/mysql"
        cat << EOF >> "$COMPOSE_FILE"

  mysql:
    image: mysql:8
    container_name: ppanel-mysql
    restart: always
    environment:
      MYSQL_DATABASE: "${db_name}"
      MYSQL_USER: "${db_user}"
      MYSQL_PASSWORD: "${db_pass}"
      MYSQL_ROOT_PASSWORD: "${root_pass}"
    volumes:
      - ./mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-p${root_pass}"]
      interval: 5s
      timeout: 5s
      retries: 20
    networks:
      - ppanel-network
EOF
    fi

    # 续写 Redis 节点
    if [[ "$redis_mode" == "1" ]]; then
        mkdir -p "$BASE_DIR/redis"
        cat << EOF >> "$COMPOSE_FILE"

  redis:
    image: redis:7
    container_name: ppanel-redis
    restart: always
    command: redis-server --requirepass "${redis_pass}"
    volumes:
      - ./redis:/data
    networks:
      - ppanel-network
EOF
    fi

    echo -e "${YELLOW}正在执行容器编排拉起服务 (主程序将自动在后台等待 MySQL 完成初始化)...${RESET}"
    cd "$BASE_DIR"
    docker compose down 2>/dev/null
    rm -rf ./web/admin ./web/admin_bak ./web/user 2>/dev/null
    
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 服务拉起失败，请检查端口 ${custom_port} 是否被占用。${RESET}"
        return
    fi

    local detect_ip=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}           PPanel 系统架构部署成功！                ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}前台访问地址   : http://${detect_ip}:${custom_port}${RESET}"
    echo -e "${YELLOW}后台管理地址   : http://${detect_ip}:${custom_port}/admin${RESET}"
    echo -e "${YELLOW}默认账号       : admin@ppanel.dev${RESET}"
    echo -e "${YELLOW}默认密码       : password${RESET}"
    echo -e "----------------------------------------------------"
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${CYAN}[内置数据库安全隔离审计]${RESET}"
        echo -e "${YELLOW}超级管理员账户 : root / 密: ${root_pass}${RESET}"
        echo -e "${YELLOW}面板业务关联户 : ${db_user} / 密: ${db_pass}${RESET}"
    fi
    echo -e "${GREEN}====================================================${RESET}"
}

# 2. 更新容器
update_ppanel() {
    check_dependencies
    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}正在从官方中心拉取最新 PPanel 核心镜像...${RESET}"
        cd "$BASE_DIR"
        docker compose pull
        rm -rf ./web/admin ./web/admin_bak ./web/user 2>/dev/null
        docker compose up -d
        echo -e "${GREEN}✅ PPanel 镜像更新并重启完成！${RESET}"
    else
        echo -e "${RED}错误: 尚未检测到部署拓扑，请先执行“1. 部署启动”。${RESET}"
    fi
}

# 3. 卸载容器
uninstall_ppanel() {
    echo -ne "${RED}确定要卸载并删除 PPanel 相关的容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            echo -e "${YELLOW}正在停止并安全移除容器及网络...${RESET}"
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            
            echo -ne "${YELLOW}是否同时删除本地所有配置文件和持久化数据目录？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                cd /opt && rm -rf "$BASE_DIR"
                echo -e "${GREEN}数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f ppanel ppanel-mysql ppanel-redis 2>/dev/null
        fi
        echo -e "${GREEN}卸载流程执行完毕！${RESET}"
    fi
}

# 4. 启动容器 / 5. 停止容器 / 6. 重启容器
start_ppanel() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}✅ 服务已整体拉起运行${RESET}"; }
stop_ppanel() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}🛑 服务已整体停止运行${RESET}"; }
restart_ppanel() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}✅ 服务已整体成功重启${RESET}"; }

# 7. 查看日志
logs_ppanel() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

# 8. 查看配置
show_info() {
    get_status_info
    local detect_ip=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态   : $status"
    echo -e "${YELLOW}安全绝对路径   : ${BASE_DIR}${RESET}"
    echo -e "${YELLOW}前台访问地址   : http://${detect_ip}:${web_port}${RESET}"
    echo -e "${YELLOW}后台管理地址   : http://${detect_ip}:${web_port}/admin${RESET}"
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}业务配置文件   : ${CONFIG_FILE}${RESET}"
    fi
    echo -e "${GREEN}====================================================${RESET}"
}

# 主菜单管理
menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}        ◈ PPanel 管理面板 ◈        ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN} 当前状态 :${RESET} $status"
    echo -e "${GREEN} 映射端口 :${RESET} ${YELLOW}${web_port}${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN} 1. 部署启动${RESET}"
    echo -e "${GREEN} 2. 更新容器${RESET}"
    echo -e "${GREEN} 3. 卸载容器${RESET}"
    echo -e "${GREEN} 4. 启动容器${RESET}"
    echo -e "${GREEN} 5. 停止容器${RESET}"
    echo -e "${GREEN} 6. 重启容器${RESET}"
    echo -e "${GREEN} 7. 查看日志${RESET}"
    echo -e "${GREEN} 8. 查看配置${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_ppanel ;;
        2) update_ppanel ;;
        3) uninstall_ppanel ;;
        4) start_ppanel ;;
        5) stop_ppanel ;;
        6) restart_ppanel ;;
        7) logs_ppanel ;;
        8) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "\n${YELLOW}按回车键继续...${RESET}"
    read -r
done
