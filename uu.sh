#!/bin/bash
# ==========================================
# XTrafficDash Docker 管理脚本
# ==========================================

set -e

# 颜色定义
GREEN="\033[32m"
RESET="\033[0m"

CONTAINER_NAME="xtrafficdash"
IMAGE_NAME="sanqi37/xtrafficdash"
DATA_DIR="/usr/xtrafficdash/data"
TIMEZONE="Asia/Shanghai"

# ================== 功能函数 ==================

get_public_ip() {
    # 尝试获取公网 IP
    IP=$(curl -s https://api.ip.sb/ip 2>/dev/null)
    if [[ -z "$IP" ]]; then
        read -p "无法自动获取公网 IP，请手动输入公网 IP: " IP
    fi
    echo "$IP"
}

show_access_url() {
    echo -e "${GREEN}访问地址: http://${1}:${2}${RESET}"
}

pause() {
    read -p "按回车返回菜单..."
}

install_xtrafficdash() {
    echo -e "${GREEN}🚀 安装 XTrafficDash${RESET}"

    if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
        echo -e "${GREEN}⚠️ 已检测到容器 $CONTAINER_NAME，请先卸载再安装${RESET}"
        pause
        return
    fi

    read -p "请输入访问端口 [默认 37022]: " HOST_PORT
    HOST_PORT=${HOST_PORT:-37022}

    read -p "请输入管理密码 [默认 admin123]: " PASSWORD
    PASSWORD=${PASSWORD:-admin123}

    echo -e "${GREEN}✅ 创建数据目录：$DATA_DIR${RESET}"
    mkdir -p "$DATA_DIR"
    chmod 777 "$DATA_DIR"

    echo -e "${GREEN}🚀 启动容器 $CONTAINER_NAME${RESET}"
    docker run -d \
      --name $CONTAINER_NAME \
      -p $HOST_PORT:$HOST_PORT \
      -v $DATA_DIR:/app/data \
      -e TZ=$TIMEZONE \
      -e PASSWORD=$PASSWORD \
      --log-opt max-size=5m \
      --log-opt max-file=3 \
      --restart unless-stopped \
      $IMAGE_NAME

    PUBLIC_IP=$(get_public_ip)
    show_access_url "$PUBLIC_IP" "$HOST_PORT"
    pause
}

update_xtrafficdash() {
    echo -e "${GREEN}🔄 更新 XTrafficDash${RESET}"

    if [ ! "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
        echo -e "${GREEN}⚠️ 未检测到容器 $CONTAINER_NAME，请先安装${RESET}"
        pause
        return
    fi

    CURRENT_PORT=$(docker inspect -f '{{(index (index .HostConfig.PortBindings "37022/tcp") 0).HostPort}}' $CONTAINER_NAME 2>/dev/null || echo "37022")
    CURRENT_PASS=$(docker inspect -f '{{range $k,$v := .Config.Env}}{{println $v}}{{end}}' $CONTAINER_NAME | grep PASSWORD | cut -d= -f2)

    read -p "请输入访问端口 [默认 $CURRENT_PORT]: " HOST_PORT
    HOST_PORT=${HOST_PORT:-$CURRENT_PORT}

    read -p "请输入管理密码 [默认 $CURRENT_PASS]: " PASSWORD
    PASSWORD=${PASSWORD:-$CURRENT_PASS}

    echo -e "${GREEN}⚠️ 删除旧容器...${RESET}"
    docker rm -f $CONTAINER_NAME

    echo -e "${GREEN}🚀 拉取最新镜像...${RESET}"
    docker pull $IMAGE_NAME

    echo -e "${GREEN}🚀 启动新容器...${RESET}"
    docker run -d \
      --name $CONTAINER_NAME \
      -p $HOST_PORT:$HOST_PORT \
      -v $DATA_DIR:/app/data \
      -e TZ=$TIMEZONE \
      -e PASSWORD=$PASSWORD \
      --log-opt max-size=5m \
      --log-opt max-file=3 \
      --restart unless-stopped \
      $IMAGE_NAME

    PUBLIC_IP=$(get_public_ip)
    show_access_url "$PUBLIC_IP" "$HOST_PORT"
    pause
}

uninstall() {
    echo -e "${GREEN}🗑 卸载 XTrafficDash${RESET}"
    if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
        docker rm -f $CONTAINER_NAME
        echo -e "${GREEN}✅ 容器已删除${RESET}"
    else
        echo -e "${GREEN}⚠️ 未检测到容器${RESET}"
    fi
    read -p "是否删除数据目录 $DATA_DIR ? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        rm -rf "$DATA_DIR"
        echo -e "${GREEN}✅ 数据目录已删除${RESET}"
    fi
    pause
}

view_logs() {
    if [ "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
        echo -e "${GREEN}📖 查看日志，按 Ctrl+C 退出${RESET}"
        docker logs -f $CONTAINER_NAME
    else
        echo -e "${GREEN}⚠️ 容器未运行${RESET}"
    fi
    pause
}

# ================== 菜单 ==================
while true; do
    echo
    echo -e "${GREEN}=== XTrafficDash 管理菜单 ===${RESET}"
    echo -e "${GREEN}[1] 安装 XTrafficDash${RESET}"
    echo -e "${GREEN}[2] 更新 XTrafficDash${RESET}"
    echo -e "${GREEN}[3] 卸载 XTrafficDash${RESET}"
    echo -e "${GREEN}[4] 查看日志${RESET}"
    echo -e "${GREEN}[0] 退出${RESET}"
    echo -e "${GREEN}=============================${RESET}"
    read -p "请选择操作 [0-4]: " choice
    case $choice in
        1) install_xtrafficdash ;;
        2) update_xtrafficdash ;;
        3) uninstall ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo -e "${GREEN}❌ 无效选项，请重新选择${RESET}" ;;
    esac
done
