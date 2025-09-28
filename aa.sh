#!/bin/bash
set -e

# ================== 配置 ==================
IMAGE="ghcr.io/sky22333/hubproxy"
CONTAINER="hubproxy"
INSTALL_DIR="/opt/hubproxy"
DEFAULT_PORT=5000

# ================== 颜色 ==================
GREEN="\033[32m"
RESET="\033[0m"

# ================== 公共函数 ==================
get_ip() {
    ip addr show | awk '/inet / && !/127.0.0.1/ {print $2}' | cut -d/ -f1 | head -n1
}

pause() {
    echo
    read -p "按回车返回菜单..."
}

# ================== 功能函数 ==================
deploy() {
    mkdir -p "$INSTALL_DIR"
    read -p "请输入映射端口(默认:${DEFAULT_PORT}): " port
    port=${port:-$DEFAULT_PORT}

    echo -e "${GREEN}>>> 正在部署 hubproxy 到 $INSTALL_DIR ...${RESET}"
    docker run -d --name $CONTAINER \
        -v $INSTALL_DIR:/app/data \
        -p 127.0.0.1:$port:5000 \
        --restart always \
        $IMAGE

    echo -e "${GREEN}hubproxy 已部署完成！访问: http://127.0.0.1:${port}${RESET}"
    pause
}

start() {
    docker start $CONTAINER && echo -e "${GREEN}hubproxy 已启动${RESET}"
    pause
}

stop() {
    docker stop $CONTAINER && echo -e "${GREEN}hubproxy 已停止${RESET}"
    pause
}

restart() {
    docker restart $CONTAINER && echo -e "${GREEN}hubproxy 已重启${RESET}"
    pause
}

status() {
    docker ps -a | grep $CONTAINER || echo -e "${GREEN}容器不存在${RESET}"
    pause
}

logs() {
    docker logs -f $CONTAINER
    pause
}

enter() {
    docker exec -it $CONTAINER /bin/sh
    pause
}

remove() {
    stop
    docker rm -f $CONTAINER 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    echo -e "${GREEN}hubproxy 容器及数据已删除${RESET}"
    pause
}

update() {
    echo -e "${GREEN}>>> 拉取最新镜像...${RESET}"
    docker pull $IMAGE

    echo -e "${GREEN}>>> 删除旧容器并重新创建...${RESET}"
    local port=$(docker inspect --format='{{(index (index .HostConfig.PortBindings "5000/tcp") 0).HostPort}}' $CONTAINER 2>/dev/null || echo $DEFAULT_PORT)

    remove >/dev/null 2>&1

    mkdir -p "$INSTALL_DIR"
    docker run -d --name $CONTAINER \
        -v $INSTALL_DIR:/app/data \
        -p 127.0.0.1:$port:5000 \
        --restart always \
        $IMAGE

    echo -e "${GREEN}hubproxy 已更新并重启完成！访问: http://127.0.0.1:${port}${RESET}"
    pause
}

# ================== 菜单 ==================
menu() {
    echo -e "${GREEN} HubProxy 容器管理 ${RESET}"
    echo -e "${GREEN}1. 部署 ${RESET}"
    echo -e "${GREEN}2. 启动${RESET}"
    echo -e "${GREEN}3. 停止${RESET}"
    echo -e "${GREEN}4. 重启${RESET}"
    echo -e "${GREEN}5. 查看状态${RESET}"
    echo -e "${GREEN}6. 查看日志${RESET}"
    echo -e "${GREEN}7. 进入容器${RESET}"
    echo -e "${GREEN}8. 删除容器及数据${RESET}"
    echo -e "${GREEN}9. 更新容器${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "==================================="

    read -p "请输入选项: " opt
    case $opt in
        1) deploy ;;
        2) start ;;
        3) stop ;;
        4) restart ;;
        5) status ;;
        6) logs ;;
        7) enter ;;
        8) remove ;;
        9) update ;;
        0) exit 0 ;;
        *) echo "无效选项"; pause ;;
    esac
    menu
}

menu
