#!/bin/bash
# ========================================
# xTrafficDash 一键部署 & 管理脚本（最终版）
# 作者: Linai Li
# ========================================

# ================== 颜色定义 ==================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# ================== 基本变量 ==================
APP_NAME="xtrafficdash"
DATA_DIR="/usr/xtrafficdash/data"
PORT=37022
PASSWORD="123456"
IMAGE="sanqi37/xtrafficdash"
TZ="Asia/Shanghai"
BACKUP_DIR="/usr/xtrafficdash/backup"

# ================== 检查 Docker ==================
if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}Docker 未安装，请先安装 Docker！${RESET}"
    exit 1
fi

# ================== 功能函数 ==================
create_data_dir() {
    if [ ! -d "$DATA_DIR" ]; then
        mkdir -p "$DATA_DIR"
        chmod 777 "$DATA_DIR"
        echo -e "${GREEN}数据目录已创建: $DATA_DIR${RESET}"
    fi
}

show_access_url() {
    HOST_IP=$(curl -s https://api.ipify.org)
    if [ -z "$HOST_IP" ]; then
        HOST_IP="本地IP或域名"
    fi
    echo -e "${GREEN}访问地址: http://${HOST_IP}:$PORT${RESET}"
}

start_container() {
    create_data_dir
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
    show_access_url
}

stop_container() {
    if [ "$(docker ps -q -f name=$APP_NAME)" ]; then
        docker stop $APP_NAME
        echo -e "${GREEN}容器已停止${RESET}"
    else
        echo -e "${YELLOW}容器未运行${RESET}"
    fi
}

restart_container() {
    stop_container
    start_container
}

view_logs() {
    if [ "$(docker ps -q -f name=$APP_NAME)" ]; then
        echo -e "${CYAN}显示最近 100 行日志：${RESET}"
        docker logs --tail 100 -f $APP_NAME
    else
        echo -e "${YELLOW}容器未运行${RESET}"
    fi
}

delete_container() {
    stop_container
    if [ "$(docker ps -aq -f name=$APP_NAME)" ]; then
        docker rm $APP_NAME
        echo -e "${GREEN}容器已删除${RESET}"
    else
        echo -e "${YELLOW}容器不存在${RESET}"
    fi
}

update_image() {
    echo -e "${CYAN}拉取最新镜像...${RESET}"
    docker pull $IMAGE
    echo -e "${GREEN}镜像更新完成${RESET}"
    
    echo -e "${YELLOW}备份当前数据...${RESET}"
    backup_data

    echo -e "${YELLOW}重启容器以应用新镜像...${RESET}"
    docker stop $APP_NAME
    docker rm $APP_NAME

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
}

backup_data() {
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
    fi
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BACKUP_FILE="$BACKUP_DIR/xtrafficdash_data_$TIMESTAMP.tar.gz"
    tar -czf $BACKUP_FILE -C $DATA_DIR .
    echo -e "${GREEN}数据已备份到: $BACKUP_FILE${RESET}"
}

modify_config() {
    echo -ne "${YELLOW}请输入新的访问端口（当前: $PORT）: ${RESET}"
    read new_port
    if [ -n "$new_port" ]; then
        PORT=$new_port
    fi
    echo -ne "${YELLOW}请输入新的访问密码（当前: $PASSWORD）: ${RESET}"
    read new_pass
    if [ -n "$new_pass" ]; then
        PASSWORD=$new_pass
    fi
    echo -e "${GREEN}配置已更新: 端口=$PORT, 密码=$PASSWORD${RESET}"
    restart_container
}

# ================== 菜单 ==================
while true; do
    echo -e "\n${GREEN}================ xTrafficDash 管理菜单 ================${RESET}"
    echo -e "${GREEN}1. 启动容器${RESET}"
    echo -e "${GREEN}2. 停止容器${RESET}"
    echo -e "${GREEN}3. 重启容器${RESET}"
    echo -e "${GREEN}4. 查看日志${RESET}"
    echo -e "${GREEN}5. 删除容器${RESET}"
    echo -e "${GREEN}6. 更新镜像并重启${RESET}"
    echo -e "${GREEN}7. 备份数据${RESET}"
    echo -e "${GREEN}8. 修改端口和密码${RESET}"
    echo -e "${GREEN}0. 退出脚本${RESET}"
    echo -ne "${YELLOW}请输入选项 [0-8]: ${RESET}"
    read choice
    case $choice in
        1) start_container ;;
        2) stop_container ;;
        3) restart_container ;;
        4) view_logs ;;
        5) delete_container ;;
        6) update_image ;;
        7) backup_data ;;
        8) modify_config ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入！${RESET}" ;;
    esac
done
