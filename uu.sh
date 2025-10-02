#!/bin/bash

# ================================
# kuma-mieru 管理脚本（菜单式）
# 自动显示访问 IP+端口，配置 .env
# ================================

green="\033[32m"
red="\033[31m"
plain="\033[0m"

APP_DIR="/opt/kuma-mieru"
HOST_PORT=3883

if [ "$(id -u)" != "0" ]; then
    echo -e "${red}请使用 root 用户运行脚本${plain}"
    exit 1
fi

install_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${green}安装 Docker...${plain}"
        apt update
        apt install -y docker.io
    fi
    if ! docker compose version &> /dev/null; then
        echo -e "${green}安装 Docker Compose 插件...${plain}"
        apt install -y docker-compose-plugin
    fi
}

install_app() {
    install_docker

    echo -e "${green}请输入 Uptime Kuma 地址 (例如 https://example.kuma-mieru.invalid):${plain}"
    read UPTIME_KUMA_BASE_URL
    echo -e "${green}请输入页面 ID:${plain}"
    read PAGE_ID

    if [ -d "$APP_DIR" ]; then
        echo -e "${green}检测到已有项目，拉取最新代码...${plain}"
        cd "$APP_DIR"
        git pull
    else
        git clone https://github.com/Alice39s/kuma-mieru.git "$APP_DIR"
        cd "$APP_DIR"
    fi

    cp -f .env.example .env
    sed -i "s|^UPTIME_KUMA_BASE_URL=.*|UPTIME_KUMA_BASE_URL=${UPTIME_KUMA_BASE_URL}|" .env
    sed -i "s|^PAGE_ID=.*|PAGE_ID=${PAGE_ID}|" .env

    docker compose up -d

    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "${green}部署完成！访问地址: http://${SERVER_IP}:${HOST_PORT}${plain}"
}

update_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${red}项目未安装，请先安装！${plain}"
        return
    fi
    cd "$APP_DIR"
    docker compose pull
    docker compose up -d
    echo -e "${green}更新镜像并重启服务...${plain}"
}

restart_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${red}项目未安装，请先安装！${plain}"
        return
    fi
    cd "$APP_DIR"
    echo -e "${green}重启服务中...${plain}"
    docker compose restart
    echo -e "${green}重启完成！${plain}"
}

show_logs() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${red}项目未安装，请先安装！${plain}"
        return
    fi
    cd "$APP_DIR"
    echo -e "${green}显示日志（按 Ctrl+C 退出）...${plain}"
    docker compose logs -f
}

uninstall_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${red}项目未安装，无需卸载${plain}"
        return
    fi
    cd "$APP_DIR"
    echo -e "${green}停止并删除容器和镜像...${plain}"
    docker compose down --rmi all
    cd ~
    rm -rf "$APP_DIR"
    echo -e "${green}卸载完成！${plain}"
}

while true; do
    clear
    echo -e "${green}=== kuma-mieru 管理菜单 ===${plain}"
    echo -e "${green}1) 安装启动${plain}"
    echo -e "${green}2) 更新${plain}"
    echo -e "${green}3) 卸载${plain}"
    echo -e "${green}4) 重启服务${plain}"
    echo -e "${green}5) 查看日志${plain}"
    echo -e "${green}0) 退出${plain}"
    echo -ne "${green}请选择操作: ${plain}"
    read choice
    case "$choice" in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) restart_app ;;
        5) show_logs ;;
        0) exit 0 ;;
        *) echo -e "${red}无效选项${plain}" ;;
    esac
done
