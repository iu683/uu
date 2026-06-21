#!/bin/bash
# =================================================================
# Acgfaka Docker Compose 管理面板 (内置库/远程库/缓存自适应三模版)
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/acgfaka"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
DEFAULT_IMAGE="dapiaoliang666/acgfaka"

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

# 动态获取容器整体状态和端口 (采用原生 Docker Inspect 终极技术)
get_status_info() {
    if [ -f "$COMPOSE_FILE" ]; then
        if [ "$(docker ps -q -f name=acgfaka)" ]; then
            status="${GREEN}运行中${RESET}"
            web_port=$(docker inspect --format='{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' acgfaka 2>/dev/null)
        elif [ "$(docker ps -aq -f name=acgfaka)" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=""
        else
            status="${RED}未部署${RESET}"
            web_port=""
        fi
        
        if [ -z "$web_port" ]; then
            web_port=$(sed -n '/acgfaka:/,/^[[:space:]]*[a-zA-Z]/p' "$COMPOSE_FILE" | grep -E '\-[[:space:]]*["'\'']?[0-9]+:' | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"''-')
            [[ -z "$web_port" ]] && web_port="8000"
        fi
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署 Acgfaka
install_acgfaka() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${GREEN}=====================================${RESET}"
    echo -e "${CYAN}====== 数据库/缓存运行模式选择 ======${RESET}"
    echo -e "${GREEN}=====================================${RESET}"
    echo -e " 1. 直接部署全新且完整的环境 (包含全新 MySQL 5.7 + Redis)"
    echo -e " 2. 使用外部已有 MySQL，但在本地部署全新 Redis 缓存"
    echo -e " 3. 同时使用外部已有 MySQL 和外部已有 Redis"
    echo -ne "${YELLOW}请选择架构部署模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Acgfaka Web 访问端口 [默认: 8000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8000"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 预设自动化环境目录
    mkdir -p "$BASE_DIR/acgfaka"

    # ------------------ 模式 1：全套本地内置容器化 ------------------
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}正在自动计算生成数据库高强度防破解随机密码...${RESET}"
        local rand_root_pass=$(openssl rand -hex 12)
        local rand_user_pass=$(openssl rand -hex 12)
        local rand_user="acgfaka_user"
        local rand_db="acgfakadb"

        mkdir -p "$BASE_DIR/mysql"

        cat << EOF > "$COMPOSE_FILE"
services:
  acgfaka:
    image: ${DEFAULT_IMAGE}
    container_name: acgfaka
    restart: always
    ports:
      - "${custom_port}:80"
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_started
    environment:
      PHP_OPCACHE_ENABLE: 1
      PHP_OPCACHE_MEMORY_CONSUMPTION: 128
      PHP_OPCACHE_MAX_ACCELERATED_FILES: 10000
      PHP_OPCACHE_REVALIDATE_FREQ: 2
      PHP_REDIS_HOST: redis
      PHP_REDIS_PORT: 6379
      PHP_REDIS_DB: 0
    volumes:
      - ${BASE_DIR}/acgfaka:/var/www/html

  mysql:
    image: mysql:5.7
    container_name: acgfaka-mysql
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${rand_root_pass}
      MYSQL_DATABASE: ${rand_db}
      MYSQL_USER: ${rand_user}
      MYSQL_PASSWORD: ${rand_user_pass}
    volumes:
      - ${BASE_DIR}/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h localhost -uroot -p${rand_root_pass}"]
      interval: 5s
      timeout: 5s
      retries: 10

  redis:
    image: redis:latest
    container_name: acgfaka-redis
    restart: always
EOF

        echo -e "${YELLOW}正在通过 Docker Compose 部署启动全套 Acgfaka 集群...${RESET}"
        cd "$BASE_DIR" && docker compose up -d --force-recreate
        if [ $? -ne 0 ]; then echo -e "${RED}部署失败，请检查 Docker 日志。${RESET}"; return; fi

    # ------------------ 模式 2：外部 MySQL + 本地内置 Redis ------------------
    elif [[ "$db_mode" == "2" ]]; then
        echo -e "${CYAN}====== 远程/外部 MySQL 数据库信息输入 ======${RESET}"
        echo -ne "${YELLOW}请输入外部 MySQL IP/域名 [默认: 127.0.0.1]: ${RESET}"
        read -r ext_mysql_host
        [[ -z "$ext_mysql_host" ]] && ext_mysql_host="127.0.0.1"

        # 回环桥接处理
        [[ "$ext_mysql_host" == "127.0.0.1" || "$ext_mysql_host" == "localhost" ]] && ext_mysql_host="172.17.0.1"
        
        cat << EOF > "$COMPOSE_FILE"
services:
  acgfaka:
    image: ${DEFAULT_IMAGE}
    container_name: acgfaka
    restart: always
    ports:
      - "${custom_port}:80"
    depends_on:
      - redis
    environment:
      PHP_OPCACHE_ENABLE: 1
      PHP_OPCACHE_MEMORY_CONSUMPTION: 128
      PHP_OPCACHE_MAX_ACCELERATED_FILES: 10000
      PHP_OPCACHE_REVALIDATE_FREQ: 2
      PHP_REDIS_HOST: redis
      PHP_REDIS_PORT: 6379
      PHP_REDIS_DB: 0
    volumes:
      - ${BASE_DIR}/acgfaka:/var/www/html

  redis:
    image: redis:latest
    container_name: acgfaka-redis
    restart: always
EOF
        cd "$BASE_DIR" && docker compose up -d --force-recreate

    # ------------------ 模式 3：外部 MySQL + 外部可含密码 Redis ------------------
    else
        echo -e "${CYAN}====== 远程/外部 MySQL 配置 ======${RESET}"
        echo -ne "${YELLOW}请输入外部 MySQL IP/域名 [默认: 127.0.0.1]: ${RESET}"
        read -r ext_mysql_host
        [[ -z "$ext_mysql_host" ]] && ext_mysql_host="127.0.0.1"

        echo -e "${CYAN}====== 远程/外部 Redis 配置 ======${RESET}"
        echo -ne "${YELLOW}请输入外部 Redis IP/域名 [默认: 127.0.0.1]: ${RESET}"
        read -r ext_redis_host
        [[ -z "$ext_redis_host" ]] && ext_redis_host="127.0.0.1"

        echo -ne "${YELLOW}请输入外部 Redis 端口 [默认: 6379]: ${RESET}"
        read -r ext_redis_port
        [[ -z "$ext_redis_port" ]] && ext_redis_port="6379"

        # 密码按需配置逻辑
        echo -e "${GREEN}(提示: 如果外部 Redis 没有设置密码，请直接【回车】跳过)${RESET}"
        echo -ne "${YELLOW}请输入外部 Redis 密码 [留空表示无密码]: ${RESET}"
        read -r ext_redis_pass

        # === 统一合并为一个 Redis 数据库号输入 ===
        echo -ne "${YELLOW}请输入远程 Redis 数据库号 (DB ID) [默认: 0]: ${RESET}"
        read -r redis_db_cfg
        [[ -z "$redis_db_cfg" ]] && redis_db_cfg="0"

        # 回环重定向桥接
        [[ "$ext_mysql_host" == "127.0.0.1" || "$ext_mysql_host" == "localhost" ]] && ext_mysql_host="172.17.0.1"
        [[ "$ext_redis_host" == "127.0.0.1" || "$ext_redis_host" == "localhost" ]] && ext_redis_host="172.17.0.1"

        cat << EOF > "$COMPOSE_FILE"
services:
  acgfaka:
    image: ${DEFAULT_IMAGE}
    container_name: acgfaka
    restart: always
    ports:
      - "${custom_port}:80"
    environment:
      PHP_OPCACHE_ENABLE: 1
      PHP_OPCACHE_MEMORY_CONSUMPTION: 128
      PHP_OPCACHE_MAX_ACCELERATED_FILES: 10000
      PHP_OPCACHE_REVALIDATE_FREQ: 2
      PHP_REDIS_HOST: ${ext_redis_host}
      PHP_REDIS_PORT: ${ext_redis_port}
      PHP_REDIS_DB: ${redis_db_cfg}
EOF

        # 如果用户输入了 Redis 密码，则动态追加密码环境变量
        if [[ -n "$ext_redis_pass" ]]; then
            echo "      PHP_REDIS_PASSWORD: ${ext_redis_pass}" >> "$COMPOSE_FILE"
        fi

        # 闭合挂载卷配置
        cat << EOF >> "$COMPOSE_FILE"
    volumes:
      - ${BASE_DIR}/acgfaka:/var/www/html
EOF
        cd "$BASE_DIR" && docker compose up -d --force-recreate
    fi

    if [ $? -ne 0 ]; then echo -e "${RED}服务拉起异常。${RESET}"; return; fi

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             Acgfaka 部署成功！                     ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}访问端点(URL) : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}映射宿主机端口 : ${custom_port}${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}内置库凭证    : 用户:${rand_user} | 密码:${rand_user_pass} | 库名:${rand_db}${RESET}"
        echo -e "${YELLOW}内置库Host管理 : 直接填 mysql 即可${RESET}"
    else
        echo -e "${YELLOW}外部 MySQL 节点: ${ext_mysql_host}${RESET}"
    fi
    
    if [[ "$db_mode" == "3" ]]; then
        if [[ -n "$ext_redis_pass" ]]; then
            echo -e "${YELLOW}外部 Redis 状态: 已连接 -> ${ext_redis_host}:${ext_redis_port} (密码验证开启)${RESET}"
        else
            echo -e "${YELLOW}外部 Redis 状态: 已连接 -> ${ext_redis_host}:${ext_redis_port} (无密码模式)${RESET}"
        fi
        echo -e "${CYAN}Redis DB 配置  : DB ID: ${redis_db_cfg}${RESET}"
    fi
    echo -e "${YELLOW}部署工作路径   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}


# 更新服务
update_acgfaka() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取 Acgfaka 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}服务已拉升至最新版本状态！${RESET}"
}

# 卸载集群
uninstall_acgfaka() {
    echo -ne "${RED}确定要注销并删除 Acgfaka 服务集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已全部终止移除。${RESET}"
            echo -ne "${RED}是否同步清理掉本地所有源码、配置及内置数据库数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                cd "$BASE_DIR" && docker compose down -v
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}工作目录及持久化挂载文件已被彻底净化清除。${RESET}"
            fi
        else
            docker rm -f acgfaka acgfaka-mysql acgfaka-redis 2>/dev/null
        fi
        echo -e "${GREEN}完全卸载完毕！${RESET}"
    fi
}

# 控制命令
start_ak() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务集群已正常启动${RESET}"; }
stop_ak() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务集群已安全暂停${RESET}"; }
restart_ak() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务集群已完成软重启${RESET}"; }
logs_ak() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

# 查看配置信息
show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态   : $status"
    echo -e "${YELLOW}实际映射端口   : ${web_port}${RESET}"
    echo -e "${YELLOW}本地项目路径   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 主菜单
menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}       ◈  Acgfaka 管理面板  ◈       ${RESET}"
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
        1) install_acgfaka ;;
        2) update_acgfaka ;;
        3) uninstall_acgfaka ;;
        4) start_ak ;;
        5) stop_ak ;;
        6) restart_ak ;;
        7) logs_ak ;;
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
