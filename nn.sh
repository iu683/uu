#!/bin/bash
# ========================================
# AutoBangumi 一键管理脚本（支持自定义端口）
# ========================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# 配置
APP_NAME="AutoBangumi"
DEFAULT_PORT=7892
CONFIG_FILE="${HOME}/.autobangumi.conf"
CONFIG_DIR="${HOME}/AutoBangumi/config"
DATA_DIR="${HOME}/AutoBangumi/data"
IMAGE_NAME="ghcr.io/estrellaxd/auto_bangumi:latest"
TIMEZONE="Asia/Shanghai"

# 读取或设置端口
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    read -p "请输入 AutoBangumi 映射端口 (默认 $DEFAULT_PORT): " input_port
    APP_PORT=${input_port:-$DEFAULT_PORT}
    echo "APP_PORT=$APP_PORT" > "$CONFIG_FILE"
fi

# 检查 Docker
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装！${RESET}"
        exit 1
    fi
}

# 部署 AutoBangumi
install_app() {
    check_docker
    mkdir -p "${CONFIG_DIR}" "${DATA_DIR}"
    echo -e "${YELLOW}拉取镜像：${IMAGE_NAME}${RESET}"
    docker pull "${IMAGE_NAME}"

    if docker ps -a --format '{{.Names}}' | grep -q "^${APP_NAME}$"; then
        echo -e "${YELLOW}已有容器 ${APP_NAME}，正在删除...${RESET}"
        docker stop "${APP_NAME}" && docker rm "${APP_NAME}"
    fi

    echo -e "${YELLOW}正在启动 AutoBangumi...${RESET}"
    docker run -d \
      --name="${APP_NAME}" \
      -v "${CONFIG_DIR}:/app/config" \
      -v "${DATA_DIR}:/app/data" \
      -p ${APP_PORT}:7892 \
      -e TZ=${TIMEZONE} \
      -e PUID=$(id -u) \
      -e PGID=$(id -g) \
      -e UMASK=022 \
      --network=bridge \
      --dns=8.8.8.8 \
      --restart unless-stopped \
      "${IMAGE_NAME}"

    echo -e "${GREEN}AutoBangumi 部署完成！${RESET}"
    echo -e "${CYAN}访问地址：http://$(hostname -I | awk '{print $1}'):${APP_PORT}${RESET}"
}

# 启动
start_app() { docker start "${APP_NAME}" && echo -e "${GREEN}已启动 ${APP_NAME}${RESET}"; }

# 停止
stop_app() { docker stop "${APP_NAME}" && echo -e "${YELLOW}已停止 ${APP_NAME}${RESET}"; }

# 重启
restart_app() { docker restart "${APP_NAME}" && echo -e "${GREEN}已重启 ${APP_NAME}${RESET}"; }

# 查看日志
logs_app() { docker logs -f "${APP_NAME}"; }

# 更新镜像
update_app() {
    echo -e "${YELLOW}正在更新 ${APP_NAME}...${RESET}"
    docker pull "${IMAGE_NAME}"
    docker stop "${APP_NAME}" && docker rm "${APP_NAME}"
    install_app
}

# 卸载
uninstall_app() {
    docker stop "${APP_NAME}" && docker rm "${APP_NAME}"
    echo -e "${YELLOW}是否删除配置和数据目录？[y/N]${RESET}"
    read -r del
    if [[ "$del" == "y" || "$del" == "Y" ]]; then
        rm -rf "${CONFIG_DIR}" "${DATA_DIR}" "${CONFIG_FILE}"
        echo -e "${RED}已删除配置和数据目录${RESET}"
    fi
    echo -e "${GREEN}${APP_NAME} 已卸载${RESET}"
}

# 菜单
menu() {
    clear
    echo -e "${GREEN}==== AutoBangumi 管理菜单 ====${RESET}"
    echo -e "${GREEN}1. 部署 AutoBangumi（可自定义端口）${RESET}"
    echo -e "${GREEN}2. 启动 AutoBangumi${RESET}"
    echo -e "${GREEN}3. 停止 AutoBangumi${RESET}"
    echo -e "${GREEN}4. 重启 AutoBangumi${RESET}"
    echo -e "${GREEN}5. 查看日志${RESET}"
    echo -e "${GREEN}6. 更新 AutoBangumi${RESET}"
    echo -e "${GREEN}7. 卸载 AutoBangumi${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -ne "${YELLOW}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) 
            read -p "请输入 AutoBangumi 映射端口 (默认 $DEFAULT_PORT): " input_port
            APP_PORT=${input_port:-$DEFAULT_PORT}
            echo "APP_PORT=$APP_PORT" > "$CONFIG_FILE"
            install_app
            ;;
        2) start_app ;;
        3) stop_app ;;
        4) restart_app ;;
        5) logs_app ;;
        6) update_app ;;
        7) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

# 循环菜单
while true; do
    menu
    echo -e "${YELLOW}按回车键继续...${RESET}"
    read -r
done
