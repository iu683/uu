#!/bin/bash
# =================================================================
# uPay 支付服务 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="upay_pro"
BASE_DIR="/opt/upay"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

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

    # 2. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取镜像名称/版本
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 从容器状态提取 Web 端口（根据绑定的端口动态获取）
        webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8090"

        # 从容器状态提取外部卷映射路径
        data_dir="使用 Docker 外部数据卷 (upay_logs, upay_db)"
    else
        # 容器未安装/未部署时的返回值
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        data_dir="N/A"
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

# 检查环境是否已经部署
check_compose_exists() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return 1
    fi
    return 0
}

# 部署 uPay
install_upay() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 系统架构检测与参数配置 ======${RESET}"
    
    # 自动识别系统架构并选择镜像 Tag
    local arch
    arch=$(uname -m)
    local image_tag="wangergou111/upay:latest"
    
    if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        image_tag="wangergou111/upay:latest-arm64"
        echo -e "${GREEN}检测到当前机器为 ARM64 架构，自动选择镜像: ${image_tag}${RESET}"
    else
        echo -e "${GREEN}检测到当前机器为 AMD64 架构，自动选择镜像: ${image_tag}${RESET}"
    fi

    echo -ne "${YELLOW}请输入 uPay 访问端口 (宿主机端口) [默认: 8090]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8090"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 1. 自动创建依赖的 Docker 外部数据卷（如果不存在的话）
    echo -e "${YELLOW}正在检查并创建 Docker 外部数据卷...${RESET}"
    docker volume inspect upay_logs &>/dev/null || docker volume create upay_logs
    docker volume inspect upay_db &>/dev/null || docker volume create upay_db

    # 2. 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  upay:
    container_name: ${CONTAINER_NAME}
    image: ${image_tag}
    restart: always
    ports:
      - "${custom_port}:8090"
    volumes:
      - upay_logs:/app/logs
      - upay_db:/app/DBS

volumes:
  upay_logs:
    external: true
    name: upay_logs
  upay_db:
    external: true
    name: upay_db
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 uPay 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    local detect_ip
    detect_ip=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}         uPay 部署成功！        ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${detect_ip}:${custom_port}${RESET}"
    echo -e "${YELLOW}外部卷1 (日志) : upay_logs${RESET}"
    echo -e "${YELLOW}外部卷2 (数据) : upay_db${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${GREEN}常用的快捷接口文档提示：${RESET}"
    echo -e "${YELLOW}1. 创建订单 (POST) : http://${detect_ip}:${custom_port}/api/create_order${RESET}"
    echo -e "${YELLOW}2. 查询状态 (GET)  : http://${detect_ip}:${custom_port}/pay/check-status/{trade_id}${RESET}"
    echo -e "${YELLOW}3. 支付收银台(GET) : http://${detect_ip}:${custom_port}/pay/checkout-counter/{trade_id}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 uPay 镜像
update_upay() {
    check_compose_exists || return
    echo -e "${YELLOW}正在从远端拉取 uPay 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 uPay
uninstall_upay() {
    echo -ne "${YELLOW}确定要卸载并删除 uPay 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地 Compose 配置和 Docker 外部存储数据卷？(y/n): ${RESET}"
            read -r clean_data
            if [[ "$clean_data" == "y" || "$clean_data" == "Y" ]]; then
                rm -rf "$BASE_DIR"
                docker volume rm upay_logs upay_db 2>/dev/null
                echo -e "${GREEN}配置路径与 Docker 外部卷 (upay_logs, upay_db) 已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_upay() { 
    check_compose_exists || return
    cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"
}

stop_upay() { 
    check_compose_exists || return
    cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"
}

restart_upay() { 
    check_compose_exists || return
    cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"
}

logs_upay() { 
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        docker logs -f "$CONTAINER_NAME"
    else
        echo -e "${RED}错误: 容器不存在，无法查看日志！${RESET}"
    fi
}

show_info() {
    get_status_info
    local detect_ip="127.0.0.1"
    if [[ "$webui_port" != "N/A" ]]; then
        detect_ip=$(get_public_ip)
    fi
    
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${detect_ip}:${webui_port}${RESET}"
    echo -e "${YELLOW}存储数据目录   : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      ◈  uPay 管理面板  ◈        ${RESET}"
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
        1) install_upay ;;
        2) update_upay ;;
        3) uninstall_upay ;;
        4) start_upay ;;
        5) stop_upay ;;
        6) restart_upay ;;
        7) logs_upay ;;
        8) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

# 主循环
while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
