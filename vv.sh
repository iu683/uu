#!/bin/bash
# =================================================================
# Random Image API 专属 Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="random-image-api"
# 默认主配置目录
DEFAULT_BASE_DIR="/opt/random-image-api"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口和数据目录
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中动态提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取镜像名称/版本
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 从容器状态提取 WebUI 端口 (容器内监听的是 3007)
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3007/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3007"

        # 动态提取自定义挂载路径
        custom_data_dir=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        
        # 定位 docker-compose.yml 的存放位置
        if [[ -n "$custom_data_dir" ]]; then
            BASE_DIR=$(dirname "$custom_data_dir")
        fi
    fi
    
    # 兜底路径
    [[ -z "$BASE_DIR" || "$BASE_DIR" == "." ]] && BASE_DIR="$DEFAULT_BASE_DIR"
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
    [[ -z "$custom_data_dir" ]] && custom_data_dir="$BASE_DIR/data"
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

# 部署 Random Image API
install_api() {
    check_dependencies
    
    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 端口配置
    echo -ne "${YELLOW}请输入服务访问端口 [默认: 3007]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3007"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 2. 主脚本与 Compose 存放目录
    echo -ne "${YELLOW}请输入面板配置文件存放路径 [默认: $DEFAULT_BASE_DIR]: ${RESET}"
    read -r input_base
    [[ -z "$input_base" ]] && input_base="$DEFAULT_BASE_DIR"
    BASE_DIR="$input_base"
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

    # 3. 自定义 data 目录
    echo -ne "${YELLOW}请输入【系统数据(data)】宿主机存储绝对路径 [默认: $BASE_DIR/data]: ${RESET}"
    read -r input_data
    [[ -z "$input_data" ]] && input_data="$BASE_DIR/data"
    custom_data_dir="$input_data"

    # 4. 环境变量配置
    echo -ne "${YELLOW}请输入 Lsky Pro API 地址 (LSKY_API_URL): ${RESET}"
    read -r lsky_url
    
    echo -ne "${YELLOW}请输入 Lsky Pro Token (LSKY_TOKEN): ${RESET}"
    read -r lsky_token
    
    echo -ne "${YELLOW}请输入网页自定义标题 (CUSTOM_TITLE) [默认: 随机图片API]: ${RESET}"
    read -r custom_title
    [[ -z "$custom_title" ]] && custom_title="随机图片API"
    
    # 创建所有用户自定义的目录并赋权
    mkdir -p "$BASE_DIR"
    mkdir -p "$custom_data_dir"
    chmod -R 777 "$BASE_DIR" "$custom_data_dir"

    # 生成 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  random-image-api:
    image: libyte/random-image-api:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${custom_port}:3007"
    environment:
      - LSKY_API_URL=${lsky_url}
      - LSKY_TOKEN=${lsky_token}
      - CUSTOM_TITLE=${custom_title}
    volumes:
      - ${custom_data_dir}:/app/data
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Random Image API 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}=====================================================${RESET}"
    echo -e "${GREEN}              Random Image API 部署成功！            ${RESET}"
    echo -e "${GREEN}=====================================================${RESET}"
    echo -e "${YELLOW}数据目录路径 ：$custom_data_dir${RESET}"
    echo -e "${CYAN}服务访问预览 ：${RESET}"
    echo -e "${GREEN}1. 主页预览  : http://${DETECT_IP}:${custom_port}/  - 好看图片页面${RESET}"
    echo -e "${GREEN}2. 直接图片  : http://${DETECT_IP}:${custom_port}/api  - 纯图片，刷新换图${RESET}"
    echo -e "${GREEN}3. JSON 数据 : http://${DETECT_IP}:${custom_port}/?format=json  - 程序调用${RESET}"
    echo -e "${GREEN}=====================================================${RESET}"
}

# 更新镜像
update_api() {
    get_status_info
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Random Image API 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载容器
uninstall_api() {
    get_status_info
    echo -ne "${YELLOW}确定要卸载并删除 Random Image API 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有自定义的数据和配置文件吗？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                rm -rf "$custom_data_dir"
                echo -e "${GREEN}所有自定义数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_api() { get_status_info && cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_api() { get_status_info && cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_api() { get_status_info && cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_api() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}=====================================================${RESET}"
    echo -e "${YELLOW}当前状态     : $status"
    echo -e "${YELLOW}镜像名称     : ${img_version}${RESET}"
    echo -e "${YELLOW}数据目录路径 : ${custom_data_dir}${RESET}"
    echo -e "${CYAN}接口访问地址 ：${RESET}"
    echo -e "${GREEN}主页预览  : http://${DETECT_IP}:${webui_port}/${RESET}"
    echo -e "${GREEN}直接图片  : http://${DETECT_IP}:${webui_port}/api${RESET}"
    echo -e "${GREEN}JSON 数据 : http://${DETECT_IP}:${webui_port}/?format=json${RESET}"
    echo -e "${GREEN}=====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} ◈  Random Image API 管理面板 ◈ ${RESET}"
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
        1) install_api ;;
        2) update_api ;;
        3) uninstall_api ;;
        4) start_api ;;
        5) stop_api ;;
        6) restart_api ;;
        7) logs_api ;;
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
