#!/bin/bash
# =================================================================
# Umami 网站统计系统 Docker Compose 管理面板 (内置+远程双模版)
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/umami"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/umami.env"

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
        if [ "$(docker ps -q -f name=umami)" ]; then
            status="${GREEN}运行中${RESET}"
            web_port=$(docker ps -f name=umami --format "{{.Ports}}" | sed -E 's/.*:([0-9]+)->.*/\1/' | head -n 1)
            if ! [[ "$web_port" =~ ^[0-9]+$ ]]; then
                web_port=$(sed -n '/umami:/,/^[[:space:]]*[a-zA-Z]/p' "$COMPOSE_FILE" | grep -E '\-[[:space:]]*["'\'']?[0-9]+:' | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"''-')
            fi
        elif [ "$(docker ps -aq -f name=umami)" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' umami 2>/dev/null)
        else
            status="${RED}未部署${RESET}"
        fi
        [[ -z "$web_port" ]] && web_port="3000"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署 Umami
install_umami() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    # 1. 基础参数配置
    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Umami 宿主机映射访问端口 [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"

    # 自动生成 Umami 的哈希加盐密钥
    local app_secret=$(openssl rand -hex 32)

    # 2. 数据库运行模式选择
    echo -e "\n${CYAN}====== PostgreSQL 数据库运行模式选择 ======${RESET}"
    echo -e " 1) 直接部署全新的 PostgreSQL 15 容器 (包含本地持久化卷)"
    echo -e " 2) 使用已有的外部/远程 PostgreSQL 数据库 (需提前手动建好空库)"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    local db_host_ip="db"
    local db_port="5432"
    local db_user="umami"
    local db_pass=""
    local db_name="umami"

    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}使用全新内置数据库容器，正在生成高强度随机密码...${RESET}"
        db_pass=$(openssl rand -hex 16)
    else
        echo -ne "${YELLOW}请输入远程 PostgreSQL 的 IP 或域名 [例如: 47.79.88.134]: ${RESET}"
        read -r ext_db_ip
        echo -ne "${YELLOW}请输入远程 PostgreSQL 端口 [默认: 5432]: ${RESET}"
        read -r ext_db_port
        [[ -z "$ext_db_port" ]] && ext_db_port="5432"
        db_host_ip="$ext_db_ip"
        db_port="$ext_db_port"
        echo -ne "${YELLOW}请输入远程 PostgreSQL 用户名 [默认: umami]: ${RESET}"
        read -r db_user
        [[ -z "$db_user" ]] && db_user="umami"
        echo -ne "${YELLOW}请输入远程 PostgreSQL 密码: ${RESET}"
        read -r db_pass
        echo -ne "${YELLOW}请输入远程已存在的数据库名 [默认: umami]: ${RESET}"
        read -r db_name
        [[ -z "$db_name" ]] && db_name="umami"
        
        # 兼容本地宿主机回环网关
        if [[ "$ext_db_ip" == "127.0.0.1" || "$ext_db_ip" == "localhost" ]]; then
            db_host_ip="172.17.0.1"
        fi
    fi

    # 3. 动态拼接生成强连接串
    local database_url="postgresql://${db_user}:${db_pass}@${db_host_ip}:${db_port}/${db_name}"

    # 4. 备份保留凭证文件 umami.env
    cat << EOF > "$ENV_FILE"
HOST_PORT=${custom_port}
APP_SECRET=${app_secret}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_pass}
DATABASE_URL=${database_url}
EOF

    # 5. 完全分流式生成 docker-compose.yml 文本
    echo -e "${YELLOW}正在生成规范化 Docker Compose 配置文件...${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        # 模式 1：本地容器拓扑
        cat << EOF > "$COMPOSE_FILE"
services:
  db:
    image: postgres:15-alpine
    container_name: umami-db
    environment:
      POSTGRES_DB: "${db_name}"
      POSTGRES_USER: "${db_user}"
      POSTGRES_PASSWORD: "${db_pass}"
    volumes:
      - umami-db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${db_user} -d ${db_name}"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: always

  umami:
    image: ghcr.io/umami-software/umami:latest
    container_name: umami
    ports:
      - "127.0.0.1:${custom_port}:3000"
    environment:
      DATABASE_URL: "${database_url}"
      APP_SECRET: "${app_secret}"
    depends_on:
      db:
        condition: service_healthy
    restart: always
    init: true

volumes:
  umami-db-data:
EOF
    else
        # 模式 2：纯净外部远程对接，无本地 db 节点，无 volumes 依赖声明
        cat << EOF > "$COMPOSE_FILE"
services:
  umami:
    image: ghcr.io/umami-software/umami:latest
    container_name: umami
    ports:
      - "127.0.0.1:${custom_port}:3000"
    environment:
      DATABASE_URL: "${database_url}"
      APP_SECRET: "${app_secret}"
    restart: always
    init: true
EOF
    fi

    # 6. 清理残余并重新拉起新集群
    echo -e "${YELLOW}正在通过 Docker Compose 部署应用状态...${RESET}"
    cd "$BASE_DIR"
    docker compose down -v 2>/dev/null
    docker compose up -d --force-recreate

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 服务拉起失败，请检查端口 ${custom_port} 是否被占用。${RESET}"
        return
    fi

    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             Umami 统计系统部署成功！                 ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}内部提取端口   : ${custom_port} (绑定在 127.0.0.1)${RESET}"
    echo -e "${YELLOW}本地 Nginx 反代: http://127.0.0.1:${custom_port}${RESET}"
    echo -e "${YELLOW}默认初始账号   : admin${RESET}"
    echo -e "${YELLOW}默认初始密码   : umami (登录后请前往设置及时修改)${RESET}"
    echo -e "----------------------------------------------------"
    echo -e "${CYAN}[数据库凭据回显]${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}PGSQL 运行模式 : ${GREEN}全新内置容器 (PostgreSQL 15)${RESET}"
        echo -e "${YELLOW}安全随机密码   : ${GREEN}${db_pass}${RESET}"
    else
        echo -e "${YELLOW}PGSQL 运行模式 : ${CYAN}外部远程连接${RESET}"
        echo -e "${YELLOW}远程目标主机   : ${db_host_ip}:${db_port}${RESET}"
        echo -e "${YELLOW}连接指定库名   : ${db_name}${RESET}"
    fi
    echo -e "----------------------------------------------------"
    echo -e "${YELLOW}持久化工作目录 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_umami() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 Umami 镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}升级完成！${RESET}"
}

# 卸载 Umami
uninstall_umami() {
    echo -ne "${RED}确定要完全卸载并删除 Umami 服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            rm -rf "$BASE_DIR"
        else
            docker rm -f umami umami-db 2>/dev/null
        fi
        echo -e "${GREEN}完全卸载成功，数据已彻底清理。${RESET}"
    fi
}

start_umami() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已拉起运行${RESET}"; }
stop_umami() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止运行${RESET}"; }
restart_umami() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已成功重启${RESET}"; }
logs_umami() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

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
    echo -e "${GREEN}       ◈  Umami 管理面板  ◈        ${RESET}"
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
        1) install_umami ;;
        2) update_umami ;;
        3) uninstall_umami ;;
        4) start_umami ;;
        5) stop_umami ;;
        6) restart_umami ;;
        7) logs_umami ;;
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
