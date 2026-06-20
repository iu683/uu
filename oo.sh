#!/bin/bash
# =================================================================
# Reclip 视频切片自动下载器 Docker Compose 自动化管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="reclip"
BASE_DIR="/opt/reclip"
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
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8899/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8899"

        # 提取本地下载卷的真实挂载物理路径
        path_download_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/downloads"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$path_download_show" ]] && path_download_show="$BASE_DIR/downloads"
    else
        img_version="N/A"
        webui_port="N/A"
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
# 部署并配置核心逻辑
install_translate() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 网络访问端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Reclip 后台访问映射端口 (宿主机) [默认: 8899]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8899"

    echo -e "\n${CYAN}====== 2. 物理数据挂载自定义 (绝对路径) ======${RESET}"
    echo -ne "${YELLOW}请输入【切片视频下载 ./downloads】保存绝对路径 [默认: $BASE_DIR/downloads]: ${RESET}"
    read -r path_download
    [[ -z "$path_download" ]] && path_download="$BASE_DIR/downloads"

    # 初始化本地目录，并注入 777 读写权限防止下载流落盘失败
    echo -e "\n${YELLOW}正在初始化文件系统并注入高兼容读写所有权...${RESET}"
    mkdir -p "$path_download"
    chmod -R 777 "$path_download"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在构建符合 Reclip 规范的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  reclip:
    image: reclipd/reclip
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${custom_port}:8899"
    volumes:
      - "${path_download}:/app/downloads"
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 编排拉起 Reclip 核心...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待网关响应完成首次环境搭建 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             Reclip 视频切片控制台部署成功！          ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}后台管理地址     : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}物理视频下载路径 : ${path_download}${RESET}"
    echo -e "${CYAN}💡 进阶使用提示：所有的切片、缓存以及长视频录制成果都会自动保存到主机的 ${path_download} 目录中。${RESET}"
    echo -e "${CYAN}   你可以随时将该物理路径挂载给 Emby、Jellyfin 或 AList 轻松实现全网点播。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新服务
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在检查并同步拉取最新 Reclip 官方映像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！自动化切片提取服务已平滑重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并停止 Reclip 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时清空本地物理存储目录中已下载的所有切片和视频源文件？(删除后不可恢复)(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$path_download_show" != "$BASE_DIR"* && -d "$path_download_show" ]] && rm -rf "$path_download_show"
                echo -e "${GREEN}本地已保存的全部视频文件及缓存已被深度格式化清理。${RESET}"
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
    echo -e "${YELLOW}视频下载本地路径 : ${path_download_show}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}◈ Reclip  自动化视频切片下载器 ◈ ${RESET}"
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
