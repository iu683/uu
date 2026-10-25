#!/bin/bash
# =================================================================
# Picloom 图床系统 Docker Compose 管理面板
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/picloom"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
CONFIG_FILE="$BASE_DIR/picloom.env"
DEFAULT_IMAGE="llleixx/picloom:latest"

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
        if [ "$(docker ps -q -f name=picloom)" ]; then
            status="${GREEN}运行中${RESET}"
            web_port=$(docker ps -f name=picloom --format "{{.Ports}}" | sed -E 's/.*:([0-9]+)->.*/\1/' | head -n 1)
            if ! [[ "$web_port" =~ ^[0-9]+$ ]]; then
                web_port=$(sed -n '/picloom:/,/^[[:space:]]*[a-zA-Z]/p' "$COMPOSE_FILE" | grep -E '\-[[:space:]]*["'\'']?[0-9]+:' | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"''-')
            fi
        elif [ "$(docker ps -aq -f name=picloom)" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' picloom 2>/dev/null)
        else
            status="${RED}未部署${RESET}"
        fi
        [[ -z "$web_port" ]] && web_port="7425"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署 Picloom
install_lsky() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    # 1. 基础参数配置
    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Picloom 宿主机映射访问端口 [默认: 7425]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="7425"

    echo -e "${YELLOW}正在自动生成高强度加密密钥 (ENCRYPTION_KEY)...${RESET}"
    encryption_key=$(openssl rand -hex 32)

    echo -ne "${YELLOW}请输入初始化管理员密码 (留空则由程序随机生成并记录在日志中): ${RESET}"
    read -r owner_password

    # 2. 数据库运行模式选择
    echo -e "\n${CYAN}====== 数据库运行模式选择 ======${RESET}"
    echo -e " 1) 使用内置 SQLite 数据库 (默认，只需挂载本地数据卷)"
    echo -e " 2) 使用本地 PostgreSQL 容器 (包含独立的 PostgreSQL 容器)"
    echo -e " 3) 使用外部/远程 PostgreSQL 数据库 (分步输入连接参数)"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    local database_url=""
    local pg_pass=""

    if [[ "$db_mode" == "2" ]]; then
        echo -e "${YELLOW}使用本地 PostgreSQL 容器，正在生成数据库密码...${RESET}"
        pg_pass=$(openssl rand -hex 16)
        database_url="postgresql://picloom:${pg_pass}@postgres:5432/picloom"
    elif [[ "$db_mode" == "3" ]]; then
        echo -ne "${YELLOW}请输入远程 PostgreSQL 的 IP 或域名: ${RESET}"
        read -r ext_db_ip
        echo -ne "${YELLOW}请输入远程 PostgreSQL 端口 [默认: 5432]: ${RESET}"
        read -r ext_db_port
        [[ -z "$ext_db_port" ]] && ext_db_port="5432"
        
        echo -ne "${YELLOW}请输入远程 PostgreSQL 用户名 [默认: picloom]: ${RESET}"
        read -r ext_db_user
        [[ -z "$ext_db_user" ]] && ext_db_user="picloom"
        
        echo -ne "${YELLOW}请输入远程 PostgreSQL 密码: ${RESET}"
        read -r ext_db_pass
        
        echo -ne "${YELLOW}请输入远程已存在的数据库名 [默认: picloom]: ${RESET}"
        read -r ext_db_name
        [[ -z "$ext_db_name" ]] && ext_db_name="picloom"
        
        # 兼容本地宿主机回环网关
        if [[ "$ext_db_ip" == "127.0.0.1" || "$ext_db_ip" == "localhost" ]]; then
            ext_db_ip="172.17.0.1"
        fi

        # 组装标准的 PostgreSQL URL
        database_url="postgresql://${ext_db_user}:${ext_db_pass}@${ext_db_ip}:${ext_db_port}/${ext_db_name}"
    else
        database_url=""
    fi

    # 3. 备份保留配置文件 picloom.env
    cat << EOF > "$CONFIG_FILE"
PORT="${custom_port}"
ENCRYPTION_KEY="${encryption_key}"
INITIAL_OWNER_PASSWORD="${owner_password}"
DATABASE_URL="${database_url}"
POSTGRES_PASSWORD="${pg_pass}"
EOF

    # 4. 创建持久化数据目录
    mkdir -p "$BASE_DIR/data"
    if [[ "$db_mode" == "2" ]]; then
        mkdir -p "$BASE_DIR/postgres"
    fi

    # 5. 生成规范化 Docker Compose 配置文件 (不绑定 127.0.0.1)
    echo -e "${YELLOW}正在生成规范化 Docker Compose 配置文件...${RESET}"
    if [[ "$db_mode" == "2" ]]; then
        # 模式 2：本地 PostgreSQL 容器
        cat << EOF > "$COMPOSE_FILE"
services:
  picloom:
    image: ${DEFAULT_IMAGE}
    container_name: picloom
    init: true
    restart: unless-stopped
    stop_grace_period: 60s
    ports:
      - "${custom_port}:7425"
    environment:
      - ENCRYPTION_KEY=${encryption_key}
      - INITIAL_OWNER_PASSWORD=${owner_password}
      - PUBLIC_ORIGIN=
      - TRUSTED_PROXIES=
      - DATABASE_URL=${database_url}
    volumes:
      - ./data:/var/lib/picloom
    depends_on:
      postgres:
        condition: service_healthy

  postgres:
    image: postgres:16-bookworm
    container_name: picloom-postgres
    restart: unless-stopped
    stop_grace_period: 60s
    environment:
      POSTGRES_USER: picloom
      POSTGRES_DB: picloom
      POSTGRES_PASSWORD: ${pg_pass}
    volumes:
      - ./postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U picloom -d picloom"]
      interval: 5s
      timeout: 5s
      retries: 12
EOF
    else
        # 模式 1（SQLite）或 模式 3（远程 PostgreSQL）
        cat << EOF > "$COMPOSE_FILE"
services:
  picloom:
    image: ${DEFAULT_IMAGE}
    container_name: picloom
    init: true
    restart: unless-stopped
    stop_grace_period: 60s
    ports:
      - "${custom_port}:7425"
    environment:
      - ENCRYPTION_KEY=${encryption_key}
      - INITIAL_OWNER_PASSWORD=${owner_password}
      - PUBLIC_ORIGIN=
      - TRUSTED_PROXIES=
      - DATABASE_URL=${database_url}
    volumes:
      - ./data:/var/lib/picloom
EOF
    fi

    # 6. 清理残余并拉起容器集群
    echo -e "${YELLOW}正在通过 Docker Compose 部署 Picloom 环境...${RESET}"
    cd "$BASE_DIR"
    docker compose down -v 2>/dev/null
    docker compose up -d --force-recreate

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 服务拉起失败，请检查端口 ${custom_port} 是否被占用。${RESET}"
        return
    fi

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}          Picloom 图床系统部署成功！              ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}服务监听端口   : ${custom_port} (公开访问)*${RESET}"
    echo -e "${YELLOW}本地访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}账户          : admin${RESET}"
    echo -e "${YELLOW}密码          : ${owner_password}${RESET}"
    echo -e "----------------------------------------------------"
    echo -e "${CYAN}[运行凭据回显]${RESET}"
    echo -e "${YELLOW}加密密钥 (KEY) : ${GREEN}${encryption_key}${RESET}"
    if [[ "$db_mode" == "2" ]]; then
        echo -e "${YELLOW}数据库运行模式 : ${GREEN}本地 PostgreSQL 16 容器${RESET}"
        echo -e "${YELLOW}PostgreSQL 密码: ${GREEN}${pg_pass}${RESET}"
    elif [[ "$db_mode" == "3" ]]; then
        echo -e "${YELLOW}数据库运行模式 : ${GREEN}外部远程 PostgreSQL 数据库${RESET}"
        echo -e "${YELLOW}远程连接主机   : ${GREEN}${ext_db_ip}:${ext_db_port}${RESET}"
        echo -e "${YELLOW}连接指定库名   : ${GREEN}${ext_db_name}${RESET}"
    else
        echo -e "${YELLOW}数据库运行模式 : ${GREEN}内置 SQLite (路径: data/database.sqlite)${RESET}"
    fi
    echo -e "----------------------------------------------------"
    echo -e "${YELLOW}持久化工作目录 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新图床
update_lsky() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 Picloom 镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}升级完成！${RESET}"
}

# 卸载图床
uninstall_lsky() {
    echo -ne "${RED}确定要完全卸载并删除 Picloom 服务及所有数据吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            rm -rf "$BASE_DIR"
        else
            docker rm -f picloom picloom-postgres 2>/dev/null
        fi
        echo -e "${GREEN}完全卸载成功，数据已彻底清理。${RESET}"
    fi
}

start_lsky() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已拉起运行${RESET}"; }
stop_lsky() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止运行${RESET}"; }
restart_lsky() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已成功重启${RESET}"; }
logs_lsky() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态   : $status"
    echo -e "${YELLOW}外部映射端口   : ${web_port}${RESET}"
    echo -e "${YELLOW}安装绝对路径   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 主菜单管理
menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}      ◈  Picloom  管理面板  ◈      ${RESET}"
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
        1) install_lsky ;;
        2) update_lsky ;;
        3) uninstall_lsky ;;
        4) start_lsky ;;
        5) stop_lsky ;;
        6) restart_lsky ;;
        7) logs_lsky ;;
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
