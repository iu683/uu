#!/bin/bash
# =================================================================
# LrcApi 歌词接口工具 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="lrcapi"
BASE_DIR="/opt/lrcapi"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 自动生成一个默认鉴权 Key 的辅助函数
generate_auth_key() {
    if command -v openssl &> /dev/null; then
        openssl_rand=$(openssl rand -hex 8 2>/dev/null)
        if [[ -n "$openssl_rand" ]]; then
            echo "lrc_$openssl_rand"
            return 0
        fi
    fi
    echo "lrc_key_$((RANDOM % 8999 + 1000))"
}

# 动态获取容器状态、映射端口、鉴权秘钥和数据目录（精准修复版）
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，精准提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 提取端口 (内部默认 28883)
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "28883/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="28883"

        # 【精准修复路径抓取】直接获取第一个挂载卷的 Source 和 Destination
        path_music_show=$(docker inspect -f '{{range .Mounts}}{{.Source}}{{break}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_container_show=$(docker inspect -f '{{range .Mounts}}{{.Destination}}{{break}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$path_music_show" ]] && path_music_show="未检测到挂载"
        [[ -z "$path_container_show" ]] && path_container_show="未检测到挂载"

        # 【精准修复环境变量抓取】直接遍历并提取包含 API_AUTH= 的整行
        auth_key_show=$(docker inspect -f '{{range .Config.Env}}{{if ge (len .) 9}}{{if eq (slice . 0 9) "API_AUTH="}}{{.}}{{end}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | awk -F'=' '{print $2}')
        [[ -z "$auth_key_show" ]] && auth_key_show="未检测到/无鉴权"
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        path_music_show="N/A"
        path_container_show="N/A"
        auth_key_show="N/A"
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

    echo -e "${CYAN}====== LrcApi 歌词接口参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入服务访问映射端口 (宿主机) [默认: 28883]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="28883"

    DEFAULT_KEY=$(generate_auth_key)
    echo -e "\n${CYAN}--- 安全鉴权配置 (API_AUTH) ---${RESET}"
    echo -ne "${YELLOW}请输入自定义鉴权 Key [默认自动生成: ${DEFAULT_KEY}]: ${RESET}"
    read -r custom_auth
    [[ -z "$custom_auth" ]] && custom_auth="${DEFAULT_KEY}"

    echo -e "\n${CYAN}--- 双向绝对路径同步挂载 ---${RESET}"
    echo -e "${GREEN}提示: 接下来输入的路径将同时作为【宿主机】与【容器内部】的等价路径映射。${RESET}"
    echo -ne "${YELLOW}请输入您的音乐媒体存储绝对目录 [示例: /www/path/music]: ${RESET}"
    read -r path_music
    
    if [[ -z "$path_music" ]]; then
        path_music="/opt/navidrome/music"
        echo -e "${YELLOW}由于未输入，已采用默认路径: ${path_music}${RESET}"
    fi

    mkdir -p "$path_music"
    chmod -R 777 "$path_music"

    echo -e "\n${YELLOW}正在生成符合双向一致规则的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  lrcapi:
    image: hisatri/lrcapi:latest
    container_name: ${CONTAINER_NAME}
    ports:
      - "${custom_port}:28883"
    volumes:
      - "${path_music}:${path_music}"
    environment:
      - API_AUTH=${custom_auth}
    restart: always
EOF

    echo -e "\n${YELLOW}正在通过 Docker Compose 启动 LrcApi 歌词接口...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     LrcApi 部署成功！          ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}API 接口访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}当前接口鉴权 Key : ${CYAN}${custom_auth}${RESET}"
    echo -e "${YELLOW}等价映射规则     : ${path_music} : ${path_music}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 LrcApi 官方镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！接口已安全重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 LrcApi 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否彻底删除 LrcApi 自身的 Compose 配置文件？(注意：绝不会删除您的任何音乐文件)(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}LrcApi 管理配置已彻底清理。${RESET}"
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
    echo -e "${YELLOW}API 接口地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}接口鉴权密码   : ${CYAN}${auth_key_show}${RESET}"
    echo -e "${YELLOW}宿主机音乐路径 : ${path_music_show}${RESET}"
    echo -e "${YELLOW}容器内映射路径 : ${path_container_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} ◈ LrcApi 自动歌词下载接口面板 ◈ ${RESET}"
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
