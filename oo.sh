#!/bin/bash
# =================================================================
# Renewlet (域名订阅提醒) Docker Compose 独立管理面板 - 本地直挂版
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="renewlet"
BASE_DIR="/opt/renewlet"
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
    if [ "$(docker ps -q -f name=^/renewlet$)" ]; then
        status="${YELLOW}运行中${RESET}"
        health_status=$(docker inspect -f '{{.State.Health.Status}}' "renewlet" 2>/dev/null)
        [[ -n "$health_status" ]] && status="${YELLOW}运行中 (${health_status})${RESET}"
    elif [ "$(docker ps -aq -f name=^/renewlet$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/renewlet$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "renewlet" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "renewlet" 2>/dev/null)
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

# 部署 Renewlet
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 目录挂载自定义配置 ======${RESET}"
    echo -e "${YELLOW}提示: 直接回车将默认在同级路径下创建 pb_data 文件夹。${RESET}"
    
    # 本地目录挂载点自定义
    echo -ne "${YELLOW}请输入数据(pb_data)本地挂载路径 [默认: ./pb_data]: ${RESET}"
    read -r input_data
    local path_data_raw="${input_data:-./pb_data}"
    local real_path_data=$(get_real_path "$path_data_raw" "./pb_data")

    # 预创建本地物理目录，防止 Docker 误将其创建为 root 权限文件夹
    mkdir -p "$real_path_data"

    echo -e "\n${CYAN}====== 2. 基础网络配置 ======${RESET}"
    # 对外端口自定义
    echo -ne "${YELLOW}请输入 Renewlet 访问端口 [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"

    # 对外公网或内网 APP_URL
    echo -ne "${YELLOW}请输入外部访问的完整 URL [默认: http://${DETECT_IP}:${custom_port}]: ${RESET}"
    read -r input_url
    local app_url="${input_url:-http://${DETECT_IP}:${custom_port}}"

    echo -e "\n${CYAN}====== 3. 安全与性能配额 ======${RESET}"
    # 自动生成 32 位 PB 加密密钥
    echo -e "${YELLOW}正在自动构建 32 位高强度 PocketBase 安全加密密钥...${RESET}"
    local random_pb_key=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 32)

    # 写入环境变量文件 .env
    echo -e "${YELLOW}正在生成外部环境配置文件 .env...${RESET}"
    cat <<EOF > "$ENV_FILE"
PORT=${custom_port}
GOMEMLIMIT=128MiB
MEM_LIMIT=256m
TZ=Asia/Shanghai
APP_URL=${app_url}
RENEWLET_DEMO_MODE=false
RENEWLET_CUSTOM_HEAD_SCRIPT=""
PB_ENCRYPTION_KEY=${random_pb_key}
NOTIFICATION_SCHEDULER_ENABLED=true
CRON_SECRET=""
NOTIFICATION_SCHEDULER_CRON="* * * * *"
NOTIFICATION_CRON_WINDOW_MINUTES=2
NOTIFICATION_MAX_RETRIES=3
NOTIFICATION_STALE_SENDING_MINUTES=15
EOF

    # 动态构建规范的 docker-compose.yml 配置文件 (移除 volumes 声明，直接绑定本地路径)
    echo -e "${YELLOW}正在生成直挂本地版的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  web:
    image: ghcr.io/zhiyingzzhou/renewlet:latest
    container_name: renewlet
    environment:
      GOMEMLIMIT: \${GOMEMLIMIT:-128MiB}
      TZ: \${TZ:-Asia/Shanghai}
      APP_URL: \${APP_URL:-http://localhost:3000}
      RENEWLET_DEMO_MODE: \${RENEWLET_DEMO_MODE:-false}
      RENEWLET_CUSTOM_HEAD_SCRIPT: \${RENEWLET_CUSTOM_HEAD_SCRIPT:-}
      PB_ENCRYPTION_KEY: \${PB_ENCRYPTION_KEY:-}
      SMTP_HOST: \${SMTP_HOST:-}
      SMTP_PORT: \${SMTP_PORT:-587}
      SMTP_USER: \${SMTP_USER:-}
      SMTP_PASSWORD: \${SMTP_PASSWORD:-}
      SMTP_FROM: \${SMTP_FROM:-}
      SMTP_TLS: \${SMTP_TLS:-false}
      BACKUPS_CRON: \${BACKUPS_CRON:-}
      BACKUPS_CRON_MAX_KEEP: \${BACKUPS_CRON_MAX_KEEP:-3}
      NOTIFICATION_SCHEDULER_ENABLED: \${NOTIFICATION_SCHEDULER_ENABLED:-true}
      CRON_SECRET: \${CRON_SECRET:-}
      NOTIFICATION_SCHEDULER_CRON: "\${NOTIFICATION_SCHEDULER_CRON:-* * * * *}"
      NOTIFICATION_CRON_WINDOW_MINUTES: \${NOTIFICATION_CRON_WINDOW_MINUTES:-2}
      NOTIFICATION_MAX_RETRIES: \${NOTIFICATION_MAX_RETRIES:-3}
      NOTIFICATION_STALE_SENDING_MINUTES: \${NOTIFICATION_STALE_SENDING_MINUTES:-15}
    volumes:
      - ${path_data_raw}:/pb_data
    ports:
      - "\${PORT:-3000}:3000"
    healthcheck:
      test: [ "CMD", "/renewlet", "healthcheck" ]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    mem_limit: \${MEM_LIMIT:-256m}
    restart: unless-stopped
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Renewlet...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化与健康检查预热 (约5秒)...${RESET}"
    sleep 5

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}         Renewlet 部署成功！      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : ${app_url}${RESET}"
    echo -e "${YELLOW}设置管理员向导 : ${app_url}/setup${RESET}"
    echo -e "${YELLOW}数据加密 Key   : ${random_pb_key}${RESET}"
    echo -e "${YELLOW}数据直挂路径   : ${real_path_data}${RESET}"
    echo -e "${YELLOW}环境配置路径   : $ENV_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 升级镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取 Renewlet 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载容器
uninstall_utils() {
    echo -e "${RED}高危警告: 卸载如果清理数据，将永久清空您物理目录下的所有账单和数据库文件！${RESET}"
    echo -ne "${YELLOW}确定要卸载并删除 Renewlet 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}【极高风险】是否同时彻底删除本地物理挂载的数据文件夹？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地物理数据目录及配置文件已全部销毁。${RESET}"
            fi
        else
            docker rm -f renewlet 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_utils() { docker logs -f renewlet; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    if [ -f "$ENV_FILE" ]; then
        local current_url=$(grep -E "^APP_URL=" "$ENV_FILE" | cut -d'=' -f2)
        echo -e "${YELLOW}配置访问地址   : ${current_url}${RESET}"
    fi
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  Renewlet 管理面板  ◈     ${RESET}"
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
