#!/bin/bash
# =================================================================
# Epay-bot Telegram 機器人 Docker Compose 管理面板 
# =================================================================

# 顏色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="epay-bot"
BASE_DIR="/opt/epay-bot"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

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

        # 从容器状态提取数据目录（挂载路径）
        data_dir=$(docker inspect -f '{{range .Mounts}}{{.Source}}{{break}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$data_dir" ]] && data_dir="/opt/epay-bot/data"
        
        webui_port="無 (Bot 類容器不佔用外部端口)"
    else
        # 容器未安装/未部署时的返回值
        img_version="${RED}未安装${RESET}"
        data_dir="N/A"
        webui_port="N/A"
    fi
}

# 检查环境是否已经部署
check_compose_exists() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return 1
    fi
    return 0
}

# 部署 Epay-bot
install_epay_bot() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 Telegram Bot Token (TELEGRAM_BOT_TOKEN): ${RESET}"
    read -r bot_token
    while [[ -z "$bot_token" ]]; do
        echo -e "${RED}错误: Bot Token 不能为空，请重新输入！${RESET}"
        echo -ne "${YELLOW}请输入 Telegram Bot Token: ${RESET}"
        read -r bot_token
    done

    echo -ne "${YELLOW}请输入宿主机数据存储绝对路径 [默认: /opt/epay-bot/data]: ${RESET}"
    read -r custom_data
    [[ -z "$custom_data" ]] && custom_data="/opt/epay-bot/data"

    # 1. 创建所需的宿主机目录
    mkdir -p "$custom_data"
    chmod -R 777 "$BASE_DIR" "$custom_data"

    # 2. 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  epay-bot:
    image: ghcr.io/sky22333/epay-bot
    container_name: ${CONTAINER_NAME}
    restart: always
    volumes:
      - ${custom_data}:/app/data
    environment:
      - TELEGRAM_BOT_TOKEN=${bot_token}
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Epay-bot 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${GREEN}                    Epay-bot 部署成功！                         ${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${YELLOW}宿主机数据路径 : $custom_data${RESET}"
    echo -e "${YELLOW}在 Telegram 中向机器人发送 /start 开始使用。${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
}

# 更新 Epay-bot 镜像
update_epay_bot() {
    check_compose_exists || return
    echo -e "${YELLOW}正在从远端拉取 Epay-bot 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 Epay-bot
uninstall_epay_bot() {
    echo -ne "${YELLOW}确定要卸载并删除 Epay-bot 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有本地配置文件和机器人运行数据？(y/n): ${RESET}"
            read -r clean_data
            if [[ "$clean_data" == "y" || "$clean_data" == "Y" ]]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$data_dir" != "N/A" ]] && rm -rf "$data_dir"
                echo -e "${GREEN}数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_epay_bot() { 
    check_compose_exists || return
    cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"
}

stop_epay_bot() { 
    check_compose_exists || return
    cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"
}

restart_epay_bot() { 
    check_compose_exists || return
    cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"
}

logs_epay_bot() { 
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        docker logs -f "$CONTAINER_NAME"
    else
        echo -e "${RED}错误: 容器不存在，无法查看日志！${RESET}"
    fi
}

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务运行状态   : ${webui_port}${RESET}"
    echo -e "${YELLOW}宿主机数据路径 : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  Epay-bot 管理面板  ◈    ${RESET}"
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
        1) install_epay_bot ;;
        2) update_epay_bot ;;
        3) uninstall_epay_bot ;;
        4) start_epay_bot ;;
        5) stop_epay_bot ;;
        6) restart_epay_bot ;;
        7) logs_epay_bot ;;
        8) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

# 主循环
while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
