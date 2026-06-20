#!/bin/bash
# =================================================================
# TuneScout 音乐全自动补全中心 Docker Compose 运维管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="tunescout"
BASE_DIR="/opt/tunescout"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态及多维挂载卷的真实物理挂载路径
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
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8503/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8503"

        # 提取本地关键物理路径
        path_music_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/music"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_dl_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/download"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_navi_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/navidrome_data"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        
        [[ -z "$path_music_show" ]] && path_music_show="$BASE_DIR/music"
        [[ -z "$path_dl_show" ]] && path_dl_show="$BASE_DIR/download"
        [[ -z "$path_navi_show" ]] && path_navi_show="/vol1/1000/docker/navidrome"
    else
        img_version="N/A"
        webui_port="N/A"
        path_music_show="N/A"
        path_dl_show="N/A"
        path_navi_show="N/A"
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

    echo -e "${CYAN}====== 1. 基础网络与安全防线配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 TuneScout 网页访问映射端口 (宿主机) [默认: 8503]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8503"

    echo -ne "${YELLOW}请设置 Web 控制台登录用户名 [默认: admin]: ${RESET}"
    read -r web_user
    [[ -z "$web_user" ]] && web_user="admin"

    echo -ne "${YELLOW}请设置 Web 控制台登录密码 [默认: yourpassword]: ${RESET}"
    read -r web_pass
    [[ -z "$web_pass" ]] && web_pass="yourpassword"

    echo -e "\n${CYAN}====== 2. 多仓物理文件路径挂载 (绝对路径) ======${RESET}"
    echo -ne "${YELLOW}1. 请输入【本地核心音乐库 ./music】绝对路径 [默认: $BASE_DIR/music]: ${RESET}"
    read -r path_music
    [[ -z "$path_music" ]] && path_music="$BASE_DIR/music"

    echo -ne "${YELLOW}2. 请输入【临时缓冲下载仓 ./download】绝对路径 [默认: $BASE_DIR/download]: ${RESET}"
    read -r path_download
    [[ -z "$path_download" ]] && path_download="$BASE_DIR/download"

    echo -ne "${YELLOW}3. 请输入【Navidrome数据库持久化 ./navidrome_data】主路径 [默认: /vol1/1000/docker/navidrome]: ${RESET}"
    read -r path_navi
    [[ -z "$path_navi" ]] && path_navi="/vol1/1000/docker/navidrome"

    # 核心安全特性：自动创建防呆空文件，避开 Docker 误转文件夹死循环
    echo -e "\n${YELLOW}【自动化预处理】正在智能拦截并补全底层物理依赖空文件...${RESET}"
    mkdir -p "$BASE_DIR" "$path_music" "$path_download" "$path_navi"
    
    # 强制构建空文件依赖
    touch "$BASE_DIR/config.json"
    touch "$BASE_DIR/library_cache.db"
    
    # 注入全通权限
    chmod 777 "$BASE_DIR/config.json" "$BASE_DIR/library_cache.db"
    chmod -R 777 "$path_music" "$path_download" "$path_navi"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在构建符合 TuneScout 联动标准的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  tunescout:
    image: yuwancumian2009/tunescout-v2:latest
    container_name: ${CONTAINER_NAME}
    environment:
      - TZ=Asia/Shanghai
      - WEB_USERNAME=${web_user}
      - WEB_PASSWORD=${web_pass}
      - PUID=1000
      - PGID=1000
      - ND_DB_PATH=/navidrome_data/navidrome.db
      - ND_MUSIC_PREFIX=/music
    volumes:
      - "${BASE_DIR}/config.json:/app/config.json"
      - "${BASE_DIR}/library_cache.db:/app/library_cache.db"
      - "${path_music}:/music"
      - "${path_download}:/download"
      - "${path_navi}:/navidrome_data"
    ports:
      - "${custom_port}:8503"
    restart: unless-stopped
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 编排拉起 TuneScout 搜刮服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待音频搜刮引擎校验本地多盘环境 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}            TuneScout 搜刮中心部署成功！              ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}控制台访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}Web登录管理员账号: ${web_user}${RESET}"
    echo -e "${YELLOW}本地正片音乐物理仓: ${path_music}${RESET}"
    echo -e "${YELLOW}Navidrome数据库源: ${path_navi}${RESET}"
    echo -e "${CYAN}💡 联动运维提示：已自动保护您的 config.json 与缓存数据库挂载。${RESET}"
    echo -e "${CYAN}   由于绑定了 Navidrome 目录，TuneScout 在完成高品质标签搜刮和补全后，${RESET}"
    echo -e "${CYAN}   会自动同步刷新 Navidrome，让您的多端播放器海报墙与内嵌歌词时刻保持完美！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新服务
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 TuneScout 补全仓官方镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！自动化流媒体搜刮服务已平滑重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并停止 TuneScout 搜刮服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时清空本地保存的搜刮规则缓存、核心 config.json 以及搜刮历史？(绝不会动你的音乐原文件)(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                get_status_info
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地的核心配置、缓存数据库文件已被彻底清理。${RESET}"
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
    echo -e "${YELLOW}音乐库本地物理路径: ${path_music_show}${RESET}"
    echo -e "${YELLOW}临时下载本地路径 : ${path_dl_show}${RESET}"
    echo -e "${YELLOW}关联Navidrome路径: ${path_navi_show}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}◈  TuneScout 音乐搜刮管理面板  ◈  ${RESET}"
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
