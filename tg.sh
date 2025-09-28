#!/bin/bash
# EmbyServer 一键部署与更新菜单脚本
# 宿主机目录: /docker/emby 映射到容器 /config

GREEN='\033[0;32m'
RESET='\033[0m'

DEFAULT_CONTAINER_NAME="amilys_embyserver"
DEFAULT_DATA_DIR="/opt/emby"
DEFAULT_HTTP_PORT="8096"

CONTAINER_NAME=""
DATA_DIR=""
HTTP_PORT=""
IMAGE_NAME=""
CONFIG_FILE="$DEFAULT_DATA_DIR/emby_config"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${GREEN}错误: Docker 未安装，请先安装 Docker${RESET}"
        exit 1
    fi
}

# 检测 CPU 架构，自动选择镜像
get_arch() {
    arch=$(uname -m)
    case "$arch" in
        x86_64)   IMAGE_NAME="amilys/embyserver" ;;
        aarch64|arm64) IMAGE_NAME="amilys/embyserver_arm64v8" ;;
        *) echo -e "${GREEN}未知架构: $arch，默认使用 amd64 镜像${RESET}"
           IMAGE_NAME="amilys/embyserver" ;;
    esac
}

get_public_ip() {
    PUBLIC_IP=$(curl -s https://ipinfo.io/ip)
    if ! [[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        PUBLIC_IP=$(curl -s https://ifconfig.me/ip)
    fi
    if ! [[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        PUBLIC_IP=""
    fi
    echo "$PUBLIC_IP"
}

load_or_input_config() {
    # 配置文件存在就直接加载，否则第一次部署提示输入
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        read -p "请输入容器名 [${DEFAULT_CONTAINER_NAME}]: " input_container
        CONTAINER_NAME=${input_container:-$DEFAULT_CONTAINER_NAME}

        read -p "请输入存放配置目录（宿主机） [${DEFAULT_DATA_DIR}]: " input_dir
        DATA_DIR=${input_dir:-$DEFAULT_DATA_DIR}

        read -p "请输入宿主机 HTTP 映射端口 [${DEFAULT_HTTP_PORT}]: " input_port
        HTTP_PORT=${input_port:-$DEFAULT_HTTP_PORT}

        mkdir -p "$(dirname "$CONFIG_FILE")"
        {
            echo "CONTAINER_NAME=\"$CONTAINER_NAME\""
            echo "DATA_DIR=\"$DATA_DIR\""
            echo "HTTP_PORT=\"$HTTP_PORT\""
        } > "$CONFIG_FILE"
    fi
}

create_dirs() {
    [ ! -d "$DATA_DIR" ] && mkdir -p "$DATA_DIR"
}

deploy_emby() {
    load_or_input_config
    create_dirs
    get_arch
    echo -e "${GREEN}正在部署 EmbyServer 容器（镜像: $IMAGE_NAME）...${RESET}"
    docker run -d \
        --name $CONTAINER_NAME \
        --network bridge \
        -e UID=0 \
        -e GID=0 \
        -e GIDLIST=0 \
        -e TZ=Asia/Shanghai \
        -v $DATA_DIR:/config \
        -p 127.0.0.1:$HTTP_PORT:8096 \
        --restart unless-stopped \
        $IMAGE_NAME

    PUBLIC_IP=$(get_public_ip)
    echo -e "${GREEN}部署完成 访问地址: http://127.0.0.1:${HTTP_PORT}${RESET}"
}

start_emby() { load_or_input_config; docker start $CONTAINER_NAME && echo -e "${GREEN}容器已启动${RESET}"; }
stop_emby() { load_or_input_config; docker stop $CONTAINER_NAME && echo -e "${GREEN}容器已停止${RESET}"; }
remove_emby() { load_or_input_config; docker rm -f $CONTAINER_NAME && echo -e "${GREEN}容器已删除${RESET}"; }
view_logs() { load_or_input_config; docker logs -f $CONTAINER_NAME; }

uninstall_all() {
    load_or_input_config
    stop_emby
    remove_emby
    if [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR" ]; then
        echo -e "${GREEN}正在删除配置目录: $DATA_DIR ...${RESET}"
        rm -rf "$DATA_DIR"
        echo -e "${GREEN}全部数据已卸载完成${RESET}"
    fi
    [ -f "$CONFIG_FILE" ] && rm -f "$CONFIG_FILE"
    echo -e "${GREEN}配置文件已删除（位于 $CONFIG_FILE）${RESET}"
}

update_image() {
    load_or_input_config
    get_arch

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
        --network bridge \
        -e UID=0 \
        -e GID=0 \
        -e GIDLIST=0 \
        -e TZ=Asia/Shanghai \
        -v $DATA_DIR:/config \
        -p 127.0.0.1:$HTTP_PORT:8096 \
        --restart unless-stopped \
        $IMAGE_NAME

    echo -e "${GREEN}更新完成${RESET}"
}

show_menu() {
    echo -e "${GREEN}===== EmbyServer菜单 =====${RESET}"
    echo -e "${GREEN}1.部署${RESET}"
    echo -e "${GREEN}2.启动容器${RESET}"
    echo -e "${GREEN}3.停止容器${RESET}"
    echo -e "${GREEN}4.删除容器${RESET}"
    echo -e "${GREEN}5.查看日志${RESET}"
    echo -e "${GREEN}6.卸载${RESET}"
    echo -e "${GREEN}7.更新${RESET}"
    echo -e "${GREEN}0.退出${RESET}"
    echo -n "请输入编号: "
}

check_docker

while true; do
    show_menu
    read choice
    case $choice in
        1) deploy_emby ;;
        2) start_emby ;;
        3) stop_emby ;;
        4) remove_emby ;;
        5) view_logs ;;
        6) uninstall_all ;;
        7) update_image ;;
        0) echo "退出脚本"; exit 0 ;;
        *) echo -e "${GREEN}无效选项${RESET}" ;;
    esac
done
