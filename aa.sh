#!/bin/bash
# =================================================================
# ABS-Ximalaya 喜马拉雅同步网关 Docker Compose 自动化管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="ximalaya"
BASE_DIR="/opt/abs-ximalaya"
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
        [[ -z "$img_version" ]] && img_version="latest"

        # 提取 Web 访问端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "7814/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="7814"
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

# 部署并配置核心逻辑
install_translate() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 网络访问端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 ABS-Ximalaya 服务映射端口 (宿主机) [默认: 7814]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="7814"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "\n${YELLOW}正在构建符合规范的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  ximalaya:
    image: shanyanwcx/abs-ximalaya:latest
    container_name: ${CONTAINER_NAME}
    ports:
      - "${custom_port}:7814"
    environment:
      - TZ=Asia/Shanghai
    restart: always
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 编排启动喜马拉雅音频同步网关...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待网关服务初始化网络环境 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}           ABS-Ximalaya 网关部署成功！              ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}网关服务控制台地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}全球标准时区锁死   : Asia/Shanghai (国内定时抓取无时差)${RESET}"
    echo -e "${CYAN}💡 联动进阶提示：本工具需要配合您的 Audiobookshelf (ABS) 共同使用。${RESET}"
    echo -e "${CYAN}   登录本网关后台后，填入你的 ABS 密钥与服务器地址，即可将喜马有声一键转换为播客源！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新服务
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在同步拉取最新 ABS-Ximalaya 官方发布版镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！喜马拉雅下载同步网关已平滑重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 ABS-Ximalaya 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            rm -rf "$BASE_DIR"
            echo -e "${GREEN}容器已停止，运行配置目录已安全移除。${RESET}"
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
    echo -e "${YELLOW}网关控制台地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}架构属性         : 轻量状态无关网关 (无本地大容量存储)${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}◈ABS-Ximalaya 喜马拉雅管理面板◈ ${RESET}"
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
