#!/bin/bash
# ========================================
# vps-value-calculator 菜单式管理脚本
# ========================================

# ========== 颜色 ==========
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ========== 设置变量 ==========
APP_NAME="vps-value-calculator"
REPO_URL="https://github.com/podcctv/vps-value-calculator.git"
APP_DIR="$HOME/$APP_NAME"

# ========== 检查 Docker ==========
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}错误: Docker 未安装！${RESET}"
        exit 1
    fi
    if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
        echo -e "${RED}错误: Docker Compose 未安装！${RESET}"
        exit 1
    fi
}

# ========== 部署或更新项目 ==========
deploy_app() {
    if [ -d "$APP_DIR" ]; then
        echo -e "${YELLOW}项目目录已存在，拉取最新代码...${RESET}"
        cd "$APP_DIR" || exit
        git pull
    else
        echo -e "${BLUE}克隆项目到 $APP_DIR ...${RESET}"
        git clone "$REPO_URL" "$APP_DIR"
        cd "$APP_DIR" || exit
    fi

    if [ -f ".env.example" ] && [ ! -f ".env" ]; then
        echo -e "${BLUE}创建 .env 文件...${RESET}"
        cp .env.example .env
        echo -e "${GREEN}.env 文件创建完成，可根据需要修改.${RESET}"
    fi

    echo -e "${BLUE}启动 Docker 容器...${RESET}"
    docker compose up -d
    echo -e "${GREEN}服务已启动.${RESET}"
}

# ========== 停止服务 ==========
stop_app() {
    cd "$APP_DIR" || exit
    docker compose down
    echo -e "${GREEN}服务已停止.${RESET}"
}

# ========== 重启服务 ==========
restart_app() {
    cd "$APP_DIR" || exit
    docker compose down
    docker compose up -d
    echo -e "${GREEN}服务已重启.${RESET}"
}

# ========== 删除容器和镜像 ==========
remove_app() {
    cd "$APP_DIR" || exit
    docker compose down --rmi all
    echo -e "${GREEN}容器和镜像已删除.${RESET}"
}

# ========== 查看日志 ==========
logs_app() {
    cd "$APP_DIR" || exit
    docker compose logs -f
}

# ========== 显示访问地址 ==========
show_address() {
    HOST_IP=$(hostname -I | awk '{print $1}')
    if grep -q "ports:" docker-compose.yml; then
        PORT=$(grep "ports:" -A 1 docker-compose.yml | grep -oP '\d+(?=:)')
        echo -e "${GREEN}服务访问地址: http://${HOST_IP}:${PORT}${RESET}"
    else
        echo -e "${GREEN}请根据 docker-compose.yml 配置的端口访问服务.${RESET}"
    fi
}

# ========== 菜单 ==========
while true; do
    echo -e "\n${GREEN}========== VPS Value Calculator 管理菜单 ==========${RESET}"
    echo -e "${GREEN}1. 部署 / 更新并启动服务${RESET}"
    echo -e "${GREEN}2. 停止服务${RESET}"
    echo -e "${GREEN}3. 重启服务${RESET}"
    echo -e "${GREEN}4. 删除容器和镜像${RESET}"
    echo -e "${GREEN}5. 查看日志${RESET}"
    echo -e "${GREEN}6. 显示访问地址${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -ne "${YELLOW}请选择操作 [0-6]: ${RESET}"
    read -r choice
    case $choice in
        1) check_docker && deploy_app ;;
        2) stop_app ;;
        3) restart_app ;;
        4) remove_app ;;
        5) logs_app ;;
        6) show_address ;;
        0) echo -e "${YELLOW}退出管理脚本.${RESET}"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择.${RESET}" ;;
    esac
done
