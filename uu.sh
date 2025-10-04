#!/usr/bin/env bash
# ========================================
# Koipy 一键管理脚本 (Docker)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="koipy-app"
APP_DIR="/opt/Koipy"
CONFIG_PATH="$APP_DIR/config.yaml"

# 检查 Docker 是否安装
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker 未安装，请先安装 Docker${RESET}"
        exit 1
    fi
}

# 确保目录和配置文件存在
prepare_env() {
    mkdir -p "$APP_DIR"
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}未找到配置文件 $CONFIG_PATH，请将 config.yaml 放到 $APP_DIR 下${RESET}"
        exit 1
    fi
}

# 拉取镜像
pull_image() {
    echo -e "${GREEN}拉取 Koipy 镜像...${RESET}"
    docker pull koipy/koipy:latest
}

# 启动容器
start_container() {
    # 删除已存在容器
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${APP_NAME}\$"; then
        echo -e "${YELLOW}检测到已存在的容器，正在删除...${RESET}"
        docker rm -f $APP_NAME
    fi

    echo -e "${GREEN}启动容器...${RESET}"
    docker run -itd \
        --name $APP_NAME \
        --network=host \
        --restart=always \
        -v "$CONFIG_PATH":/app/config.yaml \
        koipy/koipy:latest

    echo -e "${GREEN}Koipy 已启动！${RESET}"
}

# 查看日志
view_logs() {
    if docker ps --format '{{.Names}}' | grep -Eq "^${APP_NAME}\$"; then
        docker logs -f $APP_NAME
    else
        echo -e "${RED}容器未运行${RESET}"
    fi
}

# 重启容器
restart_container() {
    if docker ps --format '{{.Names}}' | grep -Eq "^${APP_NAME}\$"; then
        docker restart $APP_NAME
        echo -e "${GREEN}容器已重启${RESET}"
    else
        echo -e "${RED}容器未运行，正在启动...${RESET}"
        start_container
    fi
}

# 卸载容器
uninstall_container() {
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${APP_NAME}\$"; then
        docker rm -f $APP_NAME
        echo -e "${GREEN}容器已删除${RESET}"
    else
        echo -e "${YELLOW}容器不存在${RESET}"
    fi
}

# 菜单
menu() {
    while true; do
        echo -e "${GREEN}=== Koipy 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 重启${RESET}"
        echo -e "${GREEN}3) 查看日志${RESET}"
        echo -e "${GREEN}4) 卸载${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "请输入选项: " choice
        case $choice in
            1) prepare_env; pull_image; start_container ;;
            2) restart_container ;;
            3) view_logs ;;
            4) uninstall_container ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${RESET}" ;;
        esac
    done
}

# 脚本入口
check_docker
menu
