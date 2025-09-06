#!/bin/bash
set -e

# ================== 颜色 ==================
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# ================== 默认配置 ==================
CONTAINER_NAME="libretv"
IMAGE_NAME="bestzwei/libretv:latest"
DEFAULT_HOST_PORT=8899
CONTAINER_PORT=8080
DEFAULT_PASSWORD="your_password"

# ================== 工具函数 ==================
pause() {
    read -rp "按回车返回菜单..."
}

check_port() {
    local port=$1
    if lsof -i:"$port" >/dev/null 2>&1; then
        return 1
    else
        return 0
    fi
}

get_ip() {
    IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)
    echo "$IP"
}


print_menu() {
    clear
    echo -e "${YELLOW}=== LibreTV 容器管理菜单 ===${RESET}"
    echo -e "${GREEN}1.启动/创建容器${RESET}"
    echo -e "${GREEN}2.停止容器${RESET}"
    echo -e "${GREEN}3.重启容器${RESET}"
    echo -e "${GREEN}4.查看容器状态${RESET}"
    echo -e "${GREEN}5.查看容器日志${RESET}"
    echo -e "${GREEN}6.删除容器${RESET}"
    echo -e "${GREEN}7.拉取最新镜像并重启容器${RESET}"
    echo -e "${GREEN}0.退出${RESET}"
}

show_access_info() {
    local host_port=$1
    local ip
    ip=$(get_ip)
    echo -e "${GREEN}访问地址: http://${ip}:${host_port}${RESET}"
    echo -e "${GREEN}容器密码: ${PASSWORD}${RESET}"
}

start_container() {
    # 自定义密码
    read -rp "请输入容器密码（回车使用默认: $DEFAULT_PASSWORD）: " PASSWORD
    PASSWORD=${PASSWORD:-$DEFAULT_PASSWORD}

    # 自定义端口
    while true; do
        read -rp "请输入本机端口（回车使用默认: $DEFAULT_HOST_PORT）: " HOST_PORT
        HOST_PORT=${HOST_PORT:-$DEFAULT_HOST_PORT}

        if check_port "$HOST_PORT"; then
            break
        else
            echo -e "${RED}端口 $HOST_PORT 已被占用，请重新输入${RESET}"
        fi
    done

    if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
        echo -e "${YELLOW}容器已存在，尝试启动...${RESET}"
        docker start "$CONTAINER_NAME"
    else
        echo -e "${GREEN}正在创建并启动容器...${RESET}"
        docker run -d \
          --name "$CONTAINER_NAME" \
          --restart unless-stopped \
          -p "$HOST_PORT:$CONTAINER_PORT" \
          -e PASSWORD="$PASSWORD" \
          "$IMAGE_NAME"
    fi
    echo -e "${GREEN}容器启动完成${RESET}"
    show_access_info "$HOST_PORT"
    pause
}

stop_container() {
    if docker ps -q -f name=$CONTAINER_NAME; then
        docker stop "$CONTAINER_NAME"
        echo -e "${GREEN}容器已停止${RESET}"
    else
        echo -e "${RED}容器未运行${RESET}"
    fi
    pause
}

restart_container() {
    if docker ps -q -f name=$CONTAINER_NAME; then
        docker restart "$CONTAINER_NAME"
        echo -e "${GREEN}容器已重启${RESET}"
    else
        echo -e "${RED}容器未运行，直接启动...${RESET}"
        start_container
    fi
    pause
}

status_container() {
    docker ps -a --filter "name=$CONTAINER_NAME"
    pause
}

logs_container() {
    if docker ps -q -f name=$CONTAINER_NAME; then
        docker logs -f "$CONTAINER_NAME"
    else
        echo -e "${RED}容器未运行${RESET}"
    fi
    pause
}

delete_container() {
    if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
        docker rm -f "$CONTAINER_NAME"
        echo -e "${GREEN}容器已删除${RESET}"
    else
        echo -e "${RED}容器不存在${RESET}"
    fi
    pause
}

update_and_restart_container() {
    echo -e "${YELLOW}正在拉取最新镜像: $IMAGE_NAME ...${RESET}"
    docker pull "$IMAGE_NAME"
    if [ "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
        echo -e "${YELLOW}镜像更新完成，正在重启容器...${RESET}"
        docker restart "$CONTAINER_NAME"
        echo -e "${GREEN}容器已重启${RESET}"
        # 获取原端口
        HOST_PORT=$(docker port "$CONTAINER_NAME" $CONTAINER_PORT | cut -d: -f2)
        show_access_info "$HOST_PORT"
    else
        echo -e "${RED}容器未运行，启动新容器...${RESET}"
        start_container
    fi
    pause
}

# ================== 主循环 ==================
while true; do
    print_menu
    read -rp "请选择操作: " choice
    case $choice in
        1) start_container ;;
        2) stop_container ;;
        3) restart_container ;;
        4) status_container ;;
        5) logs_container ;;
        6) delete_container ;;
        7) update_and_restart_container ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}"; pause ;;
    esac
done
