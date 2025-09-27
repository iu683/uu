#!/bin/bash

WORKDIR="$HOME/docker_data/sun-panel"
CONTAINER_NAME="sun-panel"
IMAGE_NAME="hslr/sun-panel:latest"
CONFIG_FILE="$WORKDIR/port.conf"

# 如果没有保存端口，就提示输入
if [[ -f "$CONFIG_FILE" ]]; then
    PORT=$(cat "$CONFIG_FILE")
else
    read -p "请输入映射端口 (默认 3002): " input_port
    PORT=${input_port:-3002}
    mkdir -p "$WORKDIR"
    echo "$PORT" > "$CONFIG_FILE"
fi

mkdir -p "$WORKDIR/conf"

get_public_ip() {
    IP=$(curl -s https://ifconfig.me)
    if ! [[ $IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        IP="服务器IP"
    fi
    echo "$IP"
}

# ========== 颜色 ==========
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

show_menu() {
    echo -e "${GREEN}===== Sun Panel 管理菜单 =====${RESET}"
    echo -e "${GREEN}1. 启动 Sun Panel${RESET}"
    echo -e "${GREEN}2. 停止 Sun Panel${RESET}"
    echo -e "${GREEN}3. 更新 Sun Panel${RESET}"
    echo -e "${GREEN}4. 查看日志${RESET}"
    echo -e "${GREEN}5. 卸载 Sun Panel${RESET}"
    echo -e "${GREEN}6. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
}

while true; do
    show_menu
    echo -ne "${YELLOW}请选择操作 [1-6]: ${RESET}"
    read -r choice
    case $choice in
        1)
            echo -e "${GREEN}启动 Sun Panel...${RESET}"
            docker run -d --restart=always \
                -p 0.0.0.0:$PORT:$PORT \
                -v "$WORKDIR/conf":/app/conf \
                -v /var/run/docker.sock:/var/run/docker.sock \
                --name $CONTAINER_NAME \
                $IMAGE_NAME
            echo -e "${GREEN}Sun Panel 已启动${RESET}"

            IP=$(get_public_ip)
            echo -e "${GREEN}访问地址：http://$IP:$PORT${RESET}"
            ;;
        2)
            echo -e "${GREEN}停止 Sun Panel...${RESET}"
            docker stop $CONTAINER_NAME
            ;;
        3)
            echo -e "${GREEN}更新 Sun Panel...${RESET}"
            docker stop $CONTAINER_NAME
            docker rm $CONTAINER_NAME
            docker pull $IMAGE_NAME
            docker run -d --restart=always \
                -p 0.0.0.0:$PORT:$PORT \
                -v "$WORKDIR/conf":/app/conf \
                -v /var/run/docker.sock:/var/run/docker.sock \
                --name $CONTAINER_NAME \
                $IMAGE_NAME
            echo -e "${GREEN}Sun Panel 已更新并启动${RESET}"

            IP=$(get_public_ip)
            echo -e "${GREEN}访问地址：http://$IP:$PORT${RESET}"
            ;;
        4)
            echo -e "${GREEN}查看日志（Ctrl+C 退出）${RESET}"
            docker logs -f $CONTAINER_NAME
            ;;
        5)
            echo -ne "${YELLOW}确认卸载 Sun Panel 并删除数据吗？[y/N]: ${RESET}"
            read -r confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                docker stop $CONTAINER_NAME
                docker rm $CONTAINER_NAME
                rm -rf "$WORKDIR"
                echo -e "${GREEN}Sun Panel 已卸载${RESET}"
                exit 0
            fi
            ;;
        6)
            echo -e "${YELLOW}退出脚本${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            ;;
    esac
done
