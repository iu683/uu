#!/bin/bash
# =================================================================
# Tgzfxy 监控服务 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="sbbot"
BASE_DIR="/opt/Tgzfxy"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
GIT_REPO="https://github.com/sd87671067/Tgzfxy.git"

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
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
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
        [[ -z "$img_version" ]] && img_version="已安装 (本地构建)"
    else
        img_version="${RED}未安装${RESET}"
    fi
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

# 部署 Tgzfxy (自动克隆仓库并初始化)
install_utils() {
    check_dependencies
    
    if [ -d "$BASE_DIR/.git" ]; then
        echo -e "${YELLOW}检测到项目已存在，正在拉取最新代码 (git pull)...${RESET}"
        cd "$BASE_DIR" && git pull
    else
        echo -e "${YELLOW}正在克隆仓库 ${GIT_REPO} 到 ${BASE_DIR}...${RESET}"
        mkdir -p "$(dirname "$BASE_DIR")"
        if [ -d "$BASE_DIR" ]; then
            cd "$BASE_DIR" && git clone "$GIT_REPO" .
        else
            git clone "$GIT_REPO" "$BASE_DIR"
            cd "$BASE_DIR"
        fi
    fi

    echo -e "\n${CYAN}====== 1. 核心凭证配置 (Telegram) ======${RESET}"
    echo -ne "${YELLOW}请输入 Telegram Bot Token (必填): ${RESET}"
    read -r input_bot_token
    echo -ne "${YELLOW}请输入管理员用户 ID (多个用逗号分隔，必填): ${RESET}"
    read -r input_admin_ids

    echo -e "\n${CYAN}====== 2. 数据与配置挂载路径 ======${RESET}"
    echo -e "${YELLOW}提示: 直接回车将默认采用同级路径下的 data 文件夹。${RESET}"
    echo -ne "${YELLOW}请输入数据本地挂载路径 [默认: ./data]: ${RESET}"
    read -r input_data
    local path_data_raw="${input_data:-./data}"
    local real_path_data=$(get_real_path "$path_data_raw" "./data")
    mkdir -p "$real_path_data"
    chmod -R 777 "$real_path_data"

    echo -ne "${YELLOW}请输入 sing-box 宿主机配置目录 [默认: /etc/sing-box]: ${RESET}"
    read -r input_singbox_dir
    local singbox_dir="${input_singbox_dir:-/etc/sing-box}"
    mkdir -p "$singbox_dir"

    echo -ne "${YELLOW}请输入证书宿主机目录 [默认: /root/certs]: ${RESET}"
    read -r input_certs_dir
    local certs_dir="${input_certs_dir:-/root/certs}"
    mkdir -p "$certs_dir"

    # 生成 .env 配置文件
    echo -e "${YELLOW}正在生成 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
# 必填：BotFather token；管理员用户 ID（多个用逗号分隔）
TELEGRAM_BOT_TOKEN=${input_bot_token}
TELEGRAM_ADMIN_IDS=${input_admin_ids}

# 可选：Telegram 用户账号转发助手的开发者 API
FORWARD_API_ID=
FORWARD_API_HASH=

# 可选：搬瓦工
BWH_API_KEY=
BWH_VEID=

# 添加 AnyTLS / Hysteria 2 时必填，路径为宿主机和容器内相同的绝对路径
# 对外 TLS 域名；不带协议前缀
SHARE_DOMAIN=
# 分享链接地址；留空自动推断
SHARE_HOST=
CERTS_DIR=${certs_dir}
ANYTLS_CERT_PATH=
ANYTLS_KEY_PATH=

# Reality 伪装目标，可按需更换
REALITY_SNI=itunes.apple.com

# 仅挂载本地配置；不要将 config.json 提交 Git
SINGBOX_CONFIG_DIR=${singbox_dir}
SINGBOX_API_URL=http://127.0.0.1:9090
# 本机 Clash API 密钥；请自行设置
SINGBOX_API_SECRET=
AUTO_CONFIGURE_CLASH_API=true
AUTO_RESTART_SING_BOX=true
DEFAULT_MONTHLY_LIMIT_GB=500
TIMEZONE=Asia/Shanghai
DAILY_REPORT_HOUR=9
POLL_SECONDS=60
EOF
    chmod 600 "$ENV_FILE"

    # 生成 docker-compose.yml 配置文件 (网络模式保持 host，数据和配置本地挂载)
    echo -e "${YELLOW}正在生成规范的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  sbbot:
    build: .
    container_name: ${CONTAINER_NAME}
    restart: "on-failure:3"
    env_file:
      - .env
    network_mode: host
    pid: host
    privileged: true
    volumes:
      - \${SINGBOX_CONFIG_DIR:-/etc/sing-box}:/config
      - ${path_data_raw}:/data
      - \${CERTS_DIR:-/root/certs}:\${CERTS_DIR:-/root/certs}:ro
    logging:
      driver: local
      options:
        max-size: "5m"
        max-file: "2"
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 构建并启动 Tgzfxy...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --build --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}        Tgzfxy 部署成功！       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}数据直挂路径   : ${real_path_data}${RESET}"
    echo -e "${YELLOW}配置挂载路径   : ${singbox_dir}${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 Tgzfxy (拉取最新代码并重新构建)
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从 Git 仓库拉取最新代码并重新构建...${RESET}"
    cd "$BASE_DIR" && git pull && docker compose up -d --build --force-recreate
    echo -e "${GREEN}更新完成！代码已同步且容器已重新构建。${RESET}"
}

# 卸载 Tgzfxy
uninstall_utils() {
    echo -e "${RED}警告: 卸载如果清理数据，将永久丢失您的机器人配置与数据库！${RESET}"
    echo -ne "${YELLOW}确定要卸载并删除 Tgzfxy 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}是否同时彻底删除本地全量挂载的数据与配置文件？(y/n): ${RESET}"
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
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像状态       : ${img_version}${RESET}"
    echo -e "${YELLOW}代码目录       : $BASE_DIR${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${YELLOW}环境变量路径   : $ENV_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  Tgzfxy 管理面板  ◈      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
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
