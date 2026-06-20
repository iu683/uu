#!/bin/bash
# =================================================================
# Emby-Proxy-Go 高性能流媒体代理网关 Docker Compose 自动化管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="emby-proxy"
BASE_DIR="/opt/emby-proxy"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态及网络端口映射
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
        [[ -z "$img_version" ]] && img_version="v1.3"

        # 提取 Web 访问端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="22567"
    else
        img_version="N/A"
        webui_port="N/A"
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

    echo -e "${CYAN}====== 1. 网络代理网关端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Emby-Proxy 外网代理监听端口 [默认: 22567]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="22567"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "\n${YELLOW}正在构建符合高性能规范的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  emby-proxy:
    image: ghcr.io/gsy-allen/emby-proxy-go:v1.3
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${custom_port}:8080"
    logging:
      driver: 'local'
      options:
        max-size: '10m'
        max-file: '5'
    environment:
      LISTEN_ADDR: ':8080'
      BLOCK_PRIVATE_TARGETS: 'true'
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 启动 Emby-Proxy 高性能网关...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待 Go 代理引擎拉起网络端口 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}           Emby-Proxy 网关部署成功！              ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}代理公网入口地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}日志滚动安全策略 : local (最大 10MB * 5 自动截断，拒绝爆盘)${RESET}"
    echo -e "${YELLOW}安全沙箱防护     : BLOCK_PRIVATE_TARGETS=true (已拒绝探测内网)${RESET}"
    echo -e "${CYAN}🌐 使用方法: https://{你的反代域名}/{emby服务器协议}/{emby服务器地址}/{emby服务器端口}${RESET}"
    echo -e "${CYAN}💡 使用提示：请将客户端（如 Infuse、Emby App）连接地址指向此代理端口。${RESET}"
    echo -e "${CYAN}   网关将自动根据后台配置接管流量，实现公网播放与直链优化加速。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新服务
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在检查并拉取最新稳定版 Emby-Proxy 镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！Go 高性能流媒体代理网关已平滑重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并停止 Emby-Proxy 代理服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            rm -rf "$BASE_DIR"
            echo -e "${GREEN}网关已停止，相关编排配置目录已彻底清理。${RESET}"
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
    echo -e "${YELLOW}网关镜像版本     : ${img_version}${RESET}"
    echo -e "${YELLOW}网关代理入口     : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}架构属性         : 高性能 Go 运行时 (状态无关/不占磁盘空间)${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈  Emby-Proxy-Go 管理面板  ◈ ${RESET}"
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
