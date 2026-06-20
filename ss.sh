#!/bin/bash
# =================================================================
# MHTI 媒体自动化处理工具 Docker Compose 集成管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="mhti"
BASE_DIR="/opt/mhti"
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
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8000"

        # 提取本地多类别挂载物理路径
        path_data_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_media_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/media"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_output_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/output"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        
        [[ -z "$path_data_show" ]] && path_data_show="$BASE_DIR/data"
        [[ -z "$path_media_show" ]] && path_media_show="$BASE_DIR/media"
        [[ -z "$path_output_show" ]] && path_output_show="$BASE_DIR/output"
    else
        img_version="N/A"
        webui_port="N/A"
        path_data_show="N/A"
        path_media_show="N/A"
        path_output_show="N/A"
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
    echo -ne "${YELLOW}请输入 MHTI 网页访问映射端口 (宿主机) [默认: 8000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8000"

    echo -e "\n${CYAN}====== 2. 媒体库与输出路径挂载 (绝对路径) ======${RESET}"
    echo -ne "${YELLOW}1. 请输入【系统程序数据 ./data】保存路径 [默认: $BASE_DIR/data]: ${RESET}"
    read -r path_data
    [[ -z "$path_data" ]] && path_data="$BASE_DIR/data"

    echo -ne "${YELLOW}2. 请输入【原始视频媒体库 ./media】主路径 (只读安全挂载) [默认: $BASE_DIR/media]: ${RESET}"
    read -r path_media
    [[ -z "$path_media" ]] && path_media="$BASE_DIR/media"

    echo -ne "${YELLOW}3. 请输入【自动化结果输出 ./output】存储路径 [默认: $BASE_DIR/output]: ${RESET}"
    read -r path_output
    [[ -z "$path_output" ]] && path_output="$BASE_DIR/output"

    # 批量创建本地分类目录并赋予高兼容读写权限 (media层仅创建，容器内通过:ro控制只读)
    echo -e "\n${YELLOW}正在批量初始化本地存储仓与安全权限结构...${RESET}"
    mkdir -p "$path_data" "$path_media" "$path_output"
    chmod -R 777 "$path_data" "$path_output"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在构建符合 MHTI 生产规范的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  mhti:
    image: xiyan520/mhti:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${custom_port}:8000"
    volumes:
      - "${path_data}:/app/data"
      - "${path_media}:/media:ro"
      - "${path_output}:/output"
    environment:
      - TZ=Asia/Shanghai
      - DATA_DIR=/app/data
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 部署 MHTI 服务端...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待 MHTI 完成首次环境环境初始化 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}              MHTI 服务端部署成功！                ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}Web 后台访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}持久化配置路径   : ${path_data}${RESET}"
    echo -e "${YELLOW}媒体仓路径(只读) : ${path_media}${RESET}"
    echo -e "${YELLOW}结果输出存储路径 : ${path_output}${RESET}"
    echo -e "${CYAN}💡 进阶安全提示：已启用 \":ro\" 只读磁盘机制。${RESET}"
    echo -e "${CYAN}   MHTI 仅能读取 ${path_media} 内的视频，绝不会由于误操作破坏或删减源盘文件！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新服务
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 MHTI 官方发布镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！MHTI 自动化服务已平滑重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 MHTI 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地保存的 MHTI 运行参数及缓存数据库？(绝不会动你的媒体原文件)(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$path_data_show" != "$BASE_DIR"* && -d "$path_data_show" ]] && rm -rf "$path_data_show"
                echo -e "${GREEN}所有本地的 MHTI 任务队列、日志及缓存数据已彻底清理。${RESET}"
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
    echo -e "${YELLOW}系统持久化数据路径: ${path_data_show}${RESET}"
    echo -e "${YELLOW}媒体仓本地路径(ro): ${path_media_show}${RESET}"
    echo -e "${YELLOW}结果输出本地路径 : ${path_output_show}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈  MHTI 里番刮削管理面板  ◈   ${RESET}"
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
