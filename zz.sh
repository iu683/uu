#!/bin/bash
# =================================================================
# CLI Proxy API 服务 Docker Compose 管理面板 (增强版)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="cli-proxy-api"
BASE_DIR="/opt/cliproxy"
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
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8317/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8317"

        api_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8085/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$api_port" ]] && api_port="8085"
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        api_port="N/A"
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

# 部署 CLI Proxy API
install_cliproxy() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 端口配置
    echo -ne "${YELLOW}请输入 Web 管理面板端口 [默认: 8317]: ${RESET}"
    read -r custom_web_port
    [[ -z "$custom_web_port" ]] && custom_web_port="8317"

    echo -ne "${YELLOW}请输入 API 服务端口 [默认: 8085]: ${RESET}"
    read -r custom_api_port
    [[ -z "$custom_api_port" ]] && custom_api_port="8085"

    # 2. Web 面板管理密码配置
    # 随机生成一个 16 位面板密码作为默认值
    default_secret=$(date +%s%N | md5sum | head -c 16)
    echo -ne "${YELLOW}请设置远程 Web 面板登录密码 [默认随机: $default_secret]: ${RESET}"
    read -r secret_key
    [[ -z "$secret_key" ]] && secret_key="$default_secret"

    # 3. 客户端 API Key 配置 (解决 templates 报错)
    # 随机生成一个 24 位 API Key 作为默认值
    default_apikey="sk-proxy-$(date +%s%N | sha256sum | head -c 15)"
    echo -e "${CYAN}------------------------------------------------------------${RESET}"
    echo -e "${YELLOW}提示：接下来需要设置客户端请求该代理时所使用的 API Key。${RESET}"
    echo -ne "${YELLOW}请输入自定义 API Key [默认随机: $default_apikey]: ${RESET}"
    read -r client_apikey
    [[ -z "$client_apikey" ]] && client_apikey="$default_apikey"
    echo -e "${CYAN}------------------------------------------------------------${RESET}"

    # 创建所需的宿主机目录
    mkdir -p "$BASE_DIR/auths" "$BASE_DIR/logs"
    chmod -R 777 "$BASE_DIR"

    # 4. 动态生成 config.yaml 配置文件
    echo -e "${YELLOW}正在生成符合安全合规的 config.yaml 配置文件...${RESET}"
    cat <<EOF > "$CONFIG_FILE"
host: ""
port: 8317
tls:
  enable: false
  cert: ""
  key: ""
remote-management:
  allow-remote: true
  secret-key: "${secret_key}"
  disable-control-panel: false
  panel-github-repository: "https://github.com/router-for-me/Cli-Proxy-API-Management-Center"
auth-dir: "~/.cli-proxy-api"
api-keys:
  - "${client_apikey}"
debug: false
pprof:
  enable: false
  addr: "127.0.0.1:8316"
plugins:
  enabled: false
  dir: "plugins"
commercial-mode: false
logging-to-file: false
logs-max-total-size-mb: 0
error-logs-max-files: 10
usage-statistics-enabled: false
redis-usage-queue-retention-seconds: 60
proxy-url: ""
force-model-prefix: false
passthrough-headers: false
request-retry: 3
max-retry-credentials: 0
max-retry-interval: 30
disable-cooling: false
save-cooldown-status: false
transient-error-cooldown-seconds: 0
disable-claude-cloak-mode: false
disable-image-generation: false
video-result-auth-cache-ttl: "3h"
quota-exceeded:
  switch-project: true
  switch-preview-model: true
  antigravity-credits: true
routing:
  strategy: "round-robin"
  session-affinity: false
  session-affinity-ttl: "1h"
codex:
  identity-confuse: false
ws-auth: true
nonstream-keepalive-interval: 0
EOF

    # 5. 动态生成 docker-compose.yml
    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  cli-proxy-api:
    image: eceasy/cli-proxy-api:latest
    pull_policy: always
    container_name: ${CONTAINER_NAME}
    ports:
      - "${custom_web_port}:8317"
      - "${custom_api_port}:8085"
      - "1455:1455"
      - "54545:54545"
      - "51121:51121"
      - "11451:11451"
    volumes:
      - ./config.yaml:/CLIProxyAPI/config.yaml
      - ./auths:/root/.cli-proxy-api
      - ./logs:/CLIProxyAPI/logs
    environment:
      - TZ=Asia/Shanghai
    restart: unless-stopped
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${GREEN}                 CLI Proxy API 部署成功！                       ${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${YELLOW}Web 管理面板地址 : http://${DETECT_IP}:${custom_web_port}/management.html${RESET}"
    echo -e "${YELLOW}面板登录管理密码 : ${secret_key}${RESET}"
    echo -e "${CYAN}----------------------------------------------------------------${RESET}"
    echo -e "${YELLOW}客户端调用 APIKEY: ${client_apikey}${RESET}"
    echo -e "${YELLOW}API 服务访问地址 : http://${DETECT_IP}:${custom_api_port}${RESET}"
    echo -e "${YELLOW}宿主机安装根路径 : $BASE_DIR${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
}

# 更新镜像
update_cliproxy() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载服务
uninstall_cliproxy() {
    echo -ne "${YELLOW}确定要卸载并删除 CLI Proxy API 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件、日志和认证数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}数据根目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_cliproxy() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_cliproxy() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_cliproxy() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_cliproxy() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${YELLOW}当前状态     : $status"
    echo -e "${YELLOW}镜像名称     : ${img_version}"
    if [ "$webui_port" != "N/A" ]; then
        echo -e "${YELLOW}管理面板地址 : http://${DETECT_IP}:${webui_port}/management.html"
        echo -e "${YELLOW}API 服务地址 : http://${DETECT_IP}:${api_port}"
    fi
    echo -e "${YELLOW}配置文件路径 : ${CONFIG_FILE}${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈  CLI Proxy API 管理面板 ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}面板 :${RESET} ${YELLOW}${webui_port}${RESET} "
    echo -e "${GREEN}API  :${RESET} ${YELLOW}${api_port}${RESET}"
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
        1) install_cliproxy ;;
        2) update_cliproxy ;;
        3) uninstall_cliproxy ;;
        4) start_cliproxy ;;
        5) stop_cliproxy ;;
        6) restart_cliproxy ;;
        7) logs_cliproxy ;;
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
