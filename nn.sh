#!/bin/bash
# =================================================================
# EmbyTG 管理中心 Docker Compose 管理面板 (无端口纯净版)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# 核心变量
CONTAINER_NAME="emby_tg_admin"  
BASE_DIR="/opt/emby_tg_bot"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
GIT_REPO="https://github.com/sd87671067/EmbyTGBot.git"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! command -v git &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Git，请先安装 Git！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        health_status=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null)
        if [[ "$health_status" == "healthy" ]]; then
            status="${GREEN}运行中 (健康)${RESET}"
        elif [[ "$health_status" == "unhealthy" ]]; then
            status="${RED}运行中 (不健康)${RESET}"
        else
            status="${YELLOW}运行中 (启动中)${RESET}"
        fi
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi
}

# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
        ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
    done
    echo "127.0.0.1" && return 0
}

# 部署 EmbyTG 机器人
install_utils() {
    check_dependencies
    
    if [ ! -d "$BASE_DIR" ]; then
        echo -e "${YELLOW}正在克隆项目源码到 $BASE_DIR...${RESET}"
        git clone "$GIT_REPO" "$BASE_DIR"
    else
        echo -e "${YELLOW}目录 $BASE_DIR 已存在，准备更新配置...${RESET}"
    fi

    echo -e "${CYAN}====== 自定义环境参数配置 ======${RESET}"
    DETECT_IP=$(get_public_ip)

    # 交互式输入配置
    echo -ne "${YELLOW}1. Emby 内部 API 地址 [默认: http://172.17.0.1:8096]: ${RESET}"
    read -r emby_base_url
    [[ -z "$emby_base_url" ]] && emby_base_url="http://172.17.0.1:8096"

    echo -ne "${YELLOW}2. Emby API 密钥 (必填): ${RESET}"
    read -r emby_api_key

    echo -ne "${YELLOW}3. 用户连接的 Emby 公网外网地址 [默认: http://${DETECT_IP}:8096]: ${RESET}"
    read -r emby_public_url
    [[ -z "$emby_public_url" ]] && emby_public_url="http://${DETECT_IP}:8096"

    echo -ne "${YELLOW}4. TG 管理员机器人 Token (必填): ${RESET}"
    read -r admin_bot_token

    echo -ne "${YELLOW}5. TG 管理员账户数字 ID (必填): ${RESET}"
    read -r admin_chat_ids

    echo -ne "${YELLOW}6. TG 客户服务机器人 Token (必填): ${RESET}"
    read -r client_bot_token

    echo -ne "${YELLOW}7. 管理员 TG 用户名 (如 @my_tg_name): ${RESET}"
    read -r admin_username

    app_master_key=$(openssl rand -hex 16 2>/dev/null || echo "rand_master_key_$(date +%s)")

    echo -e "${YELLOW}正在写入配置文件 .env...${RESET}"
    cat <<EOF > "$ENV_FILE"
# -------------------------------
# 基础配置
# -------------------------------
APP_NAME=Emby TG 管理中心
APP_ENV=production
APP_PORT=8080
APP_BASE_URL=http://127.0.0.1:8080
APP_TIMEZONE=Asia/Shanghai
APP_MASTER_KEY=${app_master_key}
APP_WEB_ADMIN_USERNAME=admin
APP_WEB_ADMIN_PASSWORD=admin_pass_change_me

# -------------------------------
# Emby 配置
# -------------------------------
EMBY_BASE_URL=${emby_base_url}
EMBY_API_KEY=${emby_api_key}
EMBY_SERVER_PUBLIC_URL=${emby_public_url}
EMBY_TEMPLATE_USER=testone
EMBY_IMPORT_IGNORE_USERNAMES=xiaocai
EMBY_SYNC_LOCAL_DEFAULT_PASSWORD=1234
EMBY_PUSH_SYNC_DELAY_SECONDS=0.6

# -------------------------------
# Telegram 机器人
# -------------------------------
ADMIN_BOT_TOKEN=${admin_bot_token}
ADMIN_CHAT_IDS=${admin_chat_ids}
CLIENT_BOT_TOKEN=${client_bot_token}

# -------------------------------
# 联系方式 / 文案
# -------------------------------
ADMIN_CONTACT_TG_USERNAME=${admin_username}
ADMIN_CONTACT_TG_USER_ID=${admin_chat_ids}
DEFAULT_USER_EXPIRE_DAYS=90
REGISTER_CODE_LENGTH=16
CODE_BATCH_LIMIT=500
WEB_EXPIRING_SOON_DAYS=3

# -------------------------------
# 后台任务
# -------------------------------
EXPIRY_CHECK_SECONDS=3600
ONLINE_CHECK_SECONDS=60
EOF

    echo -e "${YELLOW}正在编译并启动 EmbyTG 机器人...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --build --force-recreate

    echo -e "${YELLOW}等待容器初始化并进行健康检查...${RESET}"
    sleep 5

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      EmbyTGBot 部署成功！      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}提示: 已遵照官方设计，未暴露任何对外 Web 端口。${RESET}"
    echo -e "${YELLOW}配置文件路径   : $ENV_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 EmbyTG 机器人
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取新源码并重新编译...${RESET}"
    cd "$BASE_DIR" && git pull && docker compose up -d --build --remove-orphans
    echo -e "${GREEN}更新完成！${RESET}"
}

# 卸载 EmbyTG 机器人
uninstall_utils() {
    echo -ne "${RED}确定要卸载并删除 EmbyTG 机器人吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地所有配置及源码？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}目录已清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" 2>/dev/null && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" 2>/dev/null && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" 2>/dev/null && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}容器名称       : ${CONTAINER_NAME}"
    echo -e "${YELLOW}网络模式       : 纯机器人交互 (无外部端口)"
    echo -e "${YELLOW}项目源码路径   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  EmbyTG 机器人管理面板  ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}已禁用 (安全模式)${RESET}"
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
