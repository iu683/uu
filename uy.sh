#!/usr/bin/env bash
# ========================================
# Miaospeed 一键管理脚本 (Docker)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="miaospeed"
APP_DIR="/opt/$APP_NAME"
CONFIG_FILE="$APP_DIR/config.env"
container_name="miaospeed"

# 初始化环境
setup_environment() {
    mkdir -p "$APP_DIR"
    echo "创建了 $APP_DIR 文件夹。"

    if [ ! -f "$CONFIG_FILE" ]; then
        touch "$CONFIG_FILE"
        echo "创建 config.env 文件。"
    fi
}

# 检查 Docker
docker_check() {
    echo "正在检查 Docker 安装情况 . . ."
    if ! command -v docker &>/dev/null; then
        echo "Docker 未安装，请安装 Docker 并将当前用户加入 docker 组。"
        read -p "按回车返回菜单..." ; menu
    fi
    if ! docker info &>/dev/null; then
        echo "当前用户无权访问 Docker 或 Docker 未运行，请检查。"
        read -p "按回车返回菜单..." ; menu
    fi
    echo "Docker 已安装并可访问。"
}

# 安装容器
install_app() {
    read -p "请输入绑定端口 [默认: 8765]: " bind_port
    bind_port=${bind_port:-8765}
    read -p "请输入 Miaospeed 路径 [默认: miaospeed]: " path
    path=${path:-miaospeed}
    read -p "请输入 Token [默认: 123123N2e{Q?W]: " token
    token=${token:-123123N2e{Q?W}

    echo "BIND_PORT=$bind_port" > "$CONFIG_FILE"
    echo "PATH=$path" >> "$CONFIG_FILE"
    echo "TOKEN=$token" >> "$CONFIG_FILE"

    docker rm -f "$container_name" &>/dev/null || true
    docker pull airportr/miaospeed:latest

    docker run -idt --name "$container_name" --network host --restart always \
        airportr/miaospeed:latest \
        server -bind 0.0.0.0:"$bind_port" -path "$path" -token "$token" -mtls

    echo -e "${GREEN}✅ Miaospeed 容器已启动${RESET}"
    read -p "按回车返回菜单..."
    menu
}

# 卸载容器并删除文件
uninstall_app() {
    docker rm -f "$container_name" &>/dev/null || echo "容器 $container_name 不存在"

    if [ -d "$APP_DIR" ]; then
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ 已删除容器 $container_name${RESET}"
    fi
    read -p "按回车返回菜单..."
    menu
}

# 启动容器
start_app() {
    docker start "$container_name" &>/dev/null || echo "容器 $container_name 不存在"
    echo -e "${GREEN}✅ 已启动容器 $container_name${RESET}"
    read -p "按回车返回菜单..."
    menu
}

# 停止容器
stop_app() {
    docker stop "$container_name" &>/dev/null || echo "容器 $container_name 不存在"
    echo -e "${GREEN}✅ 已停止容器 $container_name${RESET}"
    read -p "按回车返回菜单..."
    menu
}

# 重启容器
restart_app() {
    docker restart "$container_name" &>/dev/null || echo "容器 $container_name 不存在"
    echo -e "${GREEN}✅ 已重启容器 $container_name${RESET}"
    read -p "按回车返回菜单..."
    menu
}

# 查看日志
view_logs() {
    echo -e "${GREEN}按 Ctrl+C 停止日志查看${RESET}"
    docker logs -f "$container_name"
    read -p "按回车返回菜单..."
    menu
}

# 主菜单
menu() {
    clear
    echo -e "${GREEN}=== Miaospeed 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装${RESET}"
    echo -e "${GREEN}2) 卸载${RESET}"
    echo -e "${GREEN}3) 停止${RESET}"
    echo -e "${GREEN}4) 启动${RESET}"
    echo -e "${GREEN}5) 重启${RESET}"
    echo -e "${GREEN}6) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) setup_environment; docker_check; install_app ;;
        2) uninstall_app ;;
        3) stop_app ;;
        4) start_app ;;
        5) restart_app ;;
        6) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

# 启动菜单
menu
