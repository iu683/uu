#!/bin/bash
# =================================================================
# Magnet Fix (磁力检索与下载系统) Docker Compose 管理脚本
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

INSTALL_DIR="/opt/magnet-fix"
CONTAINER_NAME="magnet-search"

# 默认端口配置
DEFAULT_WEB_PORT="8080"
DEFAULT_UDP_PORT="6881"

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

# 动态从 docker-compose.yml 实时读取当前【仅属于 magnet-search】配置的端口
load_current_ports() {
    if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
        # 精准定位：只看 magnet-search 服务定义区间的端口（取前两行匹配项）
        WEBUI_PORT=$(sed -n '/magnet-search:/,/qbittorrent:/p' "$INSTALL_DIR/docker-compose.yml" | grep -E '[0-9]+:8080' | head -n1 | awk -F'"' '{print $2}' | cut -d':' -f1)
        UDP_PORT=$(sed -n '/magnet-search:/,/qbittorrent:/p' "$INSTALL_DIR/docker-compose.yml" | grep -E '[0-9]+:6881/udp' | head -n1 | awk -F'"' '{print $2}' | cut -d':' -f1)
    fi
    
    # 兜底默认值
    : "${WEBUI_PORT:=$DEFAULT_WEB_PORT}"
    : "${UDP_PORT:=$DEFAULT_UDP_PORT}"
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

# 自动分析当前已部署的 Profile 状态
get_current_profiles() {
    local profiles=""
    if [ "$(docker ps -aq -f name=^/qbittorrent$)" ]; then
        profiles="$profiles --profile with-qb"
    fi
    if [ "$(docker ps -aq -f name=^/magnet-mysql$)" ]; then
        profiles="$profiles --profile with-mysql"
    fi
    echo "$profiles"
}

# 选项 1：一键拉取仓库并选择模式启动
deploy_magnet() {
    check_dependencies
    
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}正在从 GitHub 克隆 magnet_fix 源码仓库...${RESET}"
        git clone https://github.com/poouo/magnet_fix.git "$INSTALL_DIR"
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: 克隆仓库失败！${RESET}"
            return
        fi
    fi

    cd "$INSTALL_DIR" || return
    load_current_ports

    # 1. 交互式配置 Web 端口（只通过 sed 作用于 magnet-search 到 qbittorrent 之间的行）
    echo -e "\n${CYAN}====== ⚙️ 配置核心磁力站服务端口 ======${RESET}"
    echo -ne "${GREEN}请输入核心磁力站访问 Web 端口 (当前/默认: ${WEBUI_PORT}): ${RESET}"
    read -r input_web_port
    if [[ -n "$input_web_port" ]]; then
        # 精准替换：只修改 magnet-search 块内部的 :8080 端口
        sed -i "/magnet-search:/,/qbittorrent:/ {s/-[[:space:]]*\"[0-9]+:8080\"/- \"$input_web_port:8080\"/g}" docker-compose.yml
        WEBUI_PORT="$input_web_port"
    fi

    # 2. 交互式配置 UDP 端口
    echo -ne "${GREEN}请输入磁力检索 UDP 传输端口 (当前/默认: ${UDP_PORT}): ${RESET}"
    read -r input_udp_port
    if [[ -n "$input_udp_port" ]]; then
        # 精准替换：只修改 magnet-search 块内部的 :6881/udp 端口
        sed -i "/magnet-search:/,/qbittorrent:/ {s/-[[:space:]]*\"[0-9]+:6881\/udp\"/- \"$input_udp_port:6881\/udp\"/g}" docker-compose.yml
        UDP_PORT="$input_udp_port"
    fi
    
    echo -e "${GREEN}核心站端口配置已成功保存！Web端口: $WEBUI_PORT，UDP端口: $UDP_PORT${RESET}\n"

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
        1) docker compose up -d --build magnet-search ;;
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
        echo -e "${YELLOW} 页面服务         地址${RESET}"
        echo -e "${YELLOW} 搜索首页:        http://${DETECT_IP}:${WEBUI_PORT}${RESET}"
        echo -e "${YELLOW} 管理后台:        http://${DETECT_IP}:${WEBUI_PORT}/admin${RESET}"
        echo -e "${YELLOW} 默认后台密码:${RESET}    ${RED}admin123${RESET}"
        [[ "$mode_choice" =~ ^(2|4)$ ]] && echo -e "${YELLOW} qBittorrentUI:  http://${DETECT_IP}:18080${RESET}"
        [[ "$mode_choice" =~ ^(3|4)$ ]] && echo -e "${YELLOW} MySQL 地址:     ${DETECT_IP}:13306${RESET}"
        echo -e "${GREEN}====================================================${RESET}"
    fi
}

# 选项 2：更新容器
update_magnet() {
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${RED}错误: 未检测到安装目录！${RESET}"
        return
    fi

    cd "$INSTALL_DIR" || return
    
    # 暂存本地用户配置过的核心服务端口
    load_current_ports
    
    echo -e "${YELLOW}正在拉取 Git 源码仓库更新...${RESET}"
    git pull
    
    # 拉取更新后，将自定义端口重新应用回 magnet-search 局部区块，确保 qb 端口不受干扰
    sed -i "/magnet-search:/,/qbittorrent:/ {s/-[[:space:]]*\"[0-9]+:8080\"/- \"$WEBUI_PORT:8080\"/g}" docker-compose.yml
    sed -i "/magnet-search:/,/qbittorrent:/ {s/-[[:space:]]*\"[0-9]+:6881\/udp\"/- \"$UDP_PORT:6881\/udp\"/g}" docker-compose.yml

    clear
    echo -e "${CYAN}====== 🔄 请选择需要更新的服务范围 ======${RESET}"
    echo -e " [1] 仅更新/拉取核心磁力站 (不触动/不唤醒 qB 和 MySQL)"
    echo -e " [2] 完全更新当前环境中已存在的所有组件 (根据本地已有容器自动匹配)"
    echo -ne "${GREEN}请选择操作 (1/2): ${RESET}"
    read -r up_choice

    if [ "$up_choice" = "1" ]; then
        echo -e "${YELLOW}正在精准更新核心容器...${RESET}"
        docker compose pull magnet-search
        docker compose up -d --build magnet-search
    elif [ "$up_choice" = "2" ]; then
        local active_profiles=$(get_current_profiles)
        echo -e "${YELLOW}识别到当前关联组件:${RESET} ${active_profiles:-无(仅核心)}"
        echo -e "${YELLOW}正在全面更新关联的组件容器...${RESET}"
        docker compose $active_profiles pull
        docker compose $active_profiles up -d --build
    else
        echo -e "${RED}无效选项，已取消更新。${RESET}"
        return
    fi
    echo -e "${GREEN}更新及重构流程完成！${RESET}"
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

# 基础群控控制
start_magnet() {
    if [ -d "$INSTALL_DIR" ]; then 
        cd "$INSTALL_DIR" || return
        local active_profiles=$(get_current_profiles)
        docker compose $active_profiles start
        echo -e "${GREEN}关联容器已全面拉起！${RESET}"
    fi
}

stop_magnet() {
    if [ -d "$INSTALL_DIR" ]; then 
        cd "$INSTALL_DIR" || return
        local active_profiles=$(get_current_profiles)
        docker compose $active_profiles stop
        echo -e "${YELLOW}关联容器已全面停止！${RESET}"
    fi
}

restart_magnet() {
    if [ -d "$INSTALL_DIR" ]; then 
        cd "$INSTALL_DIR" || return
        local active_profiles=$(get_current_profiles)
        docker compose $active_profiles restart
        echo -e "${GREEN}关联容器已平滑重启！${RESET}"
    fi
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
        load_current_ports
        echo -e "${CYAN}====== 当前环境配置 ======${RESET}"
        echo -e "${YELLOW}安装路径: $INSTALL_DIR${RESET}"
        local active_profiles=$(get_current_profiles)
        echo -e "${YELLOW}当前启用的 Profile: ${active_profiles:-仅核心站点}${RESET}"
        echo -e "${YELLOW}网页映射端口: $WEBUI_PORT${RESET}"
        echo -e "${YELLOW}UDP 传输端口: $UDP_PORT${RESET}"
    else
        echo -e "${RED}未检测到安装配置。${RESET}"
    fi
}

# 主菜单循环
menu() {
    clear
    load_current_ports
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  Magnet-Fix 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态    :${RESET} $status"
    echo -e "${GREEN}网页端口:${RESET} ${YELLOW}${WEBUI_PORT}${RESET}"
    echo -e "${GREEN}UDP 端口:${RESET} ${YELLOW}${UDP_PORT}${RESET}"
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
