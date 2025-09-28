#!/bin/bash
# Jellyfin 一键部署与更新菜单脚本（统一 /opt/jellyfin，循环菜单版）

GREEN='\033[0;32m'
RESET='\033[0m'

DEFAULT_CONTAINER_NAME="jellyfin"
DEFAULT_DATA_DIR="/opt/jellyfin"
DEFAULT_HTTP_PORT="8096"
IMAGE_NAME="jellyfin/jellyfin:latest"
CONFIG_FILE="$DEFAULT_DATA_DIR/config.env"

CONTAINER_NAME=""
DATA_DIR=""
HTTP_PORT=""

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${GREEN}错误: Docker 未安装，请先安装 Docker${RESET}"
        exit 1
    fi
}

get_public_ip() {
    PUBLIC_IP=$(curl -s https://ipinfo.io/ip)
    if ! [[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        PUBLIC_IP=$(curl -s https://ifconfig.me/ip)
    fi
    [[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || PUBLIC_IP=""
    echo "$PUBLIC_IP"
}

load_or_input_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi

    read -p "请输入容器名 [${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}]: " input_container
    CONTAINER_NAME=${input_container:-${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}}

    DATA_DIR="$DEFAULT_DATA_DIR"

    read -p "请输入宿主机 HTTP 映射端口 [${HTTP_PORT:-$DEFAULT_HTTP_PORT}]: " input_port
    HTTP_PORT=${input_port:-${HTTP_PORT:-$DEFAULT_HTTP_PORT}}

    mkdir -p "$(dirname $CONFIG_FILE)"
    {
        echo "CONTAINER_NAME=\"$CONTAINER_NAME\""
        echo "DATA_DIR=\"$DATA_DIR\""
        echo "HTTP_PORT=\"$HTTP_PORT\""
    } > "$CONFIG_FILE"
}

create_dirs() {
    mkdir -p "$DATA_DIR/config" "$DATA_DIR/cache" "$DATA_DIR/media"
    chmod -R 755 "$DATA_DIR"
    echo -e "${GREEN}已创建数据目录: $DATA_DIR${RESET}"
}

deploy_jellyfin() {
    load_or_input_config
    create_dirs
    echo -e "${GREEN}正在部署 Jellyfin 容器...${RESET}"

    docker run -d \
        --name $CONTAINER_NAME \
        --restart unless-stopped \
        -e TZ=Asia/Shanghai \
        -e UID=0 \
        -e GID=0 \
        -e GIDLIST=0 \
        -p 127.0.0.1:$HTTP_PORT:8096 \
        -p 8920:8920 \
        -v $DATA_DIR/config:/config \
        -v $DATA_DIR/cache:/cache \
        -v $DATA_DIR/media:/media \
        $IMAGE_NAME

    PUBLIC_IP=$(get_public_ip)
    echo -e "${GREEN}部署完成！访问地址: http://127.0.0.1:${HTTP_PORT}${RESET}"
    read -p "按回车返回菜单..."
}

start_jellyfin() {
    docker start $CONTAINER_NAME && echo -e "${GREEN}容器已启动${RESET}"
    read -p "按回车返回菜单..."
}
stop_jellyfin() {
    docker stop $CONTAINER_NAME && echo -e "${GREEN}容器已停止${RESET}"
    read -p "按回车返回菜单..."
}
remove_jellyfin() {
    docker rm -f $CONTAINER_NAME && echo -e "${GREEN}容器已删除${RESET}"
}
view_logs() {
    docker logs -f $CONTAINER_NAME
}

uninstall_all() {
    docker stop $CONTAINER_NAME
    remove_jellyfin
    if [ -d "$DEFAULT_DATA_DIR" ]; then
        read -p "确定要删除 $DEFAULT_DATA_DIR 吗？此操作不可恢复 [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -rf "$DEFAULT_DATA_DIR"
            echo -e "${GREEN}数据和配置已删除${RESET}"
        fi
    fi
    read -p "按回车返回菜单..."
}

update_image() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        echo -e "${GREEN}配置文件不存在，请先部署容器${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    echo -e "${GREEN}正在拉取最新镜像: $IMAGE_NAME ...${RESET}"
    docker pull $IMAGE_NAME

    if [ "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
        echo -e "${GREEN}停止正在运行的容器...${RESET}"
        docker stop $CONTAINER_NAME
    fi

    if [ "$(docker ps -a -q -f name=$CONTAINER_NAME)" ]; then
        echo -e "${GREEN}删除旧容器（保留数据）...${RESET}"
        docker rm $CONTAINER_NAME
    fi

    echo -e "${GREEN}使用最新镜像重启容器...${RESET}"
    docker run -d \
        --name $CONTAINER_NAME \
        --restart unless-stopped \
        -e TZ=Asia/Shanghai \
        -e UID=0 \
        -e GID=0 \
        -e GIDLIST=0 \
        -p 127.0.0.1:$HTTP_PORT:8096 \
        -p 8920:8920 \
        -v $DATA_DIR/config:/config \
        -v $DATA_DIR/cache:/cache \
        -v $DATA_DIR/media:/media \
        $IMAGE_NAME

    echo -e "${GREEN}更新完成${RESET}"
    read -p "按回车返回菜单..."
}

show_menu() {
    echo -e "${GREEN}===== Jellyfin 菜单 =====${RESET}"
    echo -e "${GREEN}1. 部署${RESET}"
    echo -e "${GREEN}2. 启动容器${RESET}"
    echo -e "${GREEN}3. 停止容器${RESET}"
    echo -e "${GREEN}4. 查看日志${RESET}"
    echo -e "${GREEN}5. 卸载${RESET}"
    echo -e "${GREEN}6. 更新${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -n "请输入编号: "
}

check_docker

while true; do
    show_menu
    read choice
    case $choice in
        1) deploy_jellyfin ;;
        2) start_jellyfin ;;
        3) stop_jellyfin ;;
        4) view_logs ;;
        5) uninstall_all ;;
        6) update_image ;;
        0) echo "退出脚本"; exit 0 ;;
        *) echo -e "${GREEN}无效选项${RESET}"; read -p "按回车返回菜单..." ;;
    esac
done
