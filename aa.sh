#!/bin/bash
# =================================================================
# ForwardXplus Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="forwardxplus-panel"
BASE_DIR="/opt/forwardxplus"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
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

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="9810"
        port_display="${webui_port}"
    else
        img_version="${RED}未安装${RESET}"
        port_display="N/A"
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

# 处理绝对路径与相对路径转换
get_real_path() {
    local input_path="$1"
    local default_path="$2"
    [[ -z "$input_path" ]] && input_path="$default_path"

    if [[ "$input_path" == "./"* ]]; then
        echo "$BASE_DIR/${input_path#./}"
    else
        echo "$input_path"
    fi
}

# 部署 ForwardXplus
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 目录挂载自定义配置 ======${RESET}"
    echo -e "${YELLOW}提示: 直接回车将默认采用同级路径下的 data 文件夹。${RESET}"
    echo -ne "${YELLOW}请输入数据(data)本地挂载路径 [默认: ./data]: ${RESET}"
    read -r input_data
    local path_data_raw="${input_data:-./data}"
    local real_path_data=$(get_real_path "$path_data_raw" "./data")

    mkdir -p "$real_path_data"
    chmod -R 777 "$real_path_data"

    echo -e "\n${CYAN}====== 2. 网络端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 ForwardX 访问端口 [默认: 9810]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="9810"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 生成 .env 配置文件
    echo -e "${YELLOW}正在生成 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
PORT=${custom_port}
COMPOSE_PROJECT_NAME=forwardx
FORWARDX_CONTAINER_NAME=${CONTAINER_NAME}
FORWARDX_IMAGE=ghcr.io/wzwys9/forwardplus:latest
EOF
    echo "JWT_SECRET=$(openssl rand -hex 32)" >> "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    # 生成 docker-compose.yml 配置文件 (使用本地目录挂载替代命名数据卷)
    echo -e "${YELLOW}正在生成规范的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
name: \${COMPOSE_PROJECT_NAME:-forwardx}

services:
  forwardx:
    image: \${FORWARDX_IMAGE:-ghcr.io/wzwys9/forwardplus:latest}
    container_name: \${FORWARDX_CONTAINER_NAME:-forwardx-panel}
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "\${PORT:-9810}:3000"
    environment:
      NODE_ENV: production
      PORT: 3000
      JWT_SECRET: \${JWT_SECRET}
      FORWARDPLUS_GITHUB_TOKEN: \${FORWARDPLUS_GITHUB_TOKEN:-}
      DATABASE_CONFIG_PATH: /data/database.json
      SQLITE_PATH: /data/forwardx.db
      MYSQL_CONFIG_PATH: /data/mysql.json
      DATABASE_TYPE: \${DATABASE_TYPE:-}
      MYSQL_URL: \${MYSQL_URL:-}
      MYSQL_HOST: \${MYSQL_HOST:-}
      MYSQL_PORT: \${MYSQL_PORT:-3306}
      MYSQL_USER: \${MYSQL_USER:-}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD:-}
      MYSQL_DATABASE: \${MYSQL_DATABASE:-}
      MYSQL_SSL: \${MYSQL_SSL:-false}
      POSTGRES_URL: \${POSTGRES_URL:-}
      POSTGRES_HOST: \${POSTGRES_HOST:-}
      POSTGRES_PORT: \${POSTGRES_PORT:-5432}
      POSTGRES_USER: \${POSTGRES_USER:-}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:-}
      POSTGRES_DATABASE: \${POSTGRES_DATABASE:-}
      POSTGRES_SSL: \${POSTGRES_SSL:-false}
      TELEGRAM_BOT_TOKEN: \${TELEGRAM_BOT_TOKEN:-}
    volumes:
      - ${path_data_raw}:/data
    logging:
      driver: local
      options:
        max-size: "\${FORWARDX_LOG_MAX_SIZE:-20m}"
        max-file: "\${FORWARDX_LOG_MAX_FILES:-3}"
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 ForwardX...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ForwardXplus 部署成功！       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}访问地址       : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}数据直挂路径   : ${real_path_data}${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 ForwardXplus 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 ForwardXplus 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 ForwardXplus
uninstall_utils() {
    echo -e "${RED}警告: 卸载如果清理数据，将永久丢失您的转发及面板配置！${RESET}"
    echo -ne "${YELLOW}确定要卸载并删除 ForwardXplus 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}是否同时彻底删除本地全量挂载的数据库？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有配置及数据已被彻底销毁。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}访问地址       : http://${DETECT_IP}:${port_display}${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  ForwardXplus 管理面板  ◈  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${port_display}${RESET}"
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
