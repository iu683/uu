#!/bin/bash
# =================================================================
# nowen-video 影视媒体中心 自动化集成与卷路径自适应管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="nowen-video"
BASE_DIR="/opt/nowen-video"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、内部网络 DNS 及挂载目录状况
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

        # 提取宿主机映射出来的端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8080"

        # 提取本地 Data、Cache 与 Media 真实路径
        path_data_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_cache_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/cache"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_media_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/media"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$path_data_show" ]] && path_data_show="$BASE_DIR/data"
        [[ -z "$path_cache_show" ]] && path_cache_show="$BASE_DIR/cache"
        [[ -z "$path_media_show" ]] && path_media_show="/vol01/Media"
    else
        img_version="N/A"
        webui_port="N/A"
        path_data_show="N/A"
        path_cache_show="N/A"
        path_media_show="N/A"
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

    echo -e "${CYAN}====== 1. 基础网络端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 nowen-video 网页访问映射端口 (宿主机) [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"

    echo -e "\n${CYAN}====== 2. 本地数据与媒体挂载自定义 (绝对路径) ======${RESET}"
    echo -e "${GREEN}提示：为了确保媒体刮削与访问正常，请正确填写数据库存储、缓存及媒体库路径。${RESET}"
    
    echo -ne "${YELLOW}1. 请输入【本地程序数据 ./data】保存路径 [默认: $BASE_DIR/data]: ${RESET}"
    read -r path_data
    [[ -z "$path_data" ]] && path_data="$BASE_DIR/data"

    echo -ne "${YELLOW}2. 请输入【转码缓存 ./cache】存储路径 [默认: $BASE_DIR/cache]: ${RESET}"
    read -r path_cache
    [[ -z "$path_cache" ]] && path_cache="$BASE_DIR/cache"

    echo -ne "${YELLOW}3. 请输入【媒体库目录】挂载路径 [默认: /vol01/Media]: ${RESET}"
    read -r path_media
    [[ -z "$path_media" ]] && path_media="/vol01/Media"

    # 初始化本地目录，赋予 777 最高权限，防止数据库写入和缓存失败
    echo -e "\n${YELLOW}正在对本地文件系统执行高兼容权限初始化...${RESET}"
    mkdir -p "$path_data" "$path_cache"
    chmod -R 777 "$path_data" "$path_cache"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在构建符合 nowen-video 部署规范的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
version: '3.8'

services:
  nowen-video:
    image: cropflre/nowen-video:latest
    container_name: ${CONTAINER_NAME}
    user: "0:0"
    privileged: true
    cap_add:
      - SYS_ADMIN
      - NET_ADMIN
      - SYS_PTRACE
      - DAC_READ_SEARCH
    security_opt:
      - apparmor:unconfined
      - seccomp:unconfined
    ports:
      - "${custom_port}:8080"
    volumes:
      - "${path_data}:/data"
      - "${path_cache}:/cache"
      - "${path_media}:/media"
    devices:
      - /dev/dri:/dev/dri
      - /dev/fuse:/dev/fuse
    environment:
      - NOWEN_APP_PORT=8080
      - NOWEN_APP_DATA_DIR=/data
      - NOWEN_APP_WEB_DIR=/app/web/dist
      - PUID=0
      - PGID=0
      - UMASK=000
      - NOWEN_DATABASE_DB_PATH=/data/nowen.db
      - NOWEN_SECRETS_JWT_SECRET=please-change-this-secret-key
      - NOWEN_CACHE_CACHE_DIR=/cache
      - NOWEN_LOGGING_LEVEL=info
      - NOWEN_ADULT_SCRAPER_ENABLED=false
      - NOWEN_ADULT_SCRAPER_AUTO_START_PYTHON=true
      - NOWEN_ADULT_SCRAPER_PYTHON_EXECUTABLE=/usr/bin/python3
      - NOWEN_ADULT_SCRAPER_PYTHON_SERVICE_DIR=/app/scripts/adult-scraper
      - TZ=Asia/Shanghai
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 1G
        reservations:
          memory: 256M
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 部署 nowen-video 影视中心...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务构建并完成首次环境初始化 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}           nowen-video 部署成功！                   ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}后台管理地址     : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}默认管理员账号   : 首次访问网页时注册的第一个账号${RESET}"
    echo -e "${YELLOW}数据存储本地路径 : ${path_data}${RESET}"
    echo -e "${YELLOW}缓存存储本地路径 : ${path_cache}${RESET}"
    echo -e "${YELLOW}媒体库挂载路径   : ${path_media}${RESET}"
    echo -e "${CYAN}💡 进阶提示：首次登录后可前往管理后台进行刮削与用户设置。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新服务
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 nowen-video 官方发布映像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！影视服务已平滑重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 nowen-video 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地保存的数据库、缓存及配置？(绝不会删除你的原始影视媒体文件)(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$path_data_show" != "$BASE_DIR"* && -d "$path_data_show" ]] && rm -rf "$path_data_show"
                [[ "$path_cache_show" != "$BASE_DIR"* && -d "$path_cache_show" ]] && rm -rf "$path_cache_show"
                echo -e "${GREEN}所有相关的本地 nowen-video 数据库及缓存已彻底清理。${RESET}"
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
    echo -e "${YELLOW}Web 后台访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}数据存储本地路径 : ${path_data_show}${RESET}"
    echo -e "${YELLOW}缓存存储本地路径 : ${path_cache_show}${RESET}"
    echo -e "${YELLOW}媒体库挂载路径   : ${path_media_show}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}◈ nowen-video 影视媒体中心管理面板 ◈ ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}====================================${RESET}"
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
