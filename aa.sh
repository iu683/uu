#!/bin/bash
# =================================================================
# WordPress Docker Compose 管理面板
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/wordpress"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
DEFAULT_IMAGE="wordpress:latest"

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
        if [ "$(docker ps -q -f name=wordpress-server)" ]; then
            status="${GREEN}运行中${RESET}"
            web_port=$(docker ps -f name=wordpress-server --format "{{.Ports}}" | sed -E 's/.*0.0.0.0:([0-9]+)->.*/\1/' | head -n 1)
            if ! [[ "$web_port" =~ ^[0-9]+$ ]]; then
                web_port=$(sed -n '/wordpress:/,/^[[:space:]]*[a-zA-Z]/p' "$COMPOSE_FILE" | grep -E '\-[[:space:]]*["'\'']?[0-9]+:' | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"''-')
            fi
        elif [ "$(docker ps -aq -f name=wordpress-server)" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' wordpress-server 2>/dev/null)
        else
            status="${RED}未部署${RESET}"
        fi
        [[ -z "$web_port" ]] && web_port="80"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署 WordPress
install_wordpress() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    # 1. 基础映射端口配置
    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 WordPress 宿主机映射访问端口 [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 2. 数据库运行模式选择
    echo -e "\n${CYAN}====== 1. MySQL 数据库运行模式选择 ======${RESET}"
    echo -e " 1) 直接部署全新的 MySQL 8.0 容器 (包含本地持久化卷)"
    echo -e " 2) 使用已有的外部/远程 MySQL 数据库 (需提前手动建好空库)"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    local db_host="db"
    local db_user="wordpress"
    local db_pass=""
    local db_name="wordpress"
    local root_pass=""

    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}正在自动计算生成数据库高强度防破解随机密码...${RESET}"
        root_pass=$(openssl rand -hex 12)
        db_pass=$(openssl rand -hex 12)
    else
        echo -ne "${YELLOW}请输入外部 MySQL 的 IP 或域名 [默认: 172.17.0.1]: ${RESET}"
        read -r ext_db_ip
        [[ -z "$ext_db_ip" ]] && ext_db_ip="172.17.0.1"
        echo -ne "${YELLOW}请输入外部 MySQL 端口 [默认: 3306]: ${RESET}"
        read -r ext_db_port
        [[ -z "$ext_db_port" ]] && ext_db_port="3306"
        db_host="${ext_db_ip}:${ext_db_port}"
        echo -ne "${YELLOW}请输入外部 MySQL 用户名 [默认: wordpress]: ${RESET}"
        read -r db_user
        [[ -z "$db_user" ]] && db_user="wordpress"
        echo -ne "${YELLOW}请输入外部 MySQL 密码: ${RESET}"
        read -r db_pass
        echo -ne "${YELLOW}请输入外部已存在的数据库名 [默认: wordpress]: ${RESET}"
        read -r db_name
        [[ -z "$db_name" ]] && db_name="wordpress"
        
        # 破壁 Docker 宿主机回环地址限制
        if [[ "$ext_db_ip" == "127.0.0.1" || "$ext_db_ip" == "localhost" ]]; then
            db_host="172.17.0.1:${ext_db_port}"
        fi
        echo -e "${YELLOW}提示: 请确保远程 MySQL (${db_host}) 中已提前手动创建好名为 '${db_name}' 的数据库！${RESET}"
    fi

    # 3. Redis 运行模式选择与分区注入
    echo -e "\n${CYAN}====== 2. Redis 缓存运行模式选择 ======${RESET}"
    echo -e " 1) 直接部署全新的 Redis 容器 (免密本地内部网络访问)"
    echo -e " 2) 使用已有的外部/远程 Redis 缓存服务 (支持密码+库分区绑定)"
    echo -ne "${YELLOW}请选择 Redis 模式 [默认: 1]: ${RESET}"
    read -r redis_mode
    [[ -z "$redis_mode" ]] && redis_mode="1"

    local wp_redis_host="redis"
    local wp_redis_password=""
    local wp_redis_db="0"

    if [[ "$redis_mode" == "2" ]]; then
        echo -ne "${YELLOW}请输入外部 Redis 的 IP 或域名 [默认: 172.17.0.1]: ${RESET}"
        read -r ext_redis_ip
        [[ -z "$ext_redis_ip" ]] && ext_redis_ip="172.17.0.1"
        echo -ne "${YELLOW}请输入外部 Redis 端口 [默认: 6379]: ${RESET}"
        read -r ext_redis_port
        [[ -z "$ext_redis_port" ]] && ext_redis_port="6379"
        wp_redis_host="${ext_redis_ip}:${ext_redis_port}"
        echo -ne "${YELLOW}远程 Redis 分区/库编号 (DB Index) [默认 0]: ${RESET}"
        read -r tmp_rdb; [[ -n "$tmp_rdb" ]] && wp_redis_db="$tmp_rdb"
        echo -ne "${YELLOW}请输入外部 Redis 密码 (若无密码请直接留空回车): ${RESET}"
        read -r wp_redis_password
        
        # 破壁 Docker 宿主机回环地址限制
        if [[ "$ext_redis_ip" == "127.0.0.1" || "$ext_redis_ip" == "localhost" ]]; then
            wp_redis_host="172.17.0.1:${ext_redis_port}"
        fi
    else
        # 常规内置模式也允许选择独立分区，方便单 Redis 跑多站
        echo -ne "${YELLOW}请输入内置 Redis 独占分区/库编号 (DB Index) [默认 0]: ${RESET}"
        read -r tmp_rdb; [[ -n "$tmp_rdb" ]] && wp_redis_db="$tmp_rdb"
    fi

    # 4. 精准分割 Redis 主机与端口并处理字符串机制
    local redis_pure_host="${wp_redis_host%%:*}"
    local redis_pure_port="${wp_redis_host##*:}"
    if [[ "$redis_pure_host" == "$redis_pure_port" ]]; then
        redis_pure_port="6379"
    fi

    # 5. 生成结构化的依赖节点（放弃不稳定的 sed，采用内存拼接注入）
    local server_depends=""
    if [[ "$db_mode" == "1" || "$redis_mode" == "1" ]]; then
        server_depends="    depends_on:"
        [[ "$db_mode" == "1" ]] && server_depends="${server_depends}\n      - db"
        [[ "$redis_mode" == "1" ]] && server_depends="${server_depends}\n      - redis"
    fi

    # 6. 生成 docker-compose.yml 文本
    echo -e "\n${YELLOW}正在生成持久化 Docker Compose 配置文件...${RESET}"
    mkdir -p "$BASE_DIR/data"

    # 生成核心业务基础拓扑
    cat << EOF > "$COMPOSE_FILE"
services:
  wordpress:
    image: ${DEFAULT_IMAGE}
    container_name: wordpress-server
    restart: unless-stopped
    ports:
      - "${custom_port}:80"
    volumes:
      - ${BASE_DIR}/data:/var/www/html
    environment:
      WORDPRESS_DB_HOST: ${db_host}
      WORDPRESS_DB_NAME: ${db_name}
      WORDPRESS_DB_USER: ${db_user}
      WORDPRESS_DB_PASSWORD: ${db_pass}
      WORDPRESS_CONFIG_EXTRA: |
        define('WP_REDIS_HOST', '${redis_pure_host}');
        define('WP_REDIS_PORT', ${redis_pure_port});
        define('WP_REDIS_DATABASE', ${wp_redis_db});
EOF

    # 如果配置了密码，动态优雅注入密码常量
    if [[ -n "$wp_redis_password" ]]; then
        cat << EOF >> "$COMPOSE_FILE"
        define('WP_REDIS_PASSWORD', '${wp_redis_password}');
EOF
    fi

    # 追加安全生成的依赖拓扑
    if [[ -n "$server_depends" ]]; then
        echo -e "${server_depends}" >> "$COMPOSE_FILE"
    fi

    # 7. 动态追加本地内置底层服务组件
    if [[ "$db_mode" == "1" ]]; then
        mkdir -p "$BASE_DIR/db"
        cat << EOF >> "$COMPOSE_FILE"

  db:
    image: mysql:8.0
    container_name: wordpress-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${root_pass}
      MYSQL_DATABASE: ${db_name}
      MYSQL_USER: ${db_user}
      MYSQL_PASSWORD: ${db_pass}
    volumes:
      - ${BASE_DIR}/db:/var/lib/mysql
EOF
    fi

    if [[ "$redis_mode" == "1" ]]; then
        mkdir -p "$BASE_DIR/redis"
        cat << EOF >> "$COMPOSE_FILE"

  redis:
    image: redis:alpine
    container_name: wordpress-redis
    restart: unless-stopped
    volumes:
      - ${BASE_DIR}/redis:/data
EOF
    fi

    # 8. 执行一键安全洗牌拉起
    echo -e "${YELLOW}正在通过 Docker Compose 启动 WordPress 容器集群...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 架构拉起失败，请检查端口是否被占用。${RESET}"
        return
    fi

    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             WordPress 部署成功！                    ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}外部访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}宿主机映射端口 : ${custom_port}${RESET}"
    echo -e "----------------------------------------------------"
    echo -e "${CYAN}[数据库凭据回显]${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}MySQL 运行模式 : ${GREEN}全新内置容器 (MySQL 8.0)${RESET}"
        echo -e "${YELLOW}内置实例库名   : ${db_name}${RESET}"
        echo -e "${YELLOW}MySQL root密码 : ${RED}${root_pass}${RESET}"
        echo -e "${YELLOW}WP专账用户名   : ${GREEN}${db_user}${RESET}"
        echo -e "${YELLOW}WP专账访问密码 : ${GREEN}${db_pass}${RESET}"
    else
        echo -e "${YELLOW}MySQL 运行模式 : ${CYAN}外部远程连接${RESET}"
        echo -e "${YELLOW}远程目标主机   : ${db_host}${RESET}"
        echo -e "${YELLOW}指定连接库名   : ${db_name}${RESET}"
        echo -e "${YELLOW}连接用户名     : ${db_user}${RESET}"
        echo -e "${YELLOW}连接密码       : ****** (您输入的外部密码)${RESET}"
    fi
    echo -e "----------------------------------------------------"
    echo -e "${CYAN}[Redis 凭据回显]${RESET}"
    if [[ "$redis_mode" == "1" ]]; then
        echo -e "${YELLOW}Redis 运行模式 : ${GREEN}全新内置容器 (隔离专用网段)${RESET}"
        echo -e "${YELLOW}独占绑库分区   : ${MAGENTA}DB Index [ ${wp_redis_db} ]${RESET}"
    else
        echo -e "${YELLOW}Redis 运行模式 : ${CYAN}外部远程缓存${RESET}"
        echo -e "${YELLOW}Redis 目标主机 : ${wp_redis_host}${RESET}"
        echo -e "${YELLOW}流向绑库分区   : ${MAGENTA}DB Index [ ${wp_redis_db} ]${RESET}"
        if [[ -n "$wp_redis_password" ]]; then
            echo -e "${YELLOW}Redis 验证状态 : ${GREEN}带密码安全认证 (已成功注入环境)${RESET}"
        else
            echo -e "${YELLOW}Redis 验证状态 : ${YELLOW}免密开放模式${RESET}"
        fi
    fi
    echo -e "----------------------------------------------------"
    echo -e "${YELLOW}持久化工作目录 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}


# 更新镜像
update_wp() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}升级完成！${RESET}"
}

# 卸载 WordPress
uninstall_wp() {
    echo -ne "${RED}确定要完全卸载并删除 WordPress 服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            rm -rf "$BASE_DIR"
        else
            docker rm -f wordpress-server wordpress-db wordpress-redis 2>/dev/null
        fi
        echo -e "${GREEN}完全卸载成功，数据已彻底清理。${RESET}"
    fi
}

start_wp() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已拉起运行${RESET}"; }
stop_wp() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止运行${RESET}"; }
restart_wp() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已成功重启${RESET}"; }
logs_wp() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

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
    echo -e "${GREEN}      ◈  WordPress 管理面板  ◈        ${RESET}"
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
        1) install_wordpress ;;
        2) update_wp ;;
        3) uninstall_wp ;;
        4) start_wp ;;
        5) stop_wp ;;
        6) restart_wp ;;
        7) logs_wp ;;
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
