#!/bin/bash
# =================================================================
# Docker 远程独立浏览器 (KasmVNC 自由切换版) 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/browser-services"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取当前运行的浏览器类型和状态
get_status_info() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        current_browser="无 (未部署)"
        status="${RED}未部署${RESET}"
        webui_port="N/A"
        return
    fi

    # 从 compose 文件中提取当前部署的浏览器镜像名
    if grep -q "chromium" "$COMPOSE_FILE"; then
        current_browser="Chromium (Chrome)"
        container_name="docker-chromium"
    elif grep -q "msedge" "$COMPOSE_FILE"; then
        current_browser="Microsoft Edge"
        container_name="msedge"
    elif grep -q "firefox" "$COMPOSE_FILE"; then
        current_browser="Firefox"
        container_name="firefox"
    elif grep -q "brave" "$COMPOSE_FILE"; then
        current_browser="Brave"
        container_name="brave"
    else
        current_browser="未知"
        container_name=""
    fi

    # 检查容器状态
    if [ -n "$container_name" ] && [ "$(docker ps -q -f name=^/${container_name}$)" ]; then
        status="${GREEN}运行中${RESET}"
        # 提取映射端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "$container_name" 2>/dev/null)
    elif [ -n "$container_name" ] && [ "$(docker ps -aq -f name=^/${container_name}$)" ]; then
        status="${RED}已停止${RESET}"
        webui_port="已配置"
    else
        status="${RED}未运行 (或已被手动删除)${RESET}"
        webui_port="N/A"
    fi
}

get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
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

# 部署核心：选择浏览器并支持自定义参数
install_browser() {
    check_dependencies
    mkdir -p "$BASE_DIR/config"

    clear
    echo -e "${CYAN}====== 请选择要部署切换的浏览器 ======${RESET}"
    echo -e "注：切换浏览器会保留 /config 里的用户数据，但会替换核心容器。"
    echo -e "${GREEN}1. Chromium (Chrome内核)${RESET}"
    echo -e "${GREEN}2. Microsoft Edge${RESET}"
    echo -e "${GREEN}3. Firefox (火狐)${RESET}"
    echo -e "${GREEN}4. Brave Browser${RESET}"
    echo -ne "${YELLOW}请选择编号 (1-4): ${RESET}"
    read -r b_choice

    local img_name=""
    local c_name=""
    local extra_opt=""

    case "$b_choice" in
        1) img_name="lscr.io/linuxserver/chromium:latest"; c_name="docker-chromium" ;;
        2) img_name="lscr.io/linuxserver/msedge:latest"; c_name="msedge" ;;
        3) img_name="lscr.io/linuxserver/firefox:latest"; c_name="firefox"; extra_opt="security_opt:\n      - seccomp:unconfined" ;;
        4) img_name="lscr.io/linuxserver/brave:latest"; c_name="brave" ;;
        *) echo -e "${RED}输入错误，取消部署。${RESET}"; return ;;
    esac

    echo -e "\n${CYAN}====== 自定义高性能参数 ======${RESET}"
    
    # 1. 自定义端口
    echo -ne "${YELLOW}请输入外部 HTTP 访问端口 [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"
    
    # 计算 HTTPS 端口（自动+1）
    local custom_sport=$((custom_port + 1))

    # 2. 自定义共享内存
    echo -ne "${YELLOW}请输入共享内存 shm_size [默认: 1gb, 视内存大小可填 2gb/512mb]: ${RESET}"
    read -r custom_shm
    [[ -z "$custom_shm" ]] && custom_shm="1gb"

    # 3. 自定义密码保护
    echo -ne "${YELLOW}请设置浏览器网页登录用户名 [默认: admin]: ${RESET}"
    read -r c_user
    [[ -z "$c_user" ]] && c_user="admin"

    echo -ne "${YELLOW}请设置浏览器网页登录密码 [默认: password123]: ${RESET}"
    read -r c_pass
    [[ -z "$c_pass" ]] && c_pass="password123"

    # 先停掉旧的浏览器容器，防止端口和挂载产生冲突
    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}正在清理旧的浏览器容器环境...${RESET}"
        cd "$BASE_DIR" && docker compose down --remove-orphans &>/dev/null
    fi

    # 动态渲染单服务的 docker-compose.yml 模板
    echo -e "${YELLOW}正在动态生成最新的 docker-compose.yml 结构...${RESET}"
    
    cat <<EOF > "$COMPOSE_FILE"
version: '3.8'

services:
  browser:
    image: ${img_name}
    container_name: ${c_name}
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
      - INSTALL_PACKAGES=fonts-noto-cjk
      - LC_ALL=zh_CN.UTF-8
      - CUSTOM_USER=${c_user}
      - PASSWORD=${c_pass}
    volumes:
      - ./config:/config
    ports:
      - "${custom_port}:3000"
      - "${custom_sport}:3001"
    shm_size: "${custom_shm}"
    restart: unless-stopped
EOF

    # 如果是火狐，注入无约束安全项
    if [ -n "$extra_opt" ]; then
        sed -i "/restart: unless-stopped/i \    ${extra_opt}" "$COMPOSE_FILE"
    fi

    chmod -R 777 "$BASE_DIR"
    
    echo -e "${YELLOW}正在拉取镜像并拉起浏览器容器...${RESET}"
    cd "$BASE_DIR" && docker compose up -d

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}===============================================${RESET}"
    echo -e "${GREEN}    浏览器环境部署/切换成功！                  ${RESET}"
    echo -e "${GREEN}===============================================${RESET}"
    echo -e "${YELLOW}当前浏览器 : ${img_name}${RESET}"
    echo -e "${YELLOW}HTTP 访问端: http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}统一用户名 : ${c_user}${RESET}"
    echo -e "${YELLOW}统一密  码 : ${c_pass}${RESET}"
    echo -e "${YELLOW}共享内存   : ${custom_shm}${RESET}"
    echo -e "${GREEN}===============================================${RESET}"
}

# 更新镜像
update_browser() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取当前浏览器内核的最新上游镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d
    echo -e "${GREEN}更新成功！容器已重建至最新版本。${RESET}"
}

# 彻底卸载
uninstall_browser() {
    echo -ne "${RED}确定要卸载浏览器容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已被安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除浏览器内部的所有用户配置数据(书签/缓存等)？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地数据目录已彻底清理。${RESET}"
            fi
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_browser() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已拉起启动${RESET}"; }
stop_browser() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已挂起停止${RESET}"; }
restart_browser() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已完成重启${RESET}"; }

logs_browser() {
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose logs -f
    else
        echo -e "${RED}未找到正在运行的浏览器服务${RESET}"
    fi
}

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}===============================================${RESET}"
    echo -e "${YELLOW}当前选用浏览器 : ${current_browser}"
    echo -e "${YELLOW}内核服务状态   : ${status}"
    echo -e "${YELLOW}内网/外网访问  : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}数据挂载路径   : ${BASE_DIR}/config${RESET}"
    echo -e "${GREEN}===============================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}    ◈  Docker 远程浏览器管理面板  ◈     ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 当前选用类型 :${RESET} ${CYAN}${current_browser}${RESET}"
    echo -e "${GREEN} 容器运行状态 :${RESET} ${status}"
    echo -e "${GREEN} Web 访问端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}1. 部署/切换浏览器${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_browser ;;
        2) update_browser ;;
        3) uninstall_browser ;;
        4) start_browser ;;
        5) stop_browser ;;
        6) restart_browser ;;
        7) logs_browser ;;
        8) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
