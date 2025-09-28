#!/bin/bash
# EmbyServer 一键部署与更新菜单脚本（绿色菜单、官方镜像、强制root、GPU加速、显示公网IP）

GREEN='\033[0;32m'
RESET='\033[0m'

DEFAULT_CONTAINER_NAME="emby"
DEFAULT_DATA_DIR="/opt/emby"
DEFAULT_HTTP_PORT="8096"
IMAGE_NAME="emby/embyserver:latest"
CONFIG_FILE="$HOME/.emby_config"

CONTAINER_NAME=""
DATA_DIR=""
HTTP_PORT=""

# 检查 Docker 是否安装
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${GREEN}错误: Docker 未安装，请先安装 Docker${RESET}"
        exit 1
    fi
}

# 检测 CPU 架构，自动选择镜像（更稳健）
get_arch() {
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            IMAGE_NAME="emby/embyserver:latest"
            ;;
        aarch64|arm64|armv8l)
            IMAGE_NAME="emby/embyserver_arm64v8:latest"
            ;;
        armv7l|armv7)
            # 如果你的平台是 32-bit arm (如部分旧树莓派)，可以尝试这个镜像（视镜像仓库是否存在）
            IMAGE_NAME="emby/embyserver_arm32v7:latest"
            ;;
        *)
            IMAGE_NAME="emby/embyserver:latest"
            echo -e "${GREEN}未知架构: $arch，已使用默认 amd64 镜像：$IMAGE_NAME${RESET}"
            ;;
    esac
    echo -e "${GREEN}检测到架构: $arch，使用镜像: $IMAGE_NAME${RESET}"
}

# 获取公网 IP
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

# 读取或输入配置
load_or_input_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi

    read -p "请输入容器名 [${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}]: " input_container
    CONTAINER_NAME=${input_container:-${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}}

    read -p "请输入统一存放目录（配置+媒体） [${DATA_DIR:-$DEFAULT_DATA_DIR}]: " input_dir
    DATA_DIR=${input_dir:-${DATA_DIR:-$DEFAULT_DATA_DIR}}

    read -p "请输入宿主机 HTTP 映射端口 [${HTTP_PORT:-$DEFAULT_HTTP_PORT}]: " input_port
    HTTP_PORT=${input_port:-${HTTP_PORT:-$DEFAULT_HTTP_PORT}}

    # 保存当前配置
    echo "CONTAINER_NAME=\"$CONTAINER_NAME\"" > "$CONFIG_FILE"
    echo "DATA_DIR=\"$DATA_DIR\"" >> "$CONFIG_FILE"
    echo "HTTP_PORT=\"$HTTP_PORT\"" >> "$CONFIG_FILE"
}

# 创建数据目录
create_dirs() {
    mkdir -p "$DATA_DIR/config" "$DATA_DIR/media"
    echo -e "${GREEN}目录已创建: $DATA_DIR${RESET}"
    chmod -R 755 "$DATA_DIR"
}

# 判断 GPU 是否可用
gpu_args() {
    if [ -d /dev/dri ]; then
        echo "--device /dev/dri:/dev/dri"
    else
        echo ""
    fi
}

# 部署 EmbyServer（已确保先检测架构）
deploy_emby() {
    load_or_input_config
    create_dirs
    get_arch
    echo -e "${GREEN}正在部署 EmbyServer 容器（镜像: $IMAGE_NAME）...${RESET}"

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
        -v $DATA_DIR/media:/mnt/share1 \
        $(gpu_args) \
        $IMAGE_NAME

    PUBLIC_IP=$(get_public_ip)
    if [ -n "$PUBLIC_IP" ]; then
        echo -e "${GREEN}部署完成！公网访问地址: http://127.0.0.1:${HTTP_PORT}${RESET}"
    else
        echo -e "${GREEN}部署完成公网访问地址: http://127.0.0.1:${HTTP_PORT}${RESET}"
    fi
}

# 启动、停止、删除、查看日志
start_emby() { docker start $CONTAINER_NAME && echo -e "${GREEN}容器已启动${RESET}"; }
stop_emby() { docker stop $CONTAINER_NAME && echo -e "${GREEN}容器已停止${RESET}"; }
remove_emby() { docker rm -f $CONTAINER_NAME && echo -e "${GREEN}容器已删除${RESET}"; }
view_logs() { docker logs -f $CONTAINER_NAME; }

# 卸载所有数据
uninstall_all() {
    stop_emby
    remove_emby
    if [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR" ]; then
        read -p "确定要删除 $DATA_DIR 吗？此操作不可恢复 [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -rf "$DATA_DIR"
            echo -e "${GREEN}数据目录已删除${RESET}"
        fi
    fi
    [ -f "$CONFIG_FILE" ] && rm -f "$CONFIG_FILE" && echo -e "${GREEN}配置文件已删除${RESET}"
}

# 更新镜像并重启容器（也会先检测架构）
update_image() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        echo -e "${GREEN}配置文件不存在，请先部署容器${RESET}"
        exit 1
    fi

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
        --restart unless-stopped \
        -e TZ=Asia/Shanghai \
        -e UID=0 \
        -e GID=0 \
        -e GIDLIST=0 \
        -p 127.0.0.1:$HTTP_PORT:8096 \
        -p 8920:8920 \
        -v $DATA_DIR/config:/config \
        -v $DATA_DIR/media:/mnt/share1 \
        $(gpu_args) \
        $IMAGE_NAME

    PUBLIC_IP=$(get_public_ip)
    if [ -n "$PUBLIC_IP" ]; then
        echo -e "${GREEN}更新完成${RESET}"
    else
        echo -e "${GREEN}更新完成${RESET}"
    fi
}

# 显示菜单
show_menu() {
    echo -e "${GREEN}===== EMBY菜单 =====${RESET}"
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

# 主循环
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
