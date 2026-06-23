#!/bin/bash
# =================================================================
# CliRelay Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="cli-proxy-api"
BASE_DIR="/opt/clirelay"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
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
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8317/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8317"
        data_dir="$BASE_DIR"
    else
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

# 部署 CliRelay
install_clirelay() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}1. 请输入 CliRelay API 访问端口 (宿主机端口) [默认: 8317]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8317"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 默认开启管理面板认证
    default_secret_key=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
    echo -ne "${YELLOW}2. 是否启用控制面板远程管理密钥？(y/n) [默认: y]: ${RESET}"
    read -r enable_auth
    [[ -z "$enable_auth" ]] && enable_auth="y"
    
    allow_remote="false"
    secret_key_val=""
    if [[ "$enable_auth" == "y" || "$enable_auth" == "Y" ]]; then
        allow_remote="true"
        echo -ne "${YELLOW}   请输入您的控制面板管理密钥 [默认随机生成: ${default_secret_key}]: ${RESET}"
        read -r input_key
        secret_key_val=${input_key:-$default_secret_key}
    fi

    # 1. 创建所需的宿主机持久化子目录
    mkdir -p "$BASE_DIR/auths" "$BASE_DIR/logs" "$BASE_DIR/data"
    chmod -R 777 "$BASE_DIR"

    # 2. 动态生成 .env 配置文件
    echo -e "${YELLOW}正在生成 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
CLI_PROXY_IMAGE=ghcr.io/kittors/clirelay:latest
CLI_PROXY_PULL_POLICY=always
VERSION=dev
COMMIT=none
BUILD_DATE=unknown
UI_VERSION=dev
FRONTEND_REPOSITORY=https://github.com/kittors/codeProxy.git
FRONTEND_REF=main
FRONTEND_COMMIT=
DEPLOY=
CLIRELAY_LOCALE=zh
CLIRELAY_UPDATE_CHANNEL=main
CLIRELAY_UPDATER_URL=http://clirelay-updater:8320
CLIRELAY_UPDATER_TOKEN=
CLIRELAY_TARGET_SERVICE=cli-proxy-api
AUTH_PATH=/root/.cli-proxy-api
CLIRELAY_LANG=C.UTF-8
CLIRELAY_LANGUAGE=en_US:en
CLIRELAY_PROJECT_DIR=${BASE_DIR}
CLIRELAY_ENV_FILE=${ENV_FILE}
CLIRELAY_COMPOSE_FILE=${COMPOSE_FILE}
CLI_PROXY_CONFIG_PATH=${CONFIG_FILE}
CLI_PROXY_AUTH_PATH=${BASE_DIR}/auths
CLI_PROXY_LOG_PATH=${BASE_DIR}/logs
CLI_PROXY_DATA_PATH=${BASE_DIR}/data
EOF

    # 3. 动态生成完整的 config.yaml
    echo -e "${YELLOW}正在生成 config.yaml 配置文件...${RESET}"
    cat <<EOF > "$CONFIG_FILE"
host: ""
oauth-clients:
  gemini:
    client-id: ""
    client-secret: ""
  antigravity:
    client-id: ""
    client-secret: ""
port: 8317
main-api-read-timeout-seconds: 120
request-body:
  model-max-mb: 128
  disk-threshold-mb: 8
  cache-dir: ""
timezone: "Asia/Shanghai"
redis:
  enable: false
  addr: "127.0.0.1:6379"
  password: ""
  db: 0
tls:
  enable: false
  cert: ""
  key: ""
cors-allow-origins: []
trusted-proxies: []
remote-management:
  allow-remote: ${allow_remote}
  secret-key: "${secret_key_val}"
  disable-control-panel: false
  panel-github-repository: "https://github.com/kittors/codeProxy"
auto-update:
  enabled: true
  channel: main
  repository: https://github.com/kittors/CliRelay
  docker-image: ghcr.io/kittors/clirelay
  updater-url: http://clirelay-updater:8320
auth-dir: "/root/.cli-proxy-api"
api-keys:
  - "your-api-key-1"
  - "your-api-key-2"
  - "your-api-key-3"
allow-unauthenticated: false
debug: false
pprof:
  enable: false
  addr: "127.0.0.1:8316"
  allow-remote: false
commercial-mode: false
logging-to-file: false
logs-max-total-size-mb: 0
error-logs-max-files: 10
usage-statistics-enabled: false
request-log-storage:
  store-content: true
  content-retention-days: 30
  cleanup-interval-minutes: 1440
  max-total-size-mb: 1024
  vacuum-on-cleanup: true
proxy-url: ""
insecure-skip-verify: false
ca-cert: ""
force-model-prefix: false
passthrough-headers: false
request-retry: 3
max-retry-interval: 30
quota-exceeded:
  switch-project: true
  switch-preview-model: true
routing:
  strategy: "round-robin"
  include-default-group: true
ws-auth: false
nonstream-keepalive-interval: 0
streaming:
  keepalive-seconds: 15
  bootstrap-retries: 1
EOF

    # 4. 动态生成 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  cli-proxy-api:
    image: \${CLI_PROXY_IMAGE:-ghcr.io/kittors/clirelay:latest}
    pull_policy: \${CLI_PROXY_PULL_POLICY:-always}
    container_name: ${CONTAINER_NAME}
    environment:
      DEPLOY: \${DEPLOY:-}
      CLIRELAY_LOCALE: \${CLIRELAY_LOCALE:-zh}
      CLIRELAY_UPDATE_CHANNEL: \${CLIRELAY_UPDATE_CHANNEL:-main}
      CLIRELAY_UPDATER_URL: \${CLIRELAY_UPDATER_URL:-http://clirelay-updater:8320}
      CLIRELAY_UPDATER_TOKEN: \${CLIRELAY_UPDATER_TOKEN:-}
      CLIRELAY_TARGET_SERVICE: \${CLIRELAY_TARGET_SERVICE:-cli-proxy-api}
      AUTH_PATH: \${AUTH_PATH:-/root/.cli-proxy-api}
      LANG: \${CLIRELAY_LANG:-C.UTF-8}
      LANGUAGE: \${CLIRELAY_LANGUAGE:-en_US:en}
      LC_ALL: \${CLIRELAY_LANG:-C.UTF-8}
    ports:
      - "${custom_port}:8317"
      - "127.0.0.1:8085:8085"
      - "127.0.0.1:1455:1455"
      - "127.0.0.1:54545:54545"
      - "127.0.0.1:51121:51121"
      - "127.0.0.1:11451:11451"
    volumes:
      - \${CLI_PROXY_CONFIG_PATH}:/CLIProxyAPI/config.yaml
      - \${CLI_PROXY_AUTH_PATH}:\${AUTH_PATH:-/root/.cli-proxy-api}
      - \${CLI_PROXY_LOG_PATH}:/CLIProxyAPI/logs
      - \${CLI_PROXY_DATA_PATH}:/CLIProxyAPI/data
    restart: unless-stopped

  clirelay-updater:
    image: \${CLI_PROXY_IMAGE:-ghcr.io/kittors/clirelay:latest}
    pull_policy: \${CLI_PROXY_PULL_POLICY:-always}
    command: ["./clirelay-updater"]
    environment:
      CLIRELAY_UPDATER_TOKEN: \${CLIRELAY_UPDATER_TOKEN:-}
      CLIRELAY_PROJECT_DIR: \${CLIRELAY_PROJECT_DIR}
      CLIRELAY_COMPOSE_FILE: \${CLIRELAY_COMPOSE_FILE}
      CLIRELAY_ENV_FILE: \${CLIRELAY_ENV_FILE}
      CLIRELAY_COMPOSE_PROJECT_NAME: \${CLIRELAY_COMPOSE_PROJECT_NAME:-}
      CLIRELAY_TARGET_SERVICE: \${CLIRELAY_TARGET_SERVICE:-cli-proxy-api}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - \${CLIRELAY_PROJECT_DIR}:\${CLIRELAY_PROJECT_DIR}
      - \${CLI_PROXY_CONFIG_PATH}:/CLIProxyAPI/config.yaml
    restart: unless-stopped
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 CliRelay 服务群...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器群初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    CliRelay 部署成功！          ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务主 API 访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}控制面板管理地址    : http://${DETECT_IP}:${custom_port}/manage${RESET}"
    if [[ "$allow_remote" == "true" ]]; then
        echo -e "${YELLOW}控制面板管理密钥    : ${secret_key_val}${RESET}"
    fi
    echo -e "${YELLOW}宿主机主工作目录    : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 CliRelay
update_clirelay() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 CliRelay 最新服务镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！多服务架构已处于最新状态。${RESET}"
}

# 卸载 CliRelay
uninstall_clirelay() {
    echo -ne "${YELLOW}确定要卸载并删除 CliRelay 核心与 Updater 边车吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器集群已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有本地配置文件、映射凭证与统计日志？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}CliRelay 整个主工作工作空间已彻底移除。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" clirelay-updater 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_clirelay() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}核心及边车服务已启动${RESET}"; }
stop_clirelay() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}核心及边车服务已停止${RESET}"; }
restart_clirelay() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}核心及边车服务已重启${RESET}"; }
logs_clirelay() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前主控状态    : $status"
    echo -e "${YELLOW}主镜像标签      : ${img_version}${RESET}"
    echo -e "${YELLOW}外网主控端口    : http://${DETECT_IP}:${webui_port}/manage${RESET}"
    echo -e "${YELLOW}控制面板管理密钥: ${secret_key_val}${RESET}"
    echo -e "${YELLOW}宿主机路径      : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  CliRelay 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新架构${RESET}"
    echo -e "${GREEN}3. 卸载服务${RESET}"
    echo -e "${GREEN}4. 启动集群${RESET}"
    echo -e "${GREEN}5. 停止集群${RESET}"
    echo -e "${GREEN}6. 重启集群${RESET}"
    echo -e "${GREEN}7. 主控日志${RESET}"
    echo -e "${GREEN}8. 运行配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_clirelay ;;
        2) update_clirelay ;;
        3) uninstall_clirelay ;;
        4) start_clirelay ;;
        5) stop_clirelay ;;
        6) restart_clirelay ;;
        7) logs_clirelay ;;
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
