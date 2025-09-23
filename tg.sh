#!/bin/bash
# Telegram Monitor Docker 一键管理脚本（智能端口和数据目录）

CONTAINER_NAME="telegram-monitor"
IMAGE="ghcr.io/riniba/telegrammonitor:latest"

GREEN="\e[32m"
RED="\e[31m"
RESET="\e[0m"

# 检查 Docker 是否安装
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}Docker 未安装，请先安装 Docker${RESET}"
        exit 1
    fi
}

# 获取容器端口和数据目录
get_container_info() {
    if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
        PORT=$(docker inspect $CONTAINER_NAME --format '{{(index (index .NetworkSettings.Ports "5005/tcp") 0).HostPort}}')
        DATA_DIR=$(docker inspect $CONTAINER_NAME --format '{{range .Mounts}}{{if eq .Destination "/app"}}{{.Source}}{{end}}{{end}}')
    else
        PORT=""
        DATA_DIR=""
    fi
}

# 安装/启动容器
install_container() {
    get_container_info
    if [ -n "$PORT" ] && [ -n "$DATA_DIR" ]; then
        echo -e "${GREEN}容器已存在，启动中...${RESET}"
        docker start $CONTAINER_NAME
    else
        read -p "请输入本地映射端口（默认5005）: " PORT
        PORT=${PORT:-5005}
        read -p "请输入数据存储目录（默认./data）: " DATA_DIR
        DATA_DIR=${DATA_DIR:-./data}

        echo -e "${GREEN}创建并启动容器...${RESET}"
        mkdir -p "$DATA_DIR"
        docker run -d \
            --name $CONTAINER_NAME \
            --restart unless-stopped \
            -p $PORT:5005 \
            -v "$DATA_DIR":/app \
            -e ASPNETCORE_ENVIRONMENT=Production \
            $IMAGE
    fi
}

# 停止容器
stop_container() {
    if [ "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
        echo -e "${GREEN}停止容器...${RESET}"
        docker stop $CONTAINER_NAME
    else
        echo -e "${RED}容器未运行${RESET}"
    fi
}

# 重启容器
restart_container() {
    echo -e "${GREEN}重启容器...${RESET}"
    docker restart $CONTAINER_NAME
}

# 更新镜像并重启
update_container() {
    get_container_info
    echo -e "${GREEN}拉取最新镜像...${RESET}"
    docker pull $IMAGE

    if [ -n "$PORT" ] && [ -n "$DATA_DIR" ]; then
        echo -e "${GREEN}删除旧容器并启动新容器（保留原端口和数据目录）...${RESET}"
        docker rm -f $CONTAINER_NAME
        docker run -d \
            --name $CONTAINER_NAME \
            --restart unless-stopped \
            -p $PORT:5005 \
            -v "$DATA_DIR":/app \
            -e ASPNETCORE_ENVIRONMENT=Production \
            $IMAGE
    else
        echo -e "${GREEN}容器不存在，执行安装流程...${RESET}"
        install_container
    fi
}

# 查看日志
logs_container() {
    echo -e "${GREEN}查看容器日志（按 Ctrl+C 退出）...${RESET}"
    docker logs -f $CONTAINER_NAME
}

# 卸载容器
uninstall_container() {
    echo -e "${RED}停止并删除容器...${RESET}"
    docker rm -f $CONTAINER_NAME
    echo -e "${GREEN}卸载完成${RESET}"
}

# 菜单
while true; do
    echo -e "\n${GREEN}======================${RESET}"
    echo -e "${GREEN}=== Telegram Monitor 管理菜单 ===${RESET}"
    echo -e "${GREEN}======================${RESET}"
    echo -e "${GREEN}1) 安装/启动容器${RESET}"
    echo -e "${GREEN}2) 停止容器${RESET}"
    echo -e "${GREEN}3) 重启容器${RESET}"
    echo -e "${GREEN}4) 更新容器${RESET}"
    echo -e "${GREEN}5) 查看日志${RESET}"
    echo -e "${GREEN}6) 卸载容器${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "请选择操作: " choice
    case $choice in
        1) install_container ;;
        2) stop_container ;;
        3) restart_container ;;
        4) update_container ;;
        5) logs_container ;;
        6) uninstall_container ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
done
