#!/bin/bash
# TelegramMonitor 一键管理脚本（挂载数据卷版）
# 支持启动/停止/查看日志/删除/更新容器
# 绿色字体显示

SERVICE_NAME="telegram-monitor"
IMAGE_NAME="ghcr.io/riniba/telegrammonitor:latest"
DEFAULT_PORT=5005
DATA_DIR="$HOME/telegram-monitor-data"

# 颜色
GREEN="\e[32m"
RESET="\e[0m"

# 创建数据目录
mkdir -p "$DATA_DIR"

print_menu() {
    echo -e "${GREEN}======================${RESET}"
    echo -e "${GREEN}  TelegramMonitor 管理菜单  ${RESET}"
    echo -e "${GREEN}======================${RESET}"
    echo -e "${GREEN}1. 启动容器${RESET}"
    echo -e "${GREEN}2. 停止容器${RESET}"
    echo -e "${GREEN}3. 查看日志${RESET}"
    echo -e "${GREEN}4. 删除容器${RESET}"
    echo -e "${GREEN}5. 更新容器${RESET}"
    echo -e "${GREEN}6. 退出${RESET}"
    echo -e "${GREEN}======================${RESET}"
    read -p "请输入选项: " choice
}

read_port() {
    read -p "请输入容器端口（默认 $DEFAULT_PORT）: " PORT
    PORT=${PORT:-$DEFAULT_PORT}
}

start_container() {
    if [ "$(docker ps -q -f name=$SERVICE_NAME)" ]; then
        echo -e "${GREEN}容器已在运行中${RESET}"
    else
        read_port
        echo -e "${GREEN}拉取最新镜像...${RESET}"
        docker pull $IMAGE_NAME
        echo -e "${GREEN}启动容器...${RESET}"
        docker run -d \
          --name $SERVICE_NAME \
          --restart unless-stopped \
          -p $PORT:5005 \
          -v "$DATA_DIR":/app \
          $IMAGE_NAME
        echo -e "${GREEN}容器启动完成，访问：http://localhost:$PORT${RESET}"
    fi
}

stop_container() {
    if [ "$(docker ps -q -f name=$SERVICE_NAME)" ]; then
        docker stop $SERVICE_NAME
        echo -e "${GREEN}容器已停止${RESET}"
    else
        echo -e "${GREEN}容器未运行${RESET}"
    fi
}

view_logs() {
    if [ "$(docker ps -q -f name=$SERVICE_NAME)" ]; then
        docker logs -f $SERVICE_NAME
    else
        echo -e "${GREEN}容器未运行，无法查看日志${RESET}"
    fi
}

delete_container() {
    if [ "$(docker ps -aq -f name=$SERVICE_NAME)" ]; then
        docker rm -f $SERVICE_NAME
        echo -e "${GREEN}容器已删除${RESET}"
    else
        echo -e "${GREEN}容器不存在${RESET}"
    fi
}

update_container() {
    echo -e "${GREEN}拉取最新镜像...${RESET}"
    docker pull $IMAGE_NAME
    if [ "$(docker ps -aq -f name=$SERVICE_NAME)" ]; then
        echo -e "${GREEN}停止并删除旧容器...${RESET}"
        docker rm -f $SERVICE_NAME
    fi
    start_container
    echo -e "${GREEN}容器已更新到最新版本${RESET}"
}

while true; do
    print_menu
    case $choice in
        1) start_container ;;
        2) stop_container ;;
        3) view_logs ;;
        4) delete_container ;;
        5) update_container ;;
        6) exit 0 ;;
        *) echo -e "${GREEN}无效选项，请重新输入${RESET}" ;;
    esac
done
