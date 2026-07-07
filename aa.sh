#!/bin/bash
# =================================================================
# Hubproxy Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="hubproxy"
BASE_DIR="/opt/hubproxy"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 数据与配置文件路径
CONFIG_FILE="$BASE_DIR/src/config.toml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 格式化 URL 中的 IP (如果是 IPv6 则加上方括号 [])
format_ip_for_url() {
    local ip="$1"
    if [[ "$ip" == *":"* ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

# 动态获取容器状态并联动健康检查
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        return 0
    fi
    
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        local health_status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        if [[ "$health_status" == "healthy" ]]; then
            status="${GREEN}运行中 (健康)${RESET}"
        elif [[ "$health_status" == "unhealthy" ]]; then
            status="${RED}运行中 (不健康)${RESET}"
        elif [[ "$health_status" == "starting" ]]; then
            status="${YELLOW}运行中 (启动中)${RESET}"
        else
            status="${GREEN}运行中${RESET}"
        fi
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "5000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="5000"
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
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

# 部署 Hubproxy 并初始化默认配置
install_hubproxy() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    mkdir -p "$(dirname "$CONFIG_FILE")"

    # 如果配置文件不存在，自动写入用户提供的默认模板
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}正在初始化默认的 config.toml 配置文件...${RESET}"
        cat <<'EOF' > "$CONFIG_FILE"
# 可通过 CONFIG_PATH 环境变量指定配置文件路径，默认读取当前工作目录下的 config.toml

[server]
# 监听地址
addr = "0.0.0.0:5000"
# GitHub 文件大小限制（字节），默认 1GB
fileSize = 1073741824
# HTTP/2 cleartext
enableH2C = true
# 启用前端页面
enableFrontend = true

# 限速规则，格式 "ip periodHours requestLimit"
# "*" 为全局，其他为按 IP/CIDR 覆盖，requestLimit=0 表示阻断
ipLimits = ["* 3 500"]

[access]
# 仓库白名单（支持 GitHub 仓库和 Docker 镜像，支持通配符）
whiteList = []

# 仓库黑名单（支持 GitHub 仓库和 Docker 镜像，支持通配符）
blackList = []

# 上游代理 (例如 socks5://127.0.0.1:1080)
proxy = ""

[download]
# 批量下载离线镜像数量限制
maxImages = 10

# Registry 映射配置，支持多种镜像仓库上游
[registries]

# GitHub Container Registry
[registries."ghcr.io"]
upstream = "ghcr.io"
authHost = "ghcr.io/token"
authType = "github"
enabled = true

# Google Container Registry
[registries."gcr.io"]
upstream = "gcr.io"
authHost = "gcr.io/v2/token"
authType = "google"
enabled = true

# Quay.io Container Registry
[registries."quay.io"]
upstream = "quay.io"
authHost = "quay.io/v2/auth"
authType = "quay"
enabled = true

# Kubernetes Container Registry
[registries."registry.k8s.io"]
upstream = "registry.k8s.io"
authHost = "registry.k8s.io"
authType = "anonymous"
enabled = true

[tokenCache]
# 启用缓存（同时控制 Token 和 Manifest 缓存）
enabled = true
# 缓存时间，Go duration 格式（如 20m、1h、30s）
defaultTTL = "20m"

# 日志等级：debug/info/warn/error
logLevel = "info"
EOF
    fi

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入服务访问端口 (宿主机端口) [默认: 5000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="5000"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 修改目录及文件权限，避免容器无权读取
    chmod -R 777 "$BASE_DIR"

    # 生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  hubproxy:
    image: ghcr.io/787a68/hubproxy:latest
    container_name: ${CONTAINER_NAME}
    restart: always
    ports:
      - "${custom_port}:5000"
    environment:
      - CONFIG_PATH=/app/config.toml
    volumes:
      - ${CONFIG_FILE}:/app/config.toml:ro
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:5000/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Hubproxy 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}           Hubproxy 部署及启动成功！                ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}配置文件路径 : $CONFIG_FILE (只读挂载)${RESET}"
    echo -e "${CYAN}提示: 如需修改代理白名单或限速规则，请编辑上述 config.toml 后重启容器。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_hubproxy() {
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
uninstall_hubproxy() {
    echo -ne "${YELLOW}确定要卸载并删除 Hubproxy 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有本地配置文件及挂载数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置及本地数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_hubproxy() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_hubproxy() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_hubproxy() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_hubproxy() { 
    echo -e "${CYAN}--- 容器当前运行日志 (按 Ctrl+C 退出查看) ---${RESET}"
    docker logs -f "$CONTAINER_NAME"; 
}

show_info() {
    get_status_info
    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${YELLOW}当前状态     : $status"
    echo -e "${YELLOW}镜像名称     : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}配置文件路径 : ${CONFIG_FILE}${RESET}"
    echo -e "${GREEN}========================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}   ◈  Hubproxy 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_hubproxy ;;
        2) update_hubproxy ;;
        3) uninstall_hubproxy ;;
        4) start_hubproxy ;;
        5) stop_hubproxy ;;
        6) restart_hubproxy ;;
        7) logs_hubproxy ;;
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
