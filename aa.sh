#!/bin/bash
# =================================================================
# LX-Music Sync Server 洛雪同步中心 Docker 自动化集群管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="lx-sync-server"
BASE_DIR="/opt/lx-sync-server"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态及多个独立数据卷的物理挂载路径
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="latest"

        # 提取 Web 访问端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "9527/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="9527"

        # 提取本地多类别挂载物理路径
        path_data_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/server/data"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_logs_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/server/logs"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_cache_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/server/cache"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_music_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/server/music"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        
        [[ -z "$path_data_show" ]] && path_data_show="$BASE_DIR/data"
        [[ -z "$path_logs_show" ]] && path_logs_show="$BASE_DIR/logs"
        [[ -z "$path_cache_show" ]] && path_cache_show="$BASE_DIR/cache"
        [[ -z "$path_music_show" ]] && path_music_show="$BASE_DIR/music"
    else
        img_version="N/A"
        webui_port="N/A"
        path_data_show="N/A"
        path_logs_show="N/A"
        path_cache_show="N/A"
        path_music_show="N/A"
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

# 部署核心逻辑
install_translate() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 同步网关端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入洛雪同步网关映射端口 (宿主机) [默认: 9527]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="9527"

    echo -e "\n${CYAN}====== 2. 数据与音乐卷挂载 (绝对路径) ======${RESET}"
    echo -ne "${YELLOW}1. 请输入【歌单数据仓 ./data】保存路径 [默认: $BASE_DIR/data]: ${RESET}"
    read -r path_data
    [[ -z "$path_data" ]] && path_data="$BASE_DIR/data"

    echo -ne "${YELLOW}2. 请输入【系统日志仓 ./logs】保存路径 [默认: $BASE_DIR/logs]: ${RESET}"
    read -r path_logs
    [[ -z "$path_logs" ]] && path_logs="$BASE_DIR/logs"

    echo -ne "${YELLOW}3. 请输入【同步缓存仓 ./cache】保存路径 [默认: $BASE_DIR/cache]: ${RESET}"
    read -r path_cache
    [[ -z "$path_cache" ]] && path_cache="$BASE_DIR/cache"

    echo -ne "${YELLOW}4. 请输入【本地音乐仓 ./music】保存路径 [默认: $BASE_DIR/music]: ${RESET}"
    read -r path_music
    [[ -z "$path_music" ]] && path_music="$BASE_DIR/music"

    # 批量创建本地目录并赋予高兼容读写权限
    echo -e "\n${YELLOW}正在批量初始化本地存储仓及多维文件读写权限...${RESET}"
    mkdir -p "$path_data" "$path_logs" "$path_cache" "$path_music"
    chmod -R 777 "$path_data" "$path_logs" "$path_cache" "$path_music"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在构建符合洛雪音乐规范的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  lx-sync-server:
    image: xcq0607/lxserver:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${custom_port}:9527"
    volumes:
      - "${path_data}:/server/data"
      - "${path_logs}:/server/logs"
      - "${path_cache}:/server/cache"
      - "${path_music}:/server/music"
    environment:
      - NODE_ENV=production
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 部署 LX-Music 同步核心...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务绑定并生成核心环境 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}            LX-Music 同步中心部署成功！              ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}同步连接地址     : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}歌单数据存储路径 : ${path_data}${RESET}"
    echo -e "${YELLOW}音乐网盘本地路径 : ${path_music}${RESET}"
    echo -e "${CYAN}💡 客户端连接指引：打开洛雪音乐桌面端或手机端 -> 设置 -> 同步设置。${RESET}"
    echo -e "${CYAN}   勾选启用同步服务，并在连接中填入：http://${DETECT_IP}:${custom_port} 即可实现全端数据打通！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新服务
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新洛雪同步服务端镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！同步网关已平滑重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除洛雪同步中心吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时彻底清理本地保存的所有歌单、同步快照及音乐缓存？(若音乐仓放了本地歌文件请谨慎选择)(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$path_data_show" != "$BASE_DIR"* && -d "$path_data_show" ]] && rm -rf "$path_data_show"
                [[ "$path_logs_show" != "$BASE_DIR"* && -d "$path_logs_show" ]] && rm -rf "$path_logs_show"
                [[ "$path_cache_show" != "$BASE_DIR"* && -d "$path_cache_show" ]] && rm -rf "$path_cache_show"
                [[ "$path_music_show" != "$BASE_DIR"* && -d "$path_music_show" ]] && rm -rf "$path_music_show"
                echo -e "${GREEN}所有本地的歌单快照、配置备份及通信缓存已全部深度清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_translate() { docker logs -f --tail=100 "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态     : $status"
    echo -e "${YELLOW}核心镜像版本     : ${img_version}${RESET}"
    echo -e "${YELLOW}同步服务映射地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}歌单数据本地路径 : ${path_data_show}${RESET}"
    echo -e "${YELLOW}音乐本地存储路径 : ${path_music_show}${RESET}"
    echo -e "${YELLOW}缓存与日志路径   : ${path_cache_show} | ${path_logs_show}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}◈LX-Music Sync Server 管理面板◈${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态    :${RESET} $status"
    echo -e "${GREEN}端口    :${RESET} ${YELLOW}${webui_port}${RESET}"
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
        1) install_translate ;;
        2) update_translate ;;
        3) uninstall_translate ;;
        4) start_translate ;;
        5) stop_translate ;;
        6) restart_translate ;;
        7) logs_translate ;;
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
