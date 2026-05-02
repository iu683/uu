#!/bin/bash
# ========================================
# J-Board 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[1;36m"
RESET="\033[0m"

APP_NAME="jboard"
APP_DIR="/opt/jboard"

install_jboard() {
    echo -e "${CYAN}>>> 开始安装 J-Board...${RESET}"

    mkdir -p $APP_DIR
    cd $APP_DIR || exit

    bash <(curl -fsSL https://raw.githubusercontent.com/JetSprow/J-Board/main/scripts/install-jboard-panel.sh)

    echo -e "${GREEN}>>> 安装完成${RESET}"
}

update_jboard() {
    echo -e "${CYAN}>>> 开始更新 J-Board...${RESET}"

    cd $APP_DIR || { echo -e "${RED}目录不存在，请先安装${RESET}"; return; }

    bash <(curl -fsSL https://raw.githubusercontent.com/JetSprow/J-Board/main/scripts/upgrade-jboard-panel.sh)

    echo -e "${GREEN}>>> 更新完成${RESET}"
}

logs_jboard() {
    echo -e "${CYAN}>>> 查看日志 (Ctrl+C 退出)...${RESET}"

    cd $APP_DIR || { echo -e "${RED}目录不存在${RESET}"; return; }

    docker compose logs -f app
}

uninstall_jboard() {
    echo -e "${CYAN}>>> 正在卸载 J-Board...${RESET}"

    if [ -f "$APP_DIR/docker-compose.yml" ]; then
        cd $APP_DIR || exit
        docker compose down -v
        echo -e "${GREEN}>>> 容器已停止并删除${RESET}"
    else
        echo -e "${YELLOW}未检测到 docker-compose.yml，跳过容器清理${RESET}"
    fi

    rm -rf $APP_DIR

    echo -e "${GREEN}>>> 已彻底卸载（目录已删除）${RESET}"
}

menu() {
    clear
    echo -e "${GREEN}"
    echo "======================================"
    echo "        J-Board 管理"
    echo "======================================"
    echo -e "${RESET}"
    echo -e "${GREEN}1.安装 J-Board${RESET}"
    echo -e "${GREEN}2.更新 J-Board${RESET}"
    echo -e "${GREEN}3.查看日志${RESET}"
    echo -e "${GREEN}4.卸载 J-Board${RESET}"
    echo -e "${GREEN}0.退出${RESET}"
    read -p "$(echo -e ${GREEN}请输入菜单编号:${RESET} )" choice

    case $choice in
        1) install_jboard ;;
        2) update_jboard ;;
        3) logs_jboard ;;
        4) uninstall_jboard ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo
    read -p "$(echo -e ${CYAN}按回车返回菜单...${RESET})"
done
