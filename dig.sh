#!/bin/bash

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 容器配置
DOCKER_NAME="npm"
DOCKER_IMG="jc21/nginx-proxy-manager:latest"
DATA_PATH="/home/docker/npm/data"
CERT_PATH="/home/docker/npm/letsencrypt"
CONFIG_FILE="/home/docker/npm/config.conf"

# 获取公网 IP
get_public_ip() {
    local ip
    ip=$(curl -s ipv4.ip.sb)
    [[ -z "$ip" ]] && ip=$(curl -s ifconfig.me)
    [[ -z "$ip" ]] && ip=$(curl -s ipinfo.io/ip)
    if [[ -z "$ip" ]]; then
        echo -e "${RED}无法获取公网 IP${RESET}"
        return 1
    fi
    echo "$ip"
}

# ================== 初始化配置 ==================
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    read -p "请输入 NPM 面板端口 (默认 81): " input_port
    DOCKER_PORT=${input_port:-81}
    mkdir -p "$(dirname $CONFIG_FILE)"
    echo "DOCKER_PORT=$DOCKER_PORT" > "$CONFIG_FILE"
fi

# ================== 函数 ==================
docker_update_image() {
    echo -e "${GREEN}正在拉取最新 NPM 镜像...${RESET}"
    docker pull $DOCKER_IMG
}

docker_install() {
    # 检测端口是否被占用
    if lsof -i:$DOCKER_PORT -sTCP:LISTEN || lsof -i:80 -sTCP:LISTEN || lsof -i:443 -sTCP:LISTEN; then
        echo -e "${RED}⚠️ 端口 $DOCKER_PORT / 80 / 443 已被占用，请先释放端口再运行 NPM${RESET}"
        return 1
    fi

    mkdir -p "$DATA_PATH" "$CERT_PATH"
    docker_update_image

    if docker ps -a --format '{{.Names}}' | grep -q "^${DOCKER_NAME}$"; then
        echo -e "${YELLOW}检测到已有 NPM 容器，无法重复安装，请选择更新或启动${RESET}"
        return 1
    fi

    docker run -d \
      --name=$DOCKER_NAME \
      -p ${DOCKER_PORT}:81 \
      -p 80:80 \
      -p 443:443 \
      -v $DATA_PATH:/data \
      -v $CERT_PATH:/etc/letsencrypt \
      --restart=always \
      $DOCKER_IMG

    local ip=$(get_public_ip)
    echo -e "${GREEN}✅ Nginx Proxy Manager 已安装并启动${RESET}"
    echo -e "${GREEN}管理面板地址: http://${ip}:${DOCKER_PORT}${RESET}"
    echo -e "${GREEN}初始用户名: admin@example.com${RESET}"
    echo -e "${GREEN}初始密码: changeme${RESET}"
}

docker_update() {
    docker_update_image

    if docker ps -a --format '{{.Names}}' | grep -q "^${DOCKER_NAME}$"; then
        echo -e "${YELLOW}停止旧容器并删除（保留数据）...${RESET}"
        docker stop $DOCKER_NAME
        docker rm $DOCKER_NAME
    fi

    docker run -d \
      --name=$DOCKER_NAME \
      -p ${DOCKER_PORT}:81 \
      -p 80:80 \
      -p 443:443 \
      -v $DATA_PATH:/data \
      -v $CERT_PATH:/etc/letsencrypt \
      --restart=always \
      $DOCKER_IMG

    local ip=$(get_public_ip)
    echo -e "${GREEN}✅ NPM 已更新并重启${RESET}"
    echo -e "${GREEN}管理面板地址: http://${ip}:${DOCKER_PORT}${RESET}"
}

docker_remove() {
    docker rm -f $DOCKER_NAME 2>/dev/null
    echo -e "${GREEN}✅ NPM 已卸载${RESET}"
    # 删除数据
    rm -rf "$DATA_PATH" "$CERT_PATH" "$CONFIG_FILE"
    echo -e "${RED}数据目录已删除${RESET}"
}

docker_logs() {
    docker logs -f $DOCKER_NAME
}

docker_start() {
    docker start $DOCKER_NAME
}

docker_stop() {
    docker stop $DOCKER_NAME
}

docker_restart() {
    docker restart $DOCKER_NAME
}

# ================== 菜单 ==================
menu() {
    clear
    echo -e "${GREEN}=== Nginx Proxy Manager 一键管理菜单 ===${RESET}"
    echo -e "${GREEN}1. 安装 NPM${RESET}"
    echo -e "${GREEN}2. 更新 NPM 镜像并重启容器${RESET}"
    echo -e "${GREEN}3. 启动 NPM${RESET}"
    echo -e "${GREEN}4. 停止 NPM${RESET}"
    echo -e "${GREEN}5. 重启 NPM${RESET}"
    echo -e "${GREEN}6. 查看日志${RESET}"
    echo -e "${GREEN}7. 卸载 NPM（删除容器和数据）${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}=========================================${RESET}"
    read -p $'\033[32m请输入选项: \033[0m' choice

    case $choice in
        1) docker_install ;;
        2) docker_update ;;
        3) docker_start ;;
        4) docker_stop ;;
        5) docker_restart ;;
        6) docker_logs ;;
        7) docker_remove ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

# ================== 主循环 ==================
while true; do
    menu
    read -p $'\033[32m按回车返回菜单...\033[0m' foo
done
