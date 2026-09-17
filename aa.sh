#!/bin/bash
# =================================================================
# oci-pool 综合服务 Docker Compose 管理面板
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="oci-pool-modern"
BASE_DIR="/opt/oci-pool"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! docker compose version &> /dev/null && ! command -v docker-compose &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker Compose，请先安装！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态与映射端口
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        port_display="N/A"
        return 0
    fi
    
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${GREEN}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 从运行中的 app 容器提取前端反代端口 (OCI_WEB_PORT 默认 9857)
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "oci-pool-web" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="9857"
        port_display="${webui_port}"
    else
        img_version="${RED}未安装${RESET}"
        # 如果未运行但有 .env，尝试从 .env 读取
        if [ -f "$ENV_FILE" ]; then
            port_display=$(grep "^OCI_WEB_PORT=" "$ENV_FILE" | cut -d'=' -f2)
            [[ -z "$port_display" ]] && port_display="9857"
        else
            port_display="9857"
        fi
    fi
}

# 获取公网 IP (兼容双栈环境)
get_public_ip() {
    local mode=${1:-"auto"}
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

# 生成高强度随机密码 (用于 H2 数据库加密)
generate_password() {
    tr -dc 'A-Za-z0-9!@#%^&*' < /dev/urandom | head -c 24
}

# 部署 oci-pool
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 部署配置引导 ======${RESET}"
    
    # 端口配置
    echo -ne "${YELLOW}请输入 OCI Pool 后端服务监听端口 [默认: 9856]: ${RESET}"
    read -r OCI_PORT
    [[ -z "$OCI_PORT" ]] && OCI_PORT="9856"

    echo -ne "${YELLOW}请输入 OCI Pool Web(Nginx) 对外访问端口 [默认: 9857]: ${RESET}"
    read -r OCI_WEB_PORT
    [[ -z "$OCI_WEB_PORT" ]] && OCI_WEB_PORT="9857"

    # 时区配置
    echo -ne "${YELLOW}请输入容器时区 [默认: Asia/Shanghai]: ${RESET}"
    read -r TZ
    [[ -z "$TZ" ]] && TZ="Asia/Shanghai"

    # H2 数据库密码生成
    DEFAULT_DB_PASS=$(generate_password)
    echo -ne "${YELLOW}请输入 H2 数据库加密密码 [回车自动生成 24 位强密码]: ${RESET}"
    read -r DB_PASSWORD
    [[ -z "$DB_PASSWORD" ]] && DB_PASSWORD="$DEFAULT_DB_PASS"

    # 管理员初始密码
    DEFAULT_ADMIN_PASS=$(generate_password)
    echo -ne "${YELLOW}请输入初始管理员密码 [回车自动生成安全密码]: ${RESET}"
    read -r ADMIN_PASSWORD
    [[ -z "$ADMIN_PASSWORD" ]] && ADMIN_PASSWORD="$DEFAULT_ADMIN_PASS"

    echo -e "${YELLOW}正在写入 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
# 部署端口（默认仅绑本地 127.0.0.1 回环，对外由 Nginx 统一反代）
OCI_PORT=$OCI_PORT
OCI_PORT_BIND=127.0.0.1

# 统一入口反代（web/nginx）端口，浏览器公网访问入口
OCI_WEB_PORT=$OCI_WEB_PORT

# 容器时区
TZ=$TZ

# 是否启用 Modern UI
MODERN_UI_ENABLED=true

# H2 数据库安全密码
DB_PASSWORD=$DB_PASSWORD

# 初始管理员凭据
ADMIN_USERNAME=admin
ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF

    echo -e "${YELLOW}正在写入 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  redis:
    image: redis:7-alpine
    container_name: oci-pool-redis
    restart: unless-stopped
    volumes: [./redis-data:/data]
    healthcheck: { test: ["CMD", "redis-cli", "ping"], interval: 10s, timeout: 3s, retries: 5 }

  app:
    image: docker.io/zszken/oci-pool:latest
    pull_policy: always
    container_name: oci-pool-modern
    restart: unless-stopped
    depends_on: { redis: { condition: service_healthy } }
    ports: ["\${OCI_PORT_BIND:-127.0.0.1}:\${OCI_PORT:-9856}:9856"]
    environment:
      TZ: "\${TZ:-Asia/Shanghai}"
      SPRING_REDIS_HOST: redis
      SPRING_REDIS_PORT: "6379"
      MODERN_UI_ENABLED: "\${MODERN_UI_ENABLED:-true}"
      DB_PASSWORD: "\${DB_PASSWORD:-}"
      ADMIN_USERNAME: "\${ADMIN_USERNAME:-admin}"
      ADMIN_PASSWORD: "\${ADMIN_PASSWORD:-}"
    volumes:
      - ./data:/oci-pool/data
      - ./logs:/oci-pool/logs
    healthcheck: { test: ["CMD", "curl", "-sf", "http://127.0.0.1:9856/actuator/health"], interval: 30s, timeout: 5s, retries: 5, start_period: 60s }

  web:
    image: docker.io/zszken/oci-pool-web:latest
    pull_policy: always
    container_name: oci-pool-web
    restart: unless-stopped
    depends_on: { app: { condition: service_healthy } }
    environment:
      TZ: "\${TZ:-Asia/Shanghai}"
    ports: ["\${OCI_WEB_PORT:-9857}:80"]
    healthcheck: { test: ["CMD", "wget", "-q", "-O", "-", "http://127.0.0.1/"], interval: 30s, timeout: 5s, retries: 5, start_period: 10s }
EOF

    # 创建本地挂载目录
    mkdir -p "$BASE_DIR/data" "$BASE_DIR/logs" "$BASE_DIR/redis-data"

    echo -e "${YELLOW}正在通过 Docker Compose 拉取并启动 oci-pool 服务栈...${RESET}"
    cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" up -d --force-recreate

    echo -e "${YELLOW}等待容器群初始化 (约 5 秒)...${RESET}"
    sleep 5

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             oci-pool 部署成功！                    ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}公网访问地址       : http://${DETECT_IP}:${OCI_WEB_PORT}${RESET}"
    echo -e "${YELLOW}初始管理员账号     : admin${RESET}"
    echo -e "${YELLOW}初始管理员密码     : ${ADMIN_PASSWORD}${RESET}"
    echo -e "${YELLOW}H2 数据库密码      : ${DB_PASSWORD}${RESET}"
    echo -e "${YELLOW}数据存储路径       : ${BASE_DIR}/data${RESET}"
    echo -e "${YELLOW}配置文件路径       : ${COMPOSE_FILE}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新 oci-pool 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" pull
    docker compose --env-file "$ENV_FILE" up -d --remove-orphans
    echo -e "${GREEN}更新完成！所有容器已处于最新状态。${RESET}"
}

# 卸载 oci-pool
uninstall_utils() {
    echo -e "${RED}警告: 卸载如果清理数据，将永久丢失您的本地数据库和配置！${RESET}"
    echo -ne "${YELLOW}确定要卸载并停止所有 oci-pool 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" down
            echo -e "${GREEN}容器已全部停止并移除。${RESET}"
            echo -ne "${RED}是否同时彻底删除本地全量数据目录 ($BASE_DIR)? (y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有容器、配置及数据库已被彻底销毁。${RESET}"
            fi
        else
            docker rm -f oci-pool-modern oci-pool-redis oci-pool-web 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { 
    if [[ ! -f "$COMPOSE_FILE" ]]; then echo -e "${RED}未找到配置文件${RESET}"; return; fi
    cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" start && echo -e "${GREEN}服务已全部启动${RESET}"; 
}

stop_utils() { 
    if [[ ! -f "$COMPOSE_FILE" ]]; then echo -e "${RED}未找到配置文件${RESET}"; return; fi
    cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" stop && echo -e "${YELLOW}服务已全部停止${RESET}"; 
}

restart_utils() { 
    if [[ ! -f "$COMPOSE_FILE" ]]; then echo -e "${RED}未找到配置文件${RESET}"; return; fi
    cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" restart && echo -e "${GREEN}服务已全部重启${RESET}"; 
}

logs_utils() {
    echo -e "${CYAN}请选择要查看日志的服务:${RESET}"
    echo "1. app (后端核心服务)"
    echo "2. web (前端反代服务)"
    echo "3. redis (缓存服务)"
    echo -ne "${YELLOW}输入选择 [默认 1]: ${RESET}"
    read -r log_choice
    case "$log_choice" in
        2) docker logs -f oci-pool-web ;;
        3) docker logs -f oci-pool-redis ;;
        *) docker logs -f "$CONTAINER_NAME" ;;
    esac
}

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}后端镜像       : ${img_version}${RESET}"
    echo -e "${YELLOW}访问端口       : ${port_display}${RESET}"
    echo -e "${YELLOW}访问地址       : http://${DETECT_IP}:${port_display}${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      ◈ oci-pool 管理面板 ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${port_display}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动服务${RESET}"
    echo -e "${GREEN}5. 停止服务${RESET}"
    echo -e "${GREEN}6. 重启服务${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_utils ;;
        2) update_utils ;;
        3) uninstall_utils ;;
        4) start_utils ;;
        5) stop_utils ;;
        6) restart_utils ;;
        7) logs_utils ;;
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
