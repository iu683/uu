#!/bin/bash

GREEN="\033[32m"
RESET="\033[0m"

APP_NAME="upay_pro"
LOG_VOLUME="upay_logs"
DB_VOLUME="upay_db"
PORT="8090"
YML_FILE="upay-compose.yml"

# 判断架构
get_arch() {
    arch=$(uname -m)
    if [[ "$arch" == "x86_64" ]]; then
        echo "amd64"
    elif [[ "$arch" == "aarch64" ]]; then
        echo "arm64"
    else
        echo "unknown"
    fi
}

show_menu() {
    clear
    echo -e "${GREEN}=== Upay 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动 Upay${RESET}"
    echo -e "${GREEN}2) 更新 Upay${RESET}"
    echo -e "${GREEN}3) 卸载 Upay${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}===========================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) logs_app ;;
        0) exit ;;
        *) echo "❌ 无效选择"; sleep 1; show_menu ;;
    esac
}

install_app() {
    arch=$(get_arch)

    if [[ "$arch" == "amd64" ]]; then
        IMAGE="wangergou111/upay:latest"
    elif [[ "$arch" == "arm64" ]]; then
        IMAGE="wangergou111/upay:latest-arm64"
    else
        echo "❌ 未识别的架构，无法选择镜像！"
        exit 1
    fi

    echo -e "${GREEN}🚀 正在安装并启动 $APP_NAME (镜像: $IMAGE)...${RESET}"

    docker run -d \
      --name $APP_NAME \
      -p $PORT:8090 \
      -v $LOG_VOLUME:/app/logs \
      -v $DB_VOLUME:/app/DBS \
      --restart always \
      $IMAGE

    echo -e "${GREEN}✅ $APP_NAME 已启动，访问地址: http://$(hostname -I | awk '{print $1}'):$PORT${RESET}"
    echo -e "${GREEN}✅ $APP_NAME 已启动，初始账号密码：在日志文件中，直接查看即可${RESET}"
    read -p "按回车键返回菜单..."
    show_menu
}

update_app() {
    arch=$(get_arch)

    if [[ "$arch" == "amd64" ]]; then
        IMAGE="wangergou111/upay:latest"
    elif [[ "$arch" == "arm64" ]]; then
        IMAGE="wangergou111/upay:latest-arm64"
    else
        echo "❌ 未识别的架构，无法选择镜像！"
        exit 1
    fi

    echo -e "${GREEN}🔄 正在更新 $APP_NAME...${RESET}"

    docker pull $IMAGE
    docker stop $APP_NAME && docker rm $APP_NAME
    install_app

    echo -e "${GREEN}✅ $APP_NAME 已更新并启动${RESET}"
    read -p "按回车键返回菜单..."
    show_menu
}

uninstall_app() {
    read -p "⚠️ 确认要卸载 $APP_NAME 吗？（这将删除所有数据，包括日志和数据库）（y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 停止并删除容器
        docker stop $APP_NAME && docker rm $APP_NAME
        # 删除数据卷（日志和数据库）
        docker volume rm $LOG_VOLUME $DB_VOLUME
        echo -e "${GREEN}✅ $APP_NAME 已卸载，所有相关数据已删除${RESET}"
    else
        echo "❌ 已取消"
    fi
    read -p "按回车键返回菜单..."
    show_menu
}


logs_app() {
    docker logs -f $APP_NAME
    read -p "按回车键返回菜单..."
    show_menu
}

# 调用主菜单
show_menu
