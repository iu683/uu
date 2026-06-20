#!/bin/bash
# =================================================================
# Navidrome 私有音乐流媒体服务器 Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="navidrome"
BASE_DIR="/opt/navidrome"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取当前系统用户的 UID 和 GID 作为默认安全权限
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)

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

    # 2. 如果容器存在，从容器状态中精准提取挂载信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 提取 Web 映射出来的宿主机端口 (内部默认 4533)
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "4533/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="4533"

        # 提取宿主机数据保存目录
        path_data_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        # 提取宿主机音乐库目录
        path_music_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/music"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        path_data_show="N/A"
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

    echo -e "${CYAN}====== Navidrome 参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Web 访问映射端口 (宿主机) [默认: 4533]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="4533"

    echo -e "\n${CYAN}--- 运行权限配置 (极其重要：需匹配您的音乐文件读写权限) ---${RESET}"
    echo -ne "${YELLOW}请输入运行用户 UID [默认当前用户: ${CURRENT_UID}]: ${RESET}"
    read -r custom_uid
    [[ -z "$custom_uid" ]] && custom_uid="${CURRENT_UID}"

    echo -ne "${YELLOW}请输入运行用户组 GID [默认当前用户组: ${CURRENT_GID}]: ${RESET}"
    read -r custom_gid
    [[ -z "$custom_gid" ]] && custom_gid="${CURRENT_GID}"

    echo -e "\n${CYAN}--- 宿主机目录自定义 (请尽量填绝对路径) ---${RESET}"
    echo -ne "${YELLOW}1. 请输入【数据保存(缓存/歌词/数据库)】路径 [默认: $BASE_DIR/data]: ${RESET}"
    read -r path_data
    [[ -z "$path_data" ]] && path_data="$BASE_DIR/data"

    echo -ne "${YELLOW}2. 请输入【您的音乐库存放文件夹】路径 [默认: $BASE_DIR/music]: ${RESET}"
    read -r path_music
    [[ -z "$path_music" ]] && path_music="$BASE_DIR/music"

    # 自动创建所需目录并授权
    echo -e "\n${YELLOW}正在初始化并检查宿主机目录权限...${RESET}"
    mkdir -p "$path_data" "$path_music"
    
    # 保证数据保存路径对于该 UID 有可写权限
    chown -R "$custom_uid":"$custom_gid" "$path_data"
    chmod -R 755 "$BASE_DIR" "$path_data"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  navidrome:
    image: deluan/navidrome:latest
    user: "${custom_uid}:${custom_gid}"
    container_name: ${CONTAINER_NAME}
    ports:
      - "${custom_port}:4533"
    restart: unless-stopped
    environment:
      - TZ=Asia/Shanghai
      - ND_LOGLEVEL=info
      - ND_DEFAULTLANGUAGE=zh-Hans
      - ND_SCANSCHEDULE=1h
    volumes:
      - "${path_data}:/data"
      - "${path_music}:/music:ro"
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 启动 Navidrome 音乐服务器...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务容器建构完成 (约 3 秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    Navidrome 部署成功！        ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WEB 访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}运行用户权限   : UID:${custom_uid}  GID:${custom_gid}${RESET}"
    echo -e "${YELLOW}数据保存路径   : ${path_data}${RESET}"
    echo -e "${YELLOW}音乐媒体路径   : ${path_music} (只读保护)${RESET}"
    echo -e "${YELLOW}提示: 首次访问请打开网页端注册第一个账号(即为超级管理员)。${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 Navidrome 官方镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已成功安全重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 Navidrome 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地数据保存目录(歌词缓存和账号数据)？(注意: 绝不会删除你的音乐库文件)(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$path_data_show" != "$BASE_DIR"* && -d "$path_data_show" ]] && rm -rf "$path_data_show"
                echo -e "${GREEN}缓存与元数据目录已彻底清理。${RESET}"
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
    echo -e "${YELLOW}数据保存路径   : ${path_data_show}${RESET}"
    echo -e "${YELLOW}音乐媒体路径   : ${path_music_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}◈ Navidrome 私有音乐云管理面板 ◈ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
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
