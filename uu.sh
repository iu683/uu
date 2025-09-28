#!/bin/bash
# =========================================
# STB Docker 管理脚本（菜单式增强版）
# 功能：
# 1. 自定义端口
# 2. 设置 VITE_APP_TITLE
# 3. 启动 / 停止 / 重启 / 查看日志
# 4. 更新镜像
# 5. 自动挂载数据卷
# =========================================

APP_NAME="stb_app"
IMAGE_NAME="setube/stb:latest"
CONTAINER_NAME="stb_container"
DATA_DIR="/root/stb_data"
CONTAINER_PORT=25519

GREEN="\033[32m"
RESET="\033[0m"

DEFAULT_PORT=25519
DEFAULT_TITLE="STB图床"

# ---------- 菜单 ----------
menu() {
    clear
    echo -e "${GREEN}====== STB Docker 管理脚本 ======${RESET}"
    echo -e "${GREEN}1) 启动容器${RESET}"
    echo -e "${GREEN}2) 停止容器${RESET}"
    echo -e "${GREEN}3) 重启容器${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 更新${RESET}"
    echo -e "${GREEN}6) 退出${RESET}"
    echo -ne "${GREEN}请选择操作 [1-6]: ${RESET}"
    read choice
    case $choice in
        1) start_container ;;
        2) stop_container ;;
        3) restart_container ;;
        4) view_logs ;;
        5) update_image ;;
        6) exit 0 ;;
        *) echo -e "${GREEN}输入错误！${RESET}"; sleep 1; menu ;;
    esac
}

# ---------- 启动容器 ----------
start_container() {
    echo -ne "${GREEN}请输入宿主机端口（默认 $DEFAULT_PORT）: ${RESET}"
    read HOST_PORT
    HOST_PORT=${HOST_PORT:-$DEFAULT_PORT}

    echo -ne "${GREEN}请输入网站标题（默认 $DEFAULT_TITLE）: ${RESET}"
    read SITE_TITLE
    SITE_TITLE=${SITE_TITLE:-$DEFAULT_TITLE}

    # 创建数据目录
    mkdir -p $DATA_DIR

    if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
        echo -e "${GREEN}容器已存在，尝试启动...${RESET}"
        docker start $CONTAINER_NAME
    else
        echo -e "${GREEN}启动新容器...${RESET}"
        docker run -d --name $CONTAINER_NAME -p $HOST_PORT:$CONTAINER_PORT \
            -v $DATA_DIR:/app/data \
            -e VITE_APP_TITLE="$SITE_TITLE" \
            $IMAGE_NAME
    fi

    echo -e "${GREEN}容器已启动，访问端口: $HOST_PORT${RESET}"
    read -n1 -r -p "按任意键返回菜单..."
    menu
}

# ---------- 停止容器 ----------
stop_container() {
    docker stop $CONTAINER_NAME && echo -e "${GREEN}容器已停止${RESET}"
    read -n1 -r -p "按任意键返回菜单..."
    menu
}

# ---------- 重启容器 ----------
restart_container() {
    docker restart $CONTAINER_NAME && echo -e "${GREEN}容器已重启${RESET}"
    read -n1 -r -p "按任意键返回菜单..."
    menu
}

# ---------- 查看日志 ----------
view_logs() {
    docker logs -f $CONTAINER_NAME
    menu
}

# ---------- 更新镜像 ----------
update_image() {
    echo -e "${GREEN}拉取最新镜像...${RESET}"
    docker pull $IMAGE_NAME

    if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
        echo -e "${GREEN}删除旧容器...${RESET}"
        docker stop $CONTAINER_NAME
        docker rm $CONTAINER_NAME
    fi

    echo -e "${GREEN}重启容器...${RESET}"
    start_container
}

# ---------- 循环菜单 ----------
while true; do
    menu
done
