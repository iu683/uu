#!/bin/bash
# vue-color-avatar 一键管理脚本（增加更新功能）

GREEN="\033[32m"
RESET="\033[0m"

APP_NAME="vue-color-avatar"
IMAGE_NAME="vue-color-avatar:latest"
DEFAULT_PORT=3000
BASE_DIR="/opt/vue-color-avatar"
PORT=$DEFAULT_PORT  # 默认端口，可在安装时修改

show_menu() {
    echo -e "${GREEN}=== vue-color-avatar 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 停止服务${RESET}"
    echo -e "${GREEN}3) 启动服务${RESET}"
    echo -e "${GREEN}4) 重启服务${RESET}"
    echo -e "${GREEN}5) 更新服务${RESET}"
    echo -e "${GREEN}6) 查看日志${RESET}"
    echo -e "${GREEN}7) 卸载服务${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}===============================${RESET}"
    read -p "请选择: " choice
}

install_app() {
    read -p "请输入映射端口 (默认 ${DEFAULT_PORT}): " input_port
    PORT=${input_port:-$DEFAULT_PORT}

    # 克隆代码
    if [ ! -d "$BASE_DIR" ]; then
        git clone https://github.com/Codennnn/vue-color-avatar.git "$BASE_DIR"
    fi

    # 构建镜像
    cd "$BASE_DIR"
    docker build -t $IMAGE_NAME .

    # 启动容器
    docker run -d -p "127.0.0.1:$PORT:80" --name $APP_NAME $IMAGE_NAME

    echo -e "✅ ${GREEN}vue-color-avatar 已安装并启动${RESET}"
    local ip=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
    echo -e "🌐 访问地址: ${GREEN}http://127.0.0.1:${PORT}${RESET}"
}

stop_app() {
    docker stop $APP_NAME
    echo -e "🛑 ${GREEN}vue-color-avatar 已停止${RESET}"
}

start_app() {
    docker start $APP_NAME
    echo -e "🚀 ${GREEN}vue-color-avatar 已启动${RESET}"
}

restart_app() {
    docker restart $APP_NAME
    echo -e "🔄 ${GREEN}vue-color-avatar 已重启${RESET}"
}

update_app() {
    if [ ! -d "$BASE_DIR" ]; then
        echo -e "❌ ${GREEN}代码目录不存在，请先安装服务${RESET}"
        return
    fi

    # 停止并删除旧容器
    docker stop $APP_NAME
    docker rm $APP_NAME

    # 拉取最新代码并重建镜像
    cd "$BASE_DIR"
    git pull
    docker build -t $IMAGE_NAME .

    # 启动新容器
    docker run -d -p "127.0.0.1:$PORT:80" --name $APP_NAME $IMAGE_NAME
    echo -e "⬆️ ${GREEN}vue-color-avatar 已更新并重启${RESET}"
    local ip=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
    echo -e "🌐 访问地址: ${GREEN}http://127.0.0.1:${PORT}${RESET}"
}

logs_app() {
    docker logs -f $APP_NAME
}

uninstall_app() {
    docker stop $APP_NAME
    docker rm $APP_NAME
    docker rmi $IMAGE_NAME
    rm -rf "$BASE_DIR"
    echo -e "🗑️ ${GREEN}vue-color-avatar 已卸载，镜像和代码已删除${RESET}"
}

while true; do
    show_menu
    case $choice in
        1) install_app ;;
        2) stop_app ;;
        3) start_app ;;
        4) restart_app ;;
        5) update_app ;;
        6) logs_app ;;
        7) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "❌ ${GREEN}无效选择${RESET}" ;;
    esac
done
