#!/bin/bash
# =================================================================
# CPA Usage Keeper Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="cpa-usage-keeper"
BASE_DIR="/opt/cpa-usage-keeper"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口和数据目录
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取镜像名称/版本
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 从容器状态提取前端绑定的端口（默认监听的是 8080 端口）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        # 兜底获取第一个绑定的端口
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8080"

        # 从容器状态提取数据目录（挂载路径）
        data_dir=$(docker inspect -f '{{range .Mounts}}{{.Source}}{{break}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$data_dir" ]] && data_dir="/opt/cpa-usage-keeper/data"
    else
        # 容器未安装/未部署时的返回值
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        data_dir="N/A"
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

# 部署 Keeper
install_keeper() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}1. 请输入 Keeper 访问端口 (宿主机端口) [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}2. 请输入宿主机数据存储绝对路径 [默认: /opt/cpa-usage-keeper/data]: ${RESET}"
    read -r custom_data
    [[ -z "$custom_data" ]] && custom_data="/opt/cpa-usage-keeper/data"

    echo -ne "${YELLOW}3. 请输入核心 CPA 服务的访问地址 [默认: http://host.docker.internal:8317]: ${RESET}"
    read -r cpa_url
    [[ -z "$cpa_url" ]] && cpa_url="http://host.docker.internal:8317"

    echo -ne "${YELLOW}4. 请输入 CPA Management Key [必填]: ${RESET}"
    read -r cpa_key
    if [[ -z "$cpa_key" ]]; then
        echo -e "${RED}错误: Management Key 不能为空！${RESET}"
        return
    fi

    echo -ne "${YELLOW}5. 是否启用 Web 登录密码保护？(y/n) [默认: y]: ${RESET}"
    read -r enable_auth
    [[ -z "$enable_auth" ]] && enable_auth="y"
    
    auth_enabled="false"
    login_password="replace-with-your-login-password"
    
    if [[ "$enable_auth" == "y" || "$enable_auth" == "Y" ]]; then
        auth_enabled="true"
        # 默认生成一个 12 位的随机安全密码作为提示默认值
        default_password=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 12 | head -n 1)
        echo -ne "${YELLOW}   请输入您的登录密码 [默认随机生成: ${default_password}]: ${RESET}"
        read -r login_password
        [[ -z "$login_password" ]] && login_password="$default_password"
    fi

    # 1. 创建所需的宿主机目录
    mkdir -p "$custom_data"
    chmod -R 777 "$BASE_DIR" "$custom_data"

    # 2. 动态生成 .env 配置文件
    echo -e "${YELLOW}正在生成 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
# =============================================================================
# 1. 最小必填 / Minimum required
# =============================================================================
CPA_BASE_URL=${cpa_url}
CPA_MANAGEMENT_KEY=${cpa_key}

# =============================================================================
# 2. Web 访问与反代 / Web access and reverse proxy
# =============================================================================
APP_PORT=${custom_port}
APP_BASE_PATH=
CPA_PUBLIC_URL=

# =============================================================================
# 3. 登录保护 / Login protection
# =============================================================================
AUTH_ENABLED=${auth_enabled}
LOGIN_PASSWORD=${login_password}
AUTH_SESSION_TTL=168h

# =============================================================================
# 4. 时区与请求行为 / Timezone and request behavior
# =============================================================================
TZ=Asia/Shanghai
REQUEST_TIMEOUT=30s
TLS_SKIP_VERIFY=false

# =============================================================================
# 5. Auth Files 限额刷新 / Auth Files quota refresh
# =============================================================================
QUOTA_AUTO_REFRESH_ENABLED=false
QUOTA_AUTO_REFRESH_INTERVAL=5m
QUOTA_REFRESH_WORKER_LIMIT=10

# =============================================================================
# 6. Redis 队列高级配置 / Redis queue advanced settings
# =============================================================================
REDIS_QUEUE_ADDR=
REDIS_QUEUE_TLS=false
REDIS_QUEUE_BATCH_SIZE=10000
REDIS_QUEUE_IDLE_INTERVAL=1s

# =============================================================================
# 7. 存储、日志与备份 / Storage, logs, and backups
# =============================================================================
WORK_DIR=/data
LOG_LEVEL=info
LOG_FILE_ENABLED=true
LOG_RETENTION_DAYS=7
BACKUP_ENABLED=true
BACKUP_INTERVAL=24h
BACKUP_RETENTION_DAYS=7

# =============================================================================
# 8. 内置 HTTPS / Built-in HTTPS
# =============================================================================
# 建议在反向代理层处理 HTTPS
TLS_ENABLED=false
TLS_CERT_FILE=
TLS_KEY_FILE=
EOF

    # 3. 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  cpa-usage-keeper:
    container_name: ${CONTAINER_NAME}
    image: ghcr.io/willxup/cpa-usage-keeper:latest
    restart: unless-stopped
    ports:
      - "${custom_port}:${custom_port}"
    env_file:
      - .env
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ${custom_data}:/data
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Keeper 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    Keeper 部署成功！       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}宿主机数据路径 : $custom_data${RESET}"
    if [[ "$auth_enabled" == "true" ]]; then
        echo -e "${YELLOW}面板登录密码   : ${login_password}${RESET}"
    fi
    echo -e "${GREEN}================================${RESET}"
}

# 更新 Keeper 镜像
update_keeper() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Keeper 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 Keeper
uninstall_keeper() {
    echo -ne "${YELLOW}确定要卸载并删除 Keeper 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件和数据库数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_keeper() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_keeper() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_keeper() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_keeper() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}面板登录密码   : ${login_password}${RESET}"
    echo -e "${YELLOW}宿主机数据路径 : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Keeper 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_keeper ;;
        2) update_keeper ;;
        3) uninstall_keeper ;;
        4) start_keeper ;;
        5) stop_keeper ;;
        6) restart_keeper ;;
        7) logs_keeper ;;
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
