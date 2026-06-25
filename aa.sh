#!/bin/bash
# =================================================================
# ForwardX 端口转发管理面板 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="forwardx-panel"
BASE_DIR="/opt/forwardx"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中提取实际端口
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取镜像名称/版本
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 从容器状态提取前端映射端口（容器内部默认监听 3000）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3000"
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

# 生成随机 JWT 密钥
generate_jwt_secret() {
    if command -v openssl &> /dev/null; then
        openssl_rand=$(openssl rand -hex 16 2>/dev/null)
        if [[ -n "$openssl_rand" ]]; then echo "$openssl_rand"; return; fi
    fi
    echo "fwdx_$(date +%s)_$((RANDOM % 9999))"
}

# 部署 ForwardX
install_forwardx() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 ForwardX 面板访问端口 [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"

    echo -ne "${YELLOW}请输入初始管理员密码 [默认: admin123]: ${RESET}"
    read -r admin_pwd
    [[ -z "$admin_pwd" ]] && admin_pwd="admin123"

    echo -ne "${YELLOW}是否配置 Telegram 机器人通知？(y/n) [默认: n]: ${RESET}"
    read -r tg_choice
    local tg_token=""
    local tg_polling="true"
    if [[ "$tg_choice" == "y" || "$tg_choice" == "Y" ]]; then
        echo -ne "${YELLOW}请输入 Telegram Bot Token: ${RESET}"
        read -r tg_token
    fi

    # 自动生成随机 JWT 安全密钥
    local jwt_secret=$(generate_jwt_secret)

    # 1. 动态生成 .env 环境配置文件
    echo -e "${YELLOW}正在创建 .env 环境变量文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
# ==================== 数据库配置 ====================
SQLITE_PATH=/data/forwardx.db

# ==================== 安全配置 ====================
JWT_SECRET=${jwt_secret}

# ==================== 应用配置 ====================
NODE_ENV=production
PORT=3000
FORWARDX_IMAGE=ghcr.io/poouo/forwardx:latest

# ==================== 管理员配置 ====================
ADMIN_PASSWORD=${admin_pwd}
EOF

    # 如果配置了 TG 机器人，则追加到 .env
    if [[ -n "$tg_token" ]]; then
        cat <<EOF >> "$ENV_FILE"

# ==================== Telegram 机器人 ====================
TELEGRAM_BOT_TOKEN=${tg_token}
TELEGRAM_BOT_POLLING=${tg_polling}
EOF
    fi

    # 2. 动态生成 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在创建 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
name: forwardx

services:
  forwardx:
    image: \${FORWARDX_IMAGE:-ghcr.io/poouo/forwardx:latest}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${custom_port}:3000"
    environment:
      NODE_ENV: production
      PORT: 3000
      DATABASE_CONFIG_PATH: /data/database.json
      SQLITE_PATH: /data/forwardx.db
      MYSQL_CONFIG_PATH: /data/mysql.json
      POSTGRES_URL: \${POSTGRES_URL:-}
      POSTGRES_HOST: \${POSTGRES_HOST:-}
      POSTGRES_PORT: \${POSTGRES_PORT:-5432}
      POSTGRES_USER: \${POSTGRES_USER:-}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:-}
      POSTGRES_DATABASE: \${POSTGRES_DATABASE:-}
      POSTGRES_SSL: \${POSTGRES_SSL:-false}
      JWT_SECRET: \${JWT_SECRET:-change-me-to-a-random-string}
    volumes:
      - forwardx-data:/data

volumes:
  forwardx-data:
    driver: local
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 ForwardX 面板...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约5秒)...${RESET}"
    sleep 5

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      ForwardX 部署成功！       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}面板访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}管理初始密码 : ${admin_pwd}${RESET}"
    echo -e "${YELLOW}配置文件目录 : ${BASE_DIR}${RESET}"
    echo -e "${RED}提示: 生产环境下的 JWT 安全密钥已自动为您生成并注入到 .env。${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 ForwardX
update_forwardx() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取 ForwardX 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已成功平滑重启。${RESET}"
}

# 卸载 ForwardX
uninstall_forwardx() {
    echo -ne "${YELLOW}确定要卸载并删除 ForwardX 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件和挂载的数据库卷(数据会丢失)？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                cd "$BASE_DIR" && docker compose down -v
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地数据卷及目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

check_compose_exist() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return 1
    fi
    return 0
}

start_forwardx() { check_compose_exist && cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_forwardx() { check_compose_exist && cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_forwardx() { check_compose_exist && cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }

logs_forwardx() { 
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        docker logs -f "$CONTAINER_NAME"
    else
        echo -e "${RED}错误: 容器未创建，无法查看日志！${RESET}"
    fi
}

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}面板访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}配置根目录     : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈   ForwardX 转发管理面板  ◈   ${RESET}"
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
        1) install_forwardx ;;
        2) update_forwardx ;;
        3) uninstall_forwardx ;;
        4) start_forwardx ;;
        5) stop_forwardx ;;
        6) restart_forwardx ;;
        7) logs_forwardx ;;
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
