#!/bin/bash
# =================================================================
# Music-Tag-Web 音乐标签刮削工具 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="music-tag-web"
BASE_DIR="/opt/music-tag"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口和各数据目录
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中精准提取各个挂载路径
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 提取 WebUI 映射出来的宿主机端口 (内部默认 8002)
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8002/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8002"

        # 提取宿主机音乐目录
        path_music_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/media"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        # 提取宿主机配置目录
        path_config_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        # 提取宿主机下载监控目录
        path_download_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/download"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        path_music_show="N/A"
        path_config_show="N/A"
        path_download_show="N/A"
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

    echo -e "${CYAN}====== Music-Tag-Web 参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入后台 WebUI 访问映射端口 (宿主机) [默认: 8002]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8002"

    echo -e "\n${CYAN}--- 宿主机目录自定义 (请尽量填绝对路径) ---${RESET}"
    
    echo -ne "${YELLOW}1. 请输入 NAS 上的【音乐文件夹】绝对路径 [默认: $BASE_DIR/music]: ${RESET}"
    read -r path_music
    [[ -z "$path_music" ]] && path_music="$BASE_DIR/music"

    echo -ne "${YELLOW}2. 请输入【配置文件】存储目录路径 [默认: $BASE_DIR/config]: ${RESET}"
    read -r path_config
    [[ -z "$path_config" ]] && path_config="$BASE_DIR/config"

    echo -ne "${YELLOW}3. 请输入【后台刮削监控下载】目录路径 (勿与媒体库重复) [默认: $BASE_DIR/download]: ${RESET}"
    read -r path_download
    [[ -z "$path_download" ]] && path_download="$BASE_DIR/download"

    # 自动创建所需目录并授权
    echo -e "\n${YELLOW}正在初始化并检查宿主机目录...${RESET}"
    mkdir -p "$path_music" "$path_config" "$path_download"
    chmod -R 777 "$BASE_DIR" "$path_music" "$path_config" "$path_download"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  music-tag:
    image: xhongc/music_tag_web:latest
    container_name: ${CONTAINER_NAME}
    ports:
      - "${custom_port}:8002"
    volumes:
      - "${path_music}:/app/media"
      - "${path_config}:/app/data"
      - "${path_download}:/app/download"
    restart: always
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 启动 Music-Tag-Web 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务初始化 (约 3 秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   Music-Tag-Web 部署成功！     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WEB 访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}音乐文件夹路径 : ${path_music}${RESET}"
    echo -e "${YELLOW}配置存储路径   : ${path_config}${RESET}"
    echo -e "${YELLOW}监控下载路径   : ${path_download}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 Music-Tag-Web 镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已成功重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 Music-Tag-Web 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除配置文件和下载监控目录？(注意: 绝不会删除你的音乐媒体库)(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                # 安全卸载，保留可能存在于非 BASE_DIR 的音乐库
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$path_config_show" != "$BASE_DIR"* && -d "$path_config_show" ]] && rm -rf "$path_config_show"
                [[ "$path_download_show" != "$BASE_DIR"* && -d "$path_download_show" ]] && rm -rf "$path_download_show"
                echo -e "${GREEN}相关配置与下载缓存数据目录已彻底清理。${RESET}"
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
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}核心镜像       : ${img_version}${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}宿主机音乐目录 : ${path_music_show}${RESET}"
    echo -e "${YELLOW}宿主机配置目录 : ${path_config_show}${RESET}"
    echo -e "${YELLOW}监控下载目录   : ${path_download_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}◈Music-Tag-Web 音乐标签刮削面板◈ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态    :${RESET} $status"
    echo -e "${GREEN}Web端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
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
