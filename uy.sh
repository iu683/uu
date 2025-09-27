#!/bin/bash

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

COMPOSE_DIR="/root/bepusdt"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
ENV_FILE="${COMPOSE_DIR}/bepusdt.env"
SERVICE_NAME="bepusdt"

# ================== 检查 root ==================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 用户运行此脚本！${RESET}"
    exit 1
fi

# ================== 函数 ==================

pause_return() {
    read -p "按回车返回菜单..."
}

load_config() {
    mkdir -p "$COMPOSE_DIR"
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    else
        read -p "请输入映射端口 [默认: 8080]: " input_port
        PORT=${input_port:-8080}

        read -p "请输入 conf.toml 配置文件路径 [默认: ${COMPOSE_DIR}/conf.toml]: " input_conf
        CONF_PATH=${input_conf:-${COMPOSE_DIR}/conf.toml}

        read -p "请输入数据目录路径 [默认: ${COMPOSE_DIR}/data]: " input_data
        DATA_PATH=${input_data:-${COMPOSE_DIR}/data}

        cat > "$ENV_FILE" <<EOF
PORT=$PORT
CONF_PATH=$CONF_PATH
DATA_PATH=$DATA_PATH
EOF
    fi
}

generate_compose() {
    load_config
    cat > "$COMPOSE_FILE" <<EOF
version: "3.8"

services:
  bepusdt:
    image: v03413/bepusdt:latest
    container_name: bepusdt
    restart: unless-stopped
    env_file:
      - bepusdt.env
    ports:
      - "\${PORT}:8080"
    volumes:
      - "\${CONF_PATH}:/usr/local/bepusdt/conf.toml"
      - "\${DATA_PATH}:/var/lib/bepusdt"
EOF
    echo -e "${GREEN}已生成 docker-compose.yml${RESET}"
}

start_container() {
    generate_compose
    cd "$COMPOSE_DIR"
    docker compose up -d
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}容器已启动成功！端口: $PORT${RESET}"
    else
        echo -e "${RED}容器启动失败，请检查配置！${RESET}"
    fi
    pause_return
}

stop_container() {
    cd "$COMPOSE_DIR"
    docker compose stop
    echo -e "${GREEN}容器已停止${RESET}"
    pause_return
}

restart_container() {
    cd "$COMPOSE_DIR"
    docker compose restart
    echo -e "${GREEN}容器已重启${RESET}"
    pause_return
}

remove_container() {
    cd "$COMPOSE_DIR"
    read -p "确认删除容器但保留数据和配置文件吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        docker compose down
        echo -e "${GREEN}容器已删除${RESET}"
    else
        echo "取消删除操作"
    fi
    pause_return
}

update_container() {
    generate_compose
    cd "$COMPOSE_DIR"
    echo -e "${GREEN}开始拉取最新镜像...${RESET}"
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}容器已更新并启动成功${RESET}"
    pause_return
}

logs_container() {
    cd "$COMPOSE_DIR"
    read -p "输入查看日志行数，默认显示最近 100 行: " LINES
    LINES=${LINES:-100}
    docker compose logs --tail $LINES ${SERVICE_NAME}
    pause_return
}

status_container() {
    docker ps -a --filter "name=${SERVICE_NAME}"
    pause_return
}

# ================== 菜单 ==================
while true; do
    echo -e "\n${GREEN}====== BEPUSDT 容器管理 ======${RESET}"
    echo -e "${GREEN}1) 启动容器${RESET}"
    echo -e "${GREEN}2) 停止容器${RESET}"
    echo -e "${GREEN}3) 重启容器${RESET}"
    echo -e "${GREEN}4) 删除容器${RESET}"
    echo -e "${GREEN}5) 查看状态${RESET}"
    echo -e "${GREEN}6) 更新容器${RESET}"
    echo -e "${GREEN}7) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "请选择操作: " choice

    case $choice in
        1) start_container ;;
        2) stop_container ;;
        3) restart_container ;;
        4) remove_container ;;
        5) status_container ;;
        6) update_container ;;
        7) logs_container ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择，返回菜单${RESET}" ;;
    esac
done
