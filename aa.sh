#!/bin/bash

GREEN="\033[32m"
RESET="\033[0m"

APP_NAME="danmu-api"
IMAGE_NAME="logvar/danmu-api:latest"
PORT_FILE="./danmu_port.conf"
TOKEN_FILE="./danmu_token.conf"
DEFAULT_TOKEN="87654321"

# 获取公网IP
get_public_ip() {
    curl -s ifconfig.me || curl -s ipinfo.io/ip
}

# 安装/启动容器（含拉取镜像）
install_app() {
    echo -e "${GREEN}🚀 正在拉取最新镜像...${RESET}"
    docker pull $IMAGE_NAME

    # 读取 TOKEN
    if [ -f "$TOKEN_FILE" ]; then
        TOKEN=$(cat "$TOKEN_FILE")
    else
        read -p "请输入 TOKEN (默认: $DEFAULT_TOKEN): " TOKEN
        TOKEN=${TOKEN:-$DEFAULT_TOKEN}
        echo "$TOKEN" > "$TOKEN_FILE"
    fi

    # 读取端口
    if [ -f "$PORT_FILE" ]; then
        PORT=$(cat "$PORT_FILE")
    else
        read -p "请输入映射端口 (默认 9321): " PORT
        PORT=${PORT:-9321}
        echo "$PORT" > "$PORT_FILE"
    fi

    # 如果容器存在，先删除
    if docker ps -a --format '{{.Names}}' | grep -q "^${APP_NAME}$"; then
        docker stop $APP_NAME && docker rm $APP_NAME
    fi

    echo -e "${GREEN}🚀 正在运行容器 (端口: $PORT, TOKEN: $TOKEN)...${RESET}"
    docker run -d --name $APP_NAME -p $PORT:9321 -e TOKEN="$TOKEN" $IMAGE_NAME

    IP=$(get_public_ip)
    echo -e "${GREEN}✅ $APP_NAME 已启动${RESET}"
    echo -e "${GREEN}访问地址: http://$IP:$PORT${RESET}"
    echo -e "${GREEN}TOKEN: $TOKEN${RESET}"
    read -p "按回车键返回菜单..."
    show_menu
}

# 更新容器
update_app() {
    echo -e "${GREEN}🔄 正在更新 $APP_NAME...${RESET}"
    docker stop $APP_NAME && docker rm $APP_NAME
    install_app
}

# 卸载容器
uninstall_app() {
    read -p "⚠️ 确认要卸载 $APP_NAME 并删除配置吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        docker stop $APP_NAME && docker rm $APP_NAME
        rm -f $TOKEN_FILE $PORT_FILE
        echo -e "${GREEN}✅ $APP_NAME 已卸载并清理${RESET}"
    else
        echo -e "${GREEN}❌ 已取消${RESET}"
    fi
    read -p "按回车键返回菜单..."
    show_menu
}

# 查看日志
show_logs() {
    docker logs -f $APP_NAME
}

# 查看配置信息
show_config() {
    PORT=$(cat "$PORT_FILE" 2>/dev/null || echo "未设置")
    TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null || echo "未设置")
    IP=$(get_public_ip)

    echo -e "${GREEN}=== 当前配置 ===${RESET}"
    echo -e "${GREEN}公网IP: $IP${RESET}"
    echo -e "${GREEN}端口:   $PORT${RESET}"
    echo -e "${GREEN}TOKEN:  $TOKEN${RESET}"
    echo -e "${GREEN}=================${RESET}"
    read -p "按回车键返回菜单..."
    show_menu
}

# 菜单
show_menu() {
    clear
    echo -e "${GREEN}=== Danmu-API 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动 Danmu-API${RESET}"
    echo -e "${GREEN}2) 更新 Danmu-API${RESET}"
    echo -e "${GREEN}3) 卸载 Danmu-API${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 查看当前配置${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}===========================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) show_logs ;;
        5) show_config ;;
        0) exit ;;
        *) echo "❌ 无效选择"; sleep 1; show_menu ;;
    esac
}

show_menu
