#!/bin/bash

# ================================
# kuma-mieru 管理脚本（菜单式）
# 自动显示访问 IP+端口，配置 .env
# ================================

# 颜色输出
green="\033[32m"
red="\033[31m"
plain="\033[0m"

# 项目目录
APP_DIR="$HOME/kuma-mieru"
# 默认宿主机端口（映射 docker-compose.yml 的端口）
HOST_PORT=3883

# 检查 root
if [ "$(id -u)" != "0" ]; then
    echo -e "${red}请使用 root 用户运行脚本${plain}"
    exit 1
fi

# 安装 Docker / Compose
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

# 配置 .env（基础变量 + 功能变量可自定义）
configure_env() {
    cp -f .env.example .env

    # 基础变量
    sed -i "s|^UPTIME_KUMA_BASE_URL=.*|UPTIME_KUMA_BASE_URL=${UPTIME_KUMA_BASE_URL}|" .env
    sed -i "s|^PAGE_ID=.*|PAGE_ID=${PAGE_ID}|" .env

    # 功能变量，自定义输入，默认值回车即可
    read -p "FEATURE_EDIT_THIS_PAGE [默认: false]: " FEATURE_EDIT_THIS_PAGE
    FEATURE_EDIT_THIS_PAGE=${FEATURE_EDIT_THIS_PAGE:-false}

    read -p "FEATURE_SHOW_STAR_BUTTON [默认: true]: " FEATURE_SHOW_STAR_BUTTON
    FEATURE_SHOW_STAR_BUTTON=${FEATURE_SHOW_STAR_BUTTON:-true}

    read -p "FEATURE_TITLE [默认: Kuma Mieru]: " FEATURE_TITLE
    FEATURE_TITLE=${FEATURE_TITLE:-"Kuma Mieru"}

    read -p "FEATURE_DESCRIPTION [默认: A beautiful and modern uptime monitoring dashboard]: " FEATURE_DESCRIPTION
    FEATURE_DESCRIPTION=${FEATURE_DESCRIPTION:-"A beautiful and modern uptime monitoring dashboard"}

    read -p "FEATURE_ICON [默认: /icon.svg]: " FEATURE_ICON
    FEATURE_ICON=${FEATURE_ICON:-"/icon.svg"}

    # 写入 .env
    env_vars=(
        "FEATURE_EDIT_THIS_PAGE=${FEATURE_EDIT_THIS_PAGE}"
        "FEATURE_SHOW_STAR_BUTTON=${FEATURE_SHOW_STAR_BUTTON}"
        "FEATURE_TITLE=${FEATURE_TITLE}"
        "FEATURE_DESCRIPTION=${FEATURE_DESCRIPTION}"
        "FEATURE_ICON=${FEATURE_ICON}"
    )

    for var in "${env_vars[@]}"; do
        key="${var%%=*}"
        if grep -q "^$key=" .env; then
            sed -i "s|^$key=.*|$var|" .env
        else
            echo "$var" >> .env
        fi
    done
}

# 部署安装
install_app() {
    install_docker

    # 输入基础变量
    echo -e "${green}请输入 Uptime Kuma 地址 (例如 https://example.kuma-mieru.invalid):${plain}"
    read UPTIME_KUMA_BASE_URL
    echo -e "${green}请输入页面 ID:${plain}"
    read PAGE_ID

    # 克隆或更新仓库
    if [ -d "$APP_DIR" ]; then
        echo -e "${green}检测到已有项目，拉取最新代码...${plain}"
        cd "$APP_DIR"
        git pull
    else
        git clone https://github.com/Alice39s/kuma-mieru.git "$APP_DIR"
        cd "$APP_DIR"
    fi

    # 配置 .env
    configure_env

    # 启动服务
    docker compose up -d

    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "${green}部署完成！访问地址: http://${SERVER_IP}:${HOST_PORT}${plain}"
}

# 更新服务
update_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${red}项目未安装，请先安装！${plain}"
        return
    fi
    cd "$APP_DIR"

    echo -e "${green}拉取最新代码并重启服务...${plain}"
    git pull
    docker compose pull
    docker compose up -d

    # 保持原来的基础变量，功能变量可自定义
    configure_env

    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "${green}更新完成！访问地址: http://${SERVER_IP}:${HOST_PORT}${plain}"
}

# 卸载服务
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

# 菜单
while true; do
    echo -e "\n${green}=== kuma-mieru 管理菜单 ===${plain}"
    echo -e "${green}1) 安装 / 部署${plain}"
    echo -e "${green}2) 更新${plain}"
    echo -e "${green}3) 卸载${plain}"
    echo -e "${green}0) 退出${plain}"
    echo -ne "${green}请选择操作: ${plain}"
    read choice
    case "$choice" in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${red}无效选项${plain}" ;;
    esac
done
