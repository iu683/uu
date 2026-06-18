#!/bin/bash
# =================================================================
# Moments Blog Docker Compose 管理面板
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/moments"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/moments.env"
DEFAULT_IMAGE="koalalove/moments-blog:latest"

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
        if [ "$(docker ps -q -f name=moments-blog)" ]; then
            status="${GREEN}运行中${RESET}"
            web_port=$(docker ps -f name=moments-blog --format "{{.Ports}}" | sed -E 's/.*:([0-9]+)->.*/\1/' | head -n 1)
            if ! [[ "$web_port" =~ ^[0-9]+$ ]]; then
                web_port=$(sed -n '/moments-blog:/,/^[[:space:]]*[a-zA-Z]/p' "$COMPOSE_FILE" | grep -E '\-[[:space:]]*["'\'']?[0-9]+:' | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"''-')
            fi
        elif [ "$(docker ps -aq -f name=moments-blog)" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' moments-blog 2>/dev/null)
        else
            status="${RED}未部署${RESET}"
        fi
        [[ -z "$web_port" ]] && web_port="80"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署 Moments
install_moments() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    # 1. 基础参数配置
    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Moments 宿主机映射访问端口 [默认: 80]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="80"
    
    echo -ne "${YELLOW}请输入反向代理跳数 TRUST_PROXY (直接公网暴露填 1，前面有宿主机Nginx填 2) [默认: 1]: ${RESET}"
    read -r trust_proxy
    [[ -z "$trust_proxy" ]] && trust_proxy="1"

    # 自动生成 64 位强安全 JWT 密钥
    local jwt_secret=$(openssl rand -hex 64)

    # 2. 数据库运行模式选择
    echo -e "\n${CYAN}====== PostgreSQL 数据库运行模式选择 ======${RESET}"
    echo -e " 1) 启动单容器内嵌自带的 PostgreSQL 15 (全自动一体化，推荐)"
    echo -e " 2) 使用已有的外部/远程外部 PostgreSQL 数据库 (跳过容器自带PG)"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    local db_host_ip="127.0.0.1"
    local db_port="5432"
    local db_user="moments"
    local db_pass="moments_password"
    local db_name="moments"

    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}使用容器内嵌自启数据库，正在生成安全随机密码...${RESET}"
        db_pass=$(openssl rand -hex 12)
    else
        echo -ne "${YELLOW}请输入远程 PostgreSQL 的 IP 或域名 [例如: 47.79.88.134]: ${RESET}"
        read -r ext_db_ip
        echo -ne "${YELLOW}请输入远程 PostgreSQL 端口 [默认: 5432]: ${RESET}"
        read -r ext_db_port
        [[ -z "$ext_db_port" ]] && ext_db_port="5432"
        db_host_ip="$ext_db_ip"
        db_port="$ext_db_port"
        echo -ne "${YELLOW}请输入远程 PostgreSQL 用户名 [默认: moments]: ${RESET}"
        read -r db_user
        [[ -z "$db_user" ]] && db_user="moments"
        echo -ne "${YELLOW}请输入远程 PostgreSQL 密码: ${RESET}"
        read -r db_pass
        echo -ne "${YELLOW}请输入远程已存在的数据库名 [默认: moments]: ${RESET}"
        read -r db_name
        [[ -z "$db_name" ]] && db_name="moments"
        
        # 兼容宿主机回环地址
        if [[ "$ext_db_ip" == "127.0.0.1" || "$ext_db_ip" == "localhost" ]]; then
            db_host_ip="172.17.0.1"
        fi
    fi

    # 3. 创建基础持久化数据目录
    mkdir -p "$BASE_DIR/data/uploads" "$BASE_DIR/data/logs"

    # 4. 组装最终的连接串
    local database_url="postgresql://${db_user}:${db_pass}@${db_host_ip}:${db_port}/${db_name}"

    # 5. 生成备份供日常查阅的 moments.env
    cat << EOF > "$ENV_FILE"
HOST_PORT=${custom_port}
TRUST_PROXY=${trust_proxy}
JWT_SECRET=${jwt_secret}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_pass}
DATABASE_URL=${database_url}
EOF

    # 6. 【核心修复点】采用完全独立的 if-else 分流生成 YML，绝不交叉追加导致 Key 重复
    echo -e "${YELLOW}正在生成规范化 Docker Compose 配置文件...${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        # 模式 1：包含 PGDATA 变量以及数据库卷挂载
        mkdir -p "$BASE_DIR/data/postgres"
        cat << EOF > "$COMPOSE_FILE"
services:
  moments-blog:
    image: ${DEFAULT_IMAGE}
    container_name: moments-blog
    restart: unless-stopped
    ports:
      - "${custom_port}:80"
    volumes:
      - ./data/uploads:/data/uploads
      - ./data/logs:/data/logs
      - ./data/postgres:/var/lib/postgresql/data
    environment:
      - JWT_SECRET=${jwt_secret}
      - DATABASE_URL=${database_url}
      - NODE_ENV=production
      - PORT=3001
      - UPLOAD_DIR=/data/uploads
      - INTERNAL_API_URL=http://localhost:3001
      - TRUST_PROXY=${trust_proxy}
      - PGDATA=/var/lib/postgresql/data
    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "5"
EOF
    else
        # 模式 2：纯净远程对接，移除本地数据库存储卷以及 PGDATA 声明
        cat << EOF > "$COMPOSE_FILE"
services:
  moments-blog:
    image: ${DEFAULT_IMAGE}
    container_name: moments-blog
    restart: unless-stopped
    ports:
      - "${custom_port}:80"
    volumes:
      - ./data/uploads:/data/uploads
      - ./data/logs:/data/logs
    environment:
      - JWT_SECRET=${jwt_secret}
      - DATABASE_URL=${database_url}
      - NODE_ENV=production
      - PORT=3001
      - UPLOAD_DIR=/data/uploads
      - INTERNAL_API_URL=http://localhost:3001
      - TRUST_PROXY=${trust_proxy}
    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "5"
EOF
    fi

    # 7. 清理旧容器并启动新集群
    echo -e "${YELLOW}正在拉起 Moments 容器架构...${RESET}"
    cd "$BASE_DIR"
    docker compose down -v 2>/dev/null
    docker compose up -d --force-recreate

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 服务拉起失败，请检查端口 ${custom_port} 是否被占用。${RESET}"
        return
    fi

    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             Moments 博客系统部署成功！               ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}外部访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}初始管理账号   : admin${RESET}"
    echo -e "${YELLOW}初始默认密码   : Strong1passwd! (登录后请立即前往后台修改)${RESET}"
    echo -e "----------------------------------------------------"
    echo -e "${CYAN}[数据库拓扑连接回显]${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}数据库运行状态 : ${GREEN}容器内嵌自带自启 (PostgreSQL 15)${RESET}"
        echo -e "${YELLOW}分配实例库名   : ${db_name}${RESET}"
        echo -e "${YELLOW}随机高强密码   : ${GREEN}${db_pass}${RESET}"
    else
        echo -e "${YELLOW}数据库运行状态 : ${CYAN}外部远程对接${RESET}"
        echo -e "${YELLOW}远程目标节点   : ${db_host_ip}:${db_port}${RESET}"
        echo -e "${YELLOW}指定连接库名   : ${db_name}${RESET}"
        echo -e "${YELLOW}连接用户名     : ${db_user}${RESET}"
    fi
    echo -e "----------------------------------------------------"
    echo -e "${YELLOW}持久化工作目录 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_moments() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 Moments 镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}升级完成！${RESET}"
}

# 卸载 Moments
uninstall_moments() {
    echo -ne "${RED}确定要完全卸载并删除 Moments 服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            rm -rf "$BASE_DIR"
        else
            docker rm -f moments-blog 2>/dev/null
        fi
        echo -e "${GREEN}完全卸载成功，数据已彻底清理。${RESET}"
    fi
}

start_moments() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已拉起运行${RESET}"; }
stop_moments() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止运行${RESET}"; }
restart_moments() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已成功重启${RESET}"; }
logs_moments() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

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
    echo -e "${GREEN}       ◈  Moments 管理面板  ◈        ${RESET}"
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
        1) install_moments ;;
        2) update_moments ;;
        3) uninstall_moments ;;
        4) start_moments ;;
        5) stop_moments ;;
        6) restart_moments ;;
        7) logs_moments ;;
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
