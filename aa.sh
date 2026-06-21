#!/bin/bash
# =================================================================
# qBit-Bot (Telegram 机器人) 专属管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="my-qbit-bot"
BASE_DIR="/opt/my_qbit_bot"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi
}

# 部署 qBit-Bot
install_qbit_bot() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 配置 qBit-Bot 环境变量 ======${RESET}"
    
    echo -ne "${YELLOW}1. 请输入 qBittorrent 地址 (例如 http://127.0.0.1:8080): ${RESET}"
    read -r qb_host
    if [[ -z "$qb_host" ]]; then
        echo -e "${RED}错误: 地址不能为空！${RESET}"
        return
    fi

    echo -ne "${YELLOW}2. 请输入 qBittorrent 用户名: ${RESET}"
    read -r qb_user

    echo -ne "${YELLOW}3. 请输入 qBittorrent 密码: ${RESET}"
    read -r qb_pass

    echo -ne "${YELLOW}4. 请输入 Telegram Bot Token: ${RESET}"
    read -r tg_token
    if [[ -z "$tg_token" ]]; then
        echo -e "${RED}错误: Token 不能为空！${RESET}"
        return
    fi

    echo -ne "${YELLOW}5. 请输入 你的 Telegram User ID: ${RESET}"
    read -r tg_user_id

    # 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  qbit-bot:
    image: gblaowang12138/my_qbit_bot:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    network_mode: "host"
    environment:
      QB_HOST: "${qb_host}"
      QB_USER: "${qb_user}"
      QB_PASS: "${qb_pass}"
      TG_TOKEN: "${tg_token}"
      TG_USER_ID: "${tg_user_id}"
EOF

    echo -e "${YELLOW}正在拉取镜像并启动 qBit-Bot...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化...${RESET}"
    sleep 2

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    qBit-Bot 部署流程完成！     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}由于采用 Host 网络模式，请直接在 Telegram 客户端中测试机器人是否上线。${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_qbit_bot() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！机器人容器已处于最新状态。${RESET}"
}

# 卸载机器人
uninstall_qbit_bot() {
    echo -ne "${YELLOW}确定要卸载并删除 qBit-Bot 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            rm -rf "$BASE_DIR"
            echo -e "${GREEN}容器已停止，本地配置目录已彻底清理。${RESET}"
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_bot() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}机器人已启动${RESET}"; }
stop_bot() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}机器人已停止${RESET}"; }
restart_bot() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}机器人已重启${RESET}"; }
logs_bot() { docker logs -f "$CONTAINER_NAME"; }

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  qBit-Bot 管理面板  ◈     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}模式 :${RESET} ${YELLOW}Host${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_qbit_bot ;;
        2) update_qbit_bot ;;
        3) uninstall_qbit_bot ;;
        4) start_bot ;;
        5) stop_bot ;;
        6) restart_bot ;;
        7) logs_bot ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
