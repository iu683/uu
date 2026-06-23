#!/bin/bash
# =================================================================
# DEEIX Chat AI 聊天服务 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="deeix-chat-app"
BASE_DIR="/opt/deeix-chat"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
CONFIG_FILE="$BASE_DIR/config.yaml"

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

        # 从容器状态提取内部暴露端口绑定的宿主机端口（容器内部监听的是 8080 端口）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        # 兜底获取第一个绑定的端口
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8080"

        # 从容器状态提取挂载路径（抓取首个或默认展示持久化提示）
        data_dir="Docker 命名卷 (deeix-chat-app-data)"
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

# 生成强随机密钥
generate_strong_secret() {
    if command -v openssl &> /dev/null; then
        openssl rand -hex 16
    else
        echo "secret-fallback-$(date +%s%N)"
    fi
}

# 部署 DEEIX Chat
install_deeix_chat() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 DEEIX Chat 访问端口 (宿主机端口) [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 1. 自动生成生产级别的安全密钥
    JWT_SECRET_RAND=$(generate_strong_secret)
    ENC_KEY_RAND=$(generate_strong_secret)

    # 2. 动态自动写入完整的 config.yaml 配置内容
    echo -e "${YELLOW}正在初始化生产安全级别的应用配置文件 (config.yaml)...${RESET}"
    cat <<EOF > "$CONFIG_FILE"
app:
  name: "DEEIX Chat"
  env: prod

server:
  http_port: "8080"
  cors_allow_origin: "http://localhost:${custom_port},http://127.0.0.1:${custom_port}"
  trusted_proxies: "127.0.0.1/32,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,::1/128,fc00::/7"
  public_api_base_url: "http://localhost:${custom_port}"
  public_web_base_url: "http://localhost:${custom_port}"
  frontend_dist_dir: "/app/frontend/out"
  read_header_timeout_seconds: 10
  read_timeout_seconds: 120
  idle_timeout_seconds: 120
  max_header_bytes: 1048576

security:
  jwt_secret: "${JWT_SECRET_RAND}"
  data_encryption_key: "${ENC_KEY_RAND}"
  ssrf_protection_enabled: true
  turnstile_siteverify_url: "https://challenges.cloudflare.com/turnstile/v0/siteverify"

database:
  driver: sqlite
  sqlite:
    path: /app/data/deeix.db
    dsn: ""
    max_open_conns: 1
    busy_timeout_ms: 5000
    cache_size_kb: 20480
    mmap_size_bytes: 268435456
    synchronous: NORMAL
    temp_store: MEMORY

cache:
  driver: memory

storage:
  backend: local
  local:
    root_dir: /app/storage
  s3:
    endpoint: ""
    region: auto
    bucket: ""
    prefix: ""
    access_key_id: ""
    secret_access_key: ""
    force_path_style: true

geoip:
  provider: ipwhois
  timeout_ms: 2500

observability:
  tracing:
    endpoint: ""
    headers: ""
    insecure: false
    sampling_rate: 1
EOF
    
    chmod -R 777 "$BASE_DIR"

    # 3. 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成带有隔离网络的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
name: deeix-chat

services:
  app:
    image: \${DEEIX_CHAT_IMAGE:-ghcr.io/deeix-ai/deeix-chat:latest}
    container_name: ${CONTAINER_NAME}
    ports:
      - "${custom_port}:8080"
    volumes:
      - app_storage:/app/storage
      - app_data:/app/data
      - ./config.yaml:/app/config.yaml:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - deeix-chat
    restart: unless-stopped

volumes:
  app_storage:
    name: deeix-chat-app-storage
  app_data:
    name: deeix-chat-app-data

networks:
  deeix-chat:
    name: deeix-chat-network
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 DEEIX Chat 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    DEEIX Chat 部署成功！       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务本地/反代地址 : http://localhost:${custom_port}${RESET}"
    echo -e "${YELLOW}服务外网访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}宿主机配置路径   : $CONFIG_FILE${RESET}"
    echo -e "${CYAN}提示: 安全选项已自动切换为 prod 模式，两组随机安全密钥已注入配置文件中。${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 DEEIX Chat 镜像
update_deeix_chat() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 DEEIX Chat 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 DEEIX Chat
uninstall_deeix_chat() {
    echo -ne "${YELLOW}确定要卸载并删除 DEEIX Chat 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件与 Docker 数据卷（这会清空聊天数据库）？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                # 显式删除独立的命名卷
                docker volume rm deeix-chat-app-storage deeix-chat-app-data 2>/dev/null
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}所有配置目录与 Docker 持久化数据卷已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_deeix_chat() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_deeix_chat() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_deeix_chat() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_deeix_chat() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}内部容器名称   : ${CONTAINER_NAME}${RESET}"
    echo -e "${YELLOW}服务映射端口   : ${webui_port}${RESET}"
    echo -e "${YELLOW}持久化层机制   : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  DEEIX Chat 管理面板  ◈    ${RESET}"
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
        1) install_deeix_chat ;;
        2) update_deeix_chat ;;
        3) uninstall_deeix_chat ;;
        4) start_deeix_chat ;;
        5) stop_deeix_chat ;;
        6) restart_deeix_chat ;;
        7) logs_deeix_chat ;;
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
