#!/bin/bash
# =================================================================
# Audiobookshelf 有声书与播客电台 Docker Compose 自动化管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="audiobookshelf"
BASE_DIR="/opt/audiobookshelf"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态及多品类书架的真实物理挂载路径
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
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="43378"

        # 提取本地多类别挂载物理路径
        path_config_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_meta_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/metadata"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_audio_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/audiobooks"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_podcast_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/podcasts"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        
        [[ -z "$path_config_show" ]] && path_config_show="$BASE_DIR/config"
        [[ -z "$path_meta_show" ]] && path_meta_show="$BASE_DIR/metadata"
        [[ -z "$path_audio_show" ]] && path_audio_show="$BASE_DIR/audiobooks"
        [[ -z "$path_podcast_show" ]] && path_podcast_show="$BASE_DIR/podcasts"
    else
        img_version="N/A"
        webui_port="N/A"
        path_config_show="N/A"
        path_meta_show="N/A"
        path_audio_show="N/A"
        path_podcast_show="N/A"
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

# 部署并配置多目录核心逻辑
install_translate() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 网络访问端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Audiobookshelf 网页访问端口 (宿主机) [默认: 43378]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="43378"

    echo -e "\n${CYAN}====== 2. 分类媒体仓挂载自定义 (绝对路径) ======${RESET}"
    echo -ne "${YELLOW}1. 请输入【程序系统配置 ./config】保存路径 [默认: $BASE_DIR/config]: ${RESET}"
    read -r path_config
    [[ -z "$path_config" ]] && path_config="$BASE_DIR/config"

    echo -ne "${YELLOW}2. 请输入【书籍元数据 ./metadata】保存路径 [默认: $BASE_DIR/metadata]: ${RESET}"
    read -r path_meta
    [[ -z "$path_meta" ]] && path_meta="$BASE_DIR/metadata"

    echo -ne "${YELLOW}3. 请输入【有声书音频库 ./audiobooks】本地路径 [默认: $BASE_DIR/audiobooks]: ${RESET}"
    read -r path_audio
    [[ -z "$path_audio" ]] && path_audio="$BASE_DIR/audiobooks"

    echo -ne "${YELLOW}4. 请输入【网络播客电台 ./podcasts】本地路径 [默认: $BASE_DIR/podcasts]: ${RESET}"
    read -r path_podcast
    [[ -z "$path_podcast" ]] && path_podcast="$BASE_DIR/podcasts"

    # 批量创建本地分类目录并赋予高兼容读写权限
    echo -e "\n${YELLOW}正在批量初始化 Audiobookshelf 核心矩阵仓及多维文件读写权限...${RESET}"
    mkdir -p "$path_config" "$path_meta" "$path_audio" "$path_podcast"
    chmod -R 777 "$path_config" "$path_meta" "$path_audio" "$path_podcast"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在构建符合规范的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  audiobookshelf:
    image: ghcr.io/advplyr/audiobookshelf:latest
    container_name: ${CONTAINER_NAME}
    ports:
      - "${custom_port}:80"
    volumes:
      - "${path_config}:/config"
      - "${path_meta}:/metadata"
      - "${path_audio}:/audiobooks"
      - "${path_podcast}:/podcasts"
    environment:
      - TZ=Asia/Shanghai
    restart: unless-stopped
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 编排启动 Audiobookshelf 广播中心...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待音频服务端加载数据库环境 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}           Audiobookshelf 服务端部署成功！              ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}Web 后台访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}系统主配置路径   : ${path_config}${RESET}"
    echo -e "${YELLOW}有声书媒体仓路径 : ${path_audio}${RESET}"
    echo -e "${YELLOW}播客流媒体路径   : ${path_podcast}${RESET}"
    echo -e "${CYAN}💡 客户端与初始化提示：首次登录进入 Web 页面请根据提示注册 root 管理员账户。${RESET}"
    echo -e "${CYAN}   后台关联媒体库时，直接选择容器内对应的【 /audiobooks 】或【 /podcasts 】即可。${RESET}"
    echo -e "${CYAN}   下载官方手机 App 后，服务器地址填写 http://${DETECT_IP}:${custom_port} 即可多端畅听！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新服务
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在同步拉取最新 Audiobookshelf 官方发布版镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！有声书流媒体网关已平滑重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 Audiobookshelf 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地保存的媒体元数据、刮削海报及播放进度数据库？(⚠️绝不会动你的音频、播客原文件)(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$path_config_show" != "$BASE_DIR"* && -d "$path_config_show" ]] && rm -rf "$path_config_show"
                [[ "$path_meta_show" != "$BASE_DIR"* && -d "$path_meta_show" ]] && rm -rf "$path_meta_show"
                echo -e "${GREEN}所有本地的账户关系、流媒体元数据及缓存已彻底清理。${RESET}"
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
    echo -e "${YELLOW}系统配置本地路径 : ${path_config_show}${RESET}"
    echo -e "${YELLOW}元数据缓存路径   : ${path_meta_show}${RESET}"
    echo -e "${YELLOW}有声书本地物理路径: ${path_audio_show}${RESET}"
    echo -e "${YELLOW}播客电台本地路径 : ${path_podcast_show}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}======================================${RESET}"
    echo -e "${GREEN}◈ Audiobookshelf 有声书/播客管理面板 ◈ ${RESET}"
    echo -e "${GREEN}======================================${RESET}"
    echo -e "${GREEN}状态    :${RESET} $status"
    echo -e "${GREEN}端口    :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}======================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}======================================${RESET}"
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
