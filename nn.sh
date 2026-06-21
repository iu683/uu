#!/bin/bash
# =================================================================
# Magnet Fix (磁力检索与下载系统) Docker Compose 纯净管理脚本
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

INSTALL_DIR="/opt/magnet-fix"
CONTAINER_NAME="magnet-search"
WEBUI_PORT="8080"  # Magnet Fix 默认运行端口

# 检测基础依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! command -v git &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Git，请先安装 Git！${RESET}"
        exit 1
    fi
}

# 动态获取容器当前运行状态
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi
}

# 获取公网 IP (兼容双栈环境)
get_public_ip() {
    local mode=${1:-"auto"}
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
}


# 选项 1：一键拉取仓库并选择模式启动
deploy_magnet() {
    check_dependencies
    
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}正在从 GitHub 克隆 magnet_fix 源码仓库...${RESET}"
        git clone https://github.com/Polarisiu/magnet_fix.git "$INSTALL_DIR"
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: 克隆仓库失败！${RESET}"
            return
        fi
    fi

    cd "$INSTALL_DIR" || return

    clear
    echo -e "${CYAN}====== 🚀 选择组合模式启动 Magnet Fix ======${RESET}"
    echo -e " [1] 仅启动搜索站点 (默认内置 SQLite)"
    echo -e " [2] 同时启动搜索站点 + 示例 qBittorrent 服务"
    echo -e " [3] 同时启动搜索站点 + 示例 MySQL 服务"
    echo -e " [4] 同时启动全家桶 (站点 + qBittorrent + MySQL)"
    echo -ne "${GREEN}请选择启动模式 (1-4): ${RESET}"
    read -r mode_choice

    echo -e "\n${YELLOW}正在通过 Docker Compose 构建并拉起容器...${RESET}"
    
    case "$mode_choice" in
        1) docker compose up -d --build ;;
        2) docker compose --profile with-qb up -d --build ;;
        3) docker compose --profile with-mysql up -d --build ;;
        4) docker compose --profile with-qb --profile with-mysql up -d --build ;;
        *) echo -e "${RED}无效选择，放弃部署。${RESET}" ; return ;;
    esac

    DETECT_IP=$(get_public_ip)

    if [ $? -eq 0 ]; then
        echo -e "\n${GREEN}====================================================${RESET}"
        echo -e "${GREEN}     🧲 Magnet Fix 磁力检索系统部署/启动成功！      ${RESET}"
        echo -e "${GREEN}====================================================${RESET}"
        echo -e "${YELLOW} 页面 / 服务       地址${RESET}"
        echo -e " 搜索首页:        http://${DETECT_IP}:${WEBUI_PORT}"
        echo -e " 管理后台:        http://${DETECT_IP}:${WEBUI_PORT}/admin"
        echo -e " 默认后台密码:    ${RED}admin123${RESET}"
        [[ "$mode_choice" =~ ^(2|4)$ ]] && echo -e " qBittorrentUI:  http://${DETECT_IP}:18080"
        [[ "$mode_choice" =~ ^(3|4)$ ]] && echo -e " MySQL 地址:     ${DETECT_IP}:13306"
        echo -e "${GREEN}====================================================${RESET}"
    fi
}

# 选项 2：更新容器
update_magnet() {
    if [ -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}正在拉取仓库及镜像更新...${RESET}"
        cd "$INSTALL_DIR" && git pull
        docker compose --profile with-qb --profile with-mysql pull
        docker compose --profile with-qb --profile with-mysql up -d --build
        echo -e "${GREEN}更新完成！${RESET}"
    else
        echo -e "${RED}未检测到安装目录！${RESET}"
    fi
}

# 选项 3：彻底卸载清理
uninstall_magnet() {
    echo -ne "${RED}警告: 确定要彻底卸载磁力站并清理所有相关数据吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" = "y" || "$confirm" = "Y" ]]; then
        if [ -d "$INSTALL_DIR" ]; then
            cd "$INSTALL_DIR" && docker compose --profile with-qb --profile with-mysql down -v
            rm -rf "$INSTALL_DIR"
            echo -e "${GREEN}彻底卸载清理完成。${RESET}"
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
    fi
}

start_magnet() {
    if [ -d "$INSTALL_DIR" ]; then cd "$INSTALL_DIR" && docker compose restart magnet-search && echo -e "${GREEN}容器已启动${RESET}"; fi
}

stop_magnet() {
    if [ -d "$INSTALL_DIR" ]; then cd "$INSTALL_DIR" && docker compose stop magnet-search && echo -e "${YELLOW}容器已停止${RESET}"; fi
}

restart_magnet() {
    if [ -d "$INSTALL_DIR" ]; then cd "$INSTALL_DIR" && docker compose restart magnet-search && echo -e "${GREEN}容器已重启${RESET}"; fi
}

show_logs() {
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        docker logs -f --tail=100 "$CONTAINER_NAME"
    else
        echo -e "${RED}容器未运行！${RESET}"
    fi
}

show_config() {
    if [ -d "$INSTALL_DIR" ]; then
        echo -e "${CYAN}====== 当前环境配置 ======${RESET}"
        echo -e "${YELLOW}安装路径:${RESET} $INSTALL_DIR"
        if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
            cat "$INSTALL_DIR/docker-compose.yml" | grep -E "image:|ports:"
        fi
    else
        echo -e "${RED}未检测到安装配置。${RESET}"
    fi
}

# 主菜单循环
menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  Magnet-Fix 管理面板  ◈ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态    :${RESET} $status"
    echo -e "${GREEN}端口    :${RESET} ${YELLOW}${WEBUI_PORT}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) deploy_magnet ;;
        2) update_magnet ;;
        3) uninstall_magnet ;;
        4) start_magnet ;;
        5) stop_magnet ;;
        6) restart_magnet ;;
        7) show_logs ;;
        8) show_config ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "\n${YELLOW}按回车键继续...${RESET}"
    read -r
done
