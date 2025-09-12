#!/bin/bash
# ============================================
# Homepage 一键管理脚本
# 功能: 安装/更新/卸载/查看日志
# ============================================

APP_NAME="homepage"
IMAGE_NAME="ghcr.io/gethomepage/homepage:latest"
DATA_DIR="./homepage_config"
CONFIG_FILE="./homepage.conf"

GREEN="\033[32m"
RESET="\033[0m"

check_env() {
    if ! command -v docker &> /dev/null; then
        echo -e "${GREEN}❌ 未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
PORT="$PORT"
CONFIG_DIR="$CONFIG_DIR"
HOMEPAGE_ALLOWED_HOSTS="$HOMEPAGE_ALLOWED_HOSTS"
EOF
}

install_app() {
    load_config

    read -p "请输入映射端口 (默认 ${PORT:-3000}): " input
    PORT=${input:-${PORT:-3000}}

    read -p "请输入配置目录路径 (默认 ${CONFIG_DIR:-$DATA_DIR}): " input
    CONFIG_DIR=${input:-${CONFIG_DIR:-$DATA_DIR}}

    read -p "请输入 HOMEPAGE_ALLOWED_HOSTS (默认 ${HOMEPAGE_ALLOWED_HOSTS:-gethomepage.dev}): " input
    HOMEPAGE_ALLOWED_HOSTS=${input:-${HOMEPAGE_ALLOWED_HOSTS:-gethomepage.dev}}

    mkdir -p "$CONFIG_DIR"

    save_config

    echo -e "${GREEN}🚀 正在安装并启动 $APP_NAME ...${RESET}"

    docker run -d \
      --name $APP_NAME \
      -p ${PORT}:3000 \
      -v "$(realpath $CONFIG_DIR):/app/config" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -e HOMEPAGE_ALLOWED_HOSTS="$HOMEPAGE_ALLOWED_HOSTS" \
      $IMAGE_NAME

    echo -e "${GREEN}✅ $APP_NAME 已启动，访问地址: http://<服务器IP>:$PORT${RESET}"
}

update_app() {
    echo -e "${GREEN}🔄 正在更新 $APP_NAME ...${RESET}"
    docker pull $IMAGE_NAME
    docker stop $APP_NAME && docker rm $APP_NAME
    install_app
    echo -e "${GREEN}✅ 容器已更新并启动${RESET}"
}

uninstall_app() {
    read -p "⚠️ 确认要卸载 $APP_NAME 并删除数据和配置吗？(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        docker stop $APP_NAME && docker rm $APP_NAME
        rm -rf $DATA_DIR
        rm -f $CONFIG_FILE
        echo -e "${GREEN}✅ $APP_NAME 已卸载并清理（含配置文件）${RESET}"
    else
        echo -e "${GREEN}❌ 已取消${RESET}"
    fi
}

logs_app() {
    docker logs -f $APP_NAME
}

menu() {
    clear
    echo -e "${GREEN}=== Homepage 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动 Homepage${RESET}"
    echo -e "${GREEN}2) 更新 Homepage${RESET}"
    echo -e "${GREEN}3) 卸载 Homepage${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}==========================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) logs_app ;;
        0) exit 0 ;;
        *) echo -e "${GREEN}无效选择${RESET}" ;;
    esac
}

check_env
while true; do
    menu
    read -p "按回车键返回菜单..." enter
done
