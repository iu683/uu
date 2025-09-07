#!/bin/bash
# ==========================================
# XTrafficDash Docker 管理脚本
# ==========================================

set -e

# 颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

APP_NAME="xtrafficdash"
IMAGE="sanqi37/xtrafficdash"
DATA_DIR="/usr/xtrafficdash/data"
TZ="Asia/Shanghai"
PORT=37022
DEFAULT_PASSWORD="admin123"

pause() {
    read -p "按回车返回菜单..."
}

# ================== 功能函数 ==================

create_data_dir() {
    if [ ! -d "$DATA_DIR" ]; then
        mkdir -p "$DATA_DIR"
        chmod 777 "$DATA_DIR"
        echo -e "${GREEN}数据目录已创建: $DATA_DIR${RESET}"
    fi
}

read_password() {
    read -p "请输入管理密码 [默认 $DEFAULT_PASSWORD]: " PASSWORD
    PASSWORD=${PASSWORD:-$DEFAULT_PASSWORD}
}

start_container() {
    create_data_dir
    read_password
    if [ "$(docker ps -aq -f name=$APP_NAME)" ]; then
        echo -e "${YELLOW}容器已存在，尝试启动...${RESET}"
        docker start $APP_NAME
    else
        echo -e "${GREEN}启动新容器...${RESET}"
        docker run -d \
            --name $APP_NAME \
            -p $PORT:$PORT \
            -v $DATA_DIR:/app/data \
            -e TZ=$TZ \
            -e PASSWORD=$PASSWORD \
            --log-opt max-size=5m \
            --log-opt max-file=3 \
            --restart unless-stopped \
            $IMAGE
    fi
    echo -e "${GREEN}容器状态:${RESET}"
    docker ps -f name=$APP_NAME
    echo -e "${GREEN}✅ 容器已启动，访问地址: http://$(curl -s https://api.ipify.org):$PORT${RESET}"
    pause
}

view_logs() {
    if [ "$(docker ps -q -f name=$APP_NAME)" ]; then
        echo -e "${CYAN}显示最近 100 行日志，按 Ctrl+C 退出:${RESET}"
        docker logs --tail 100 -f $APP_NAME
    else
        echo -e "${YELLOW}容器未运行${RESET}"
    fi
    pause
}

delete_container() {
    if [ "$(docker ps -q -f name=$APP_NAME)" ]; then
        docker stop $APP_NAME
    fi
    if [ "$(docker ps -aq -f name=$APP_NAME)" ]; then
        docker rm $APP_NAME
        echo -e "${GREEN}容器已删除${RESET}"
    else
        echo -e "${YELLOW}容器不存在${RESET}"
    fi
    pause
}

update_image() {
    echo -e "${CYAN}拉取最新镜像...${RESET}"
    docker pull $IMAGE
    echo -e "${GREEN}镜像更新完成${RESET}"

    read_password

    echo -e "${YELLOW}重启容器以应用新镜像...${RESET}"
    docker stop $APP_NAME 2>/dev/null || true
    docker rm $APP_NAME 2>/dev/null || true

    docker run -d \
        --name $APP_NAME \
        -p $PORT:$PORT \
        -v $DATA_DIR:/app/data \
        -e TZ=$TZ \
        -e PASSWORD=$PASSWORD \
        --log-opt max-size=5m \
        --log-opt max-file=3 \
        --restart unless-stopped \
        $IMAGE

    echo -e "${GREEN}✅ 容器已更新并启动，访问地址: http://$(curl -s https://api.ipify.org):$PORT${RESET}"
    pause
}

# ================== 菜单 ==================
while true; do
    echo
    echo -e "${GREEN}=== XTrafficDash 管理菜单 ===${RESET}"
    echo -e "${GREEN}[1] 启动容器${RESET}"
    echo -e "${GREEN}[2] 删除容器${RESET}"
    echo -e "${GREEN}[3] 更新镜像并启动容器${RESET}"
    echo -e "${GREEN}[4] 查看日志${RESET}"
    echo -e "${GREEN}[0] 退出${RESET}"
    echo -e "${GREEN}=============================${RESET}"
    read -p "请选择操作 [0-4]: " choice
    case $choice in
        1) start_container ;;
        2) delete_container ;;
        3) update_image ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo -e "${YELLOW}无效选项，请重新选择${RESET}" ;;
    esac
done
