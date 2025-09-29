#!/bin/bash
# ========================================
# Setube/STB 一键管理脚本 (Docker)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="stb"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
DATA_DIR="$APP_DIR/data"
CONTAINER_NAME="stb"
IMAGE_NAME="setube/stb:latest"

# ---------- 端口检查函数 ----------
check_port() {
    local PORT=$1
    while lsof -i :"$PORT" >/dev/null 2>&1; do
        echo -e "${RED}❌ 端口 $PORT 已被占用，请输入其他端口${RESET}"
        read -p "请输入端口: " PORT
    done
    echo $PORT
}

# ---------- 安装/启动 ----------
install_app() {
    mkdir -p "$DATA_DIR"

    read -p "请输入容器映射端口 [默认 25519]: " input_port
    PORT=${input_port:-25519}
    PORT=$(check_port $PORT)

    # 拉取最新镜像
    echo -e "${YELLOW}拉取镜像 $IMAGE_NAME ...${RESET}"
    docker pull $IMAGE_NAME
    # 启动容器
    docker run -d \
        --name $CONTAINER_NAME \
        -p 127.0.0.1:$PORT:25519 \
        -v $DATA_DIR:/app/data \
        --restart unless-stopped \
        $IMAGE_NAME

    echo -e "${GREEN}✅ $APP_NAME 已启动${RESET}"
    echo -e "${GREEN}访问地址: http://127.0.0.1:$PORT${RESET}"
    read -p "按回车返回菜单..."
    menu
}

# ---------- 更新 ----------
update_app() {
    echo -e "${YELLOW}拉取最新镜像并更新容器...${RESET}"
    docker pull $IMAGE_NAME
    docker stop $CONTAINER_NAME 2>/dev/null
    docker rm $CONTAINER_NAME 2>/dev/null
    docker run -d \
        --name $CONTAINER_NAME \
        -p 127.0.0.1:$PORT:25519 \
        -v $DATA_DIR:/app/data \
        --restart unless-stopped \
        $IMAGE_NAME
    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

# ---------- 卸载 ----------
uninstall_app() {
    read -p "⚠️ 确认卸载并删除数据? (y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        docker stop $CONTAINER_NAME 2>/dev/null
        docker rm $CONTAINER_NAME 2>/dev/null
        docker rmi $IMAGE_NAME 2>/dev/null
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ 已卸载 $APP_NAME 并删除数据${RESET}"
    else
        echo "已取消卸载"
    fi
    read -p "按回车返回菜单..."
    menu
}

# ---------- 查看日志 ----------
view_logs() {
    docker logs -f $CONTAINER_NAME
    read -p "按回车返回菜单..."
    menu
}

# ---------- 管理菜单 ----------
menu() {
    clear
    echo -e "${GREEN}=== STB图床 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}==========================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

# ---------- 执行 ----------
menu
