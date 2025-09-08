#!/bin/bash
# ============================================
# MetaTube 管理脚本（菜单版）
# 功能: 安装/更新/卸载/日志
# ============================================

set -e

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

CONTAINER_NAME="metatube"
IMAGE_NAME="ghcr.io/metatube-community/metatube-server:latest"
CONFIG_DIR="$PWD/config"
DB_FILE="$CONFIG_DIR/metatube.db"

menu() {
    clear
    echo -e "${GREEN}=== MetaTube 管理菜单 ===${RESET}"
    echo -e "${YELLOW}1) 安装/部署 MetaTube${RESET}"
    echo -e "${YELLOW}2) 更新 MetaTube${RESET}"
    echo -e "${YELLOW}3) 卸载 MetaTube${RESET}"
    echo -e "${YELLOW}4) 查看日志${RESET}"
    echo -e "${YELLOW}0) 退出${RESET}"
    echo
    read -p "请选择操作: " choice

    case $choice in
        1) install_metatube ;;
        2) update_metatube ;;
        3) uninstall_metatube ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择！${RESET}" && sleep 1 && menu ;;
    esac
}

install_metatube() {
    echo -e "${GREEN}=== 安装/部署 MetaTube ===${RESET}"

    # 创建配置目录
    mkdir -p "$CONFIG_DIR"

    # 运行容器
    docker run -d \
        -p 8080:8080 \
        -v "$CONFIG_DIR":/config \
        --name "$CONTAINER_NAME" \
        "$IMAGE_NAME" \
        -dsn /config/metatube.db

    echo -e "${GREEN}✅ 部署完成！访问地址: http://$(curl -s https://api.ipify.org):8080${RESET}"
    read -p "按回车返回菜单..." && menu
}

update_metatube() {
    echo -e "${GREEN}=== 更新 MetaTube ===${RESET}"

    # 拉取最新镜像
    docker pull "$IMAGE_NAME"

    # 停止并删除旧容器（数据在 ./config 下不会丢失）
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true

    # 重新运行容器
    docker run -d \
        -p 8080:8080 \
        -v "$CONFIG_DIR":/config \
        --name "$CONTAINER_NAME" \
        "$IMAGE_NAME" \
        -dsn /config/metatube.db

    echo -e "${GREEN}✅ 更新完成！访问地址: http://$(curl -s https://api.ipify.org):8080${RESET}"
    read -p "按回车返回菜单..." && menu
}

uninstall_metatube() {
    echo -e "${RED}⚠️  即将卸载 MetaTube，并删除相关配置数据！${RESET}"
    read -p "确认卸载? (y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        docker rm "$CONTAINER_NAME" 2>/dev/null || true
        rm -rf "$CONFIG_DIR"
        echo -e "${GREEN}✅ 卸载完成${RESET}"
    else
        echo -e "${YELLOW}已取消${RESET}"
    fi
    read -p "按回车返回菜单..." && menu
}

view_logs() {
    echo -e "${GREEN}=== 查看 MetaTube 日志 ===${RESET}"
    docker logs -f "$CONTAINER_NAME"
    read -p "按回车返回菜单..." && menu
}

menu
