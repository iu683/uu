#!/bin/bash
# =================================================================
# TGFS (mifun-storage) Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="tgfs"
BASE_DIR="/opt/tgfs"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
VOLUME_NAME="tgfs_data"

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

# 动态获取容器状态、映射端口和镜像信息
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        return 0
    fi

    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${GREEN}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 优先读取 .env 中的 PORT，再从容器端口映射提取
        local env_port=""
        if [[ -f "$ENV_FILE" ]]; then
            env_port=$(grep -E '^PORT=' "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' | tr -d "'" | xargs)
        fi
        [[ -z "$env_port" ]] && env_port="3000"

        webui_port=$(docker inspect -f "{{(index (index .NetworkSettings.Ports \"${env_port}/tcp\") 0).HostPort}}" "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="$env_port"
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

# 部署 TGFS
install_tgfs() {
    check_dependencies

    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"

    echo -ne "${YELLOW}请输入服务端口 PORT [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]] || [ "$custom_port" -lt 1 ] || [ "$custom_port" -gt 65535 ]; then
        echo -e "${RED}错误: 端口必须是 1-65535 之间的数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入 SITE_URL (如 https://tgfs.example.com，可留空): ${RESET}"
    read -r site_url

    while true; do
        echo -ne "${YELLOW}请输入 TELEGRAM_BOT_TOKEN (必填): ${RESET}"
        read -r bot_token
        if [[ -n "$bot_token" && "$bot_token" != "replace-with-bot-token" ]]; then
            break
        fi
        echo -e "${RED}错误: TELEGRAM_BOT_TOKEN 不能为空或占位符！${RESET}"
    done

    while true; do
        echo -ne "${YELLOW}请输入 TELEGRAM_STORAGE_CHAT_ID (频道 ID，如 -1001234567890): ${RESET}"
        read -r chat_id
        if [[ "$chat_id" =~ ^-?[0-9]+$ ]]; then
            break
        fi
        echo -e "${RED}错误: Chat ID 必须是整数（通常以 -100 开头）！${RESET}"
    done

    echo -ne "${YELLOW}请输入管理员鉴权 ADMIN_TOKEN [留空自动生成随机 Token，输入 none 关闭鉴权]: ${RESET}"
    read -r admin_token
    if [[ "$admin_token" == "none" || "$admin_token" == "NONE" ]]; then
        admin_token=""
    elif [[ -z "$admin_token" ]]; then
        if command -v openssl &> /dev/null; then
            admin_token=$(openssl rand -hex 32)
        else
            admin_token=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
        fi
    fi

    echo -ne "${YELLOW}请输入单个文件上传上限字节数 MAX_UPLOAD_SIZE [默认: 52428800 (50MiB)]: ${RESET}"
    read -r max_upload
    [[ -z "$max_upload" ]] && max_upload="52428800"

    echo -ne "${YELLOW}请输入单个文件下载上限字节数 MAX_DOWNLOAD_SIZE [默认: 20971520 (20MiB)]: ${RESET}"
    read -r max_download
    [[ -z "$max_download" ]] && max_download="20971520"

    echo -e "${YELLOW}正在生成 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
# HTTP 服务监听端口和地址
PORT=${custom_port}
HOST=0.0.0.0
SITE_URL=${site_url}
ABOUT_ENABLED=true

# 数据库配置（留空默认使用容器卷 /app/data/tgfs.db）
DATABASE_URL=

# Telegram Bot 与存储频道配置
TELEGRAM_BOT_TOKEN=${bot_token}
TELEGRAM_STORAGE_CHAT_ID=${chat_id}

# 管理员鉴权 Token（留空表示关闭管理员鉴权）
ADMIN_TOKEN=${admin_token}

# 单个文件上传和下载大小上限（字节）
MAX_UPLOAD_SIZE=${max_upload}
MAX_DOWNLOAD_SIZE=${max_download}
EOF
    chmod 600 "$ENV_FILE"

    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  tgfs:
    image: andyskaura/mifun-storage:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      HOST: 0.0.0.0
    ports:
      - "\${PORT:-3000}:\${PORT:-3000}"
    volumes:
      - ${VOLUME_NAME}:/app/data

volumes:
  ${VOLUME_NAME}:
    name: ${VOLUME_NAME}
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 TGFS 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}              TGFS 部署及启动成功！                 ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}数据持久化卷 : ${VOLUME_NAME} -> /app/data${RESET}"
    echo -e "${YELLOW}配置文件路径 : ${ENV_FILE}${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    if [[ -n "$admin_token" ]]; then
        echo -e "${CYAN}🔑 管理员 Token (ADMIN_TOKEN):${RESET}"
        echo -e "${GREEN}   👉 ${RESET}${RED}${admin_token}${RESET}"
    else
        echo -e "${YELLOW}⚠️  当前未设置 ADMIN_TOKEN（管理员鉴权已关闭）${RESET}"
    fi
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_tgfs() {
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
uninstall_tgfs() {
    echo -ne "${YELLOW}确定要卸载并删除 TGFS 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除配置目录 ($BASE_DIR) 及数据卷 ($VOLUME_NAME)？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                docker volume rm "$VOLUME_NAME" 2>/dev/null
                echo -e "${GREEN}配置目录及数据卷已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_tgfs()   { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_tgfs()    { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_tgfs() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_tgfs() {
    echo -e "${CYAN}--- 容器当前运行日志 (按 Ctrl+C 退出查看) ---${RESET}"
    docker logs -f "$CONTAINER_NAME"
}

show_info() {
    get_status_info
    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${YELLOW}当前状态     : $status"
    echo -e "${YELLOW}镜像名称     : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}数据持久化卷 : ${VOLUME_NAME} -> /app/data${RESET}"
    echo -e "${YELLOW}环境变量文件 : ${ENV_FILE}${RESET}"
    echo -e "${GREEN}========================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}     ◈  TGFS 管理面板  ◈      ${RESET}"
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
        1) install_tgfs ;;
        2) update_tgfs ;;
        3) uninstall_tgfs ;;
        4) start_tgfs ;;
        5) stop_tgfs ;;
        6) restart_tgfs ;;
        7) logs_tgfs ;;
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
