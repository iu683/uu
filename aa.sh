#!/bin/bash
# =================================================================
# OVH Console Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="ovh-console"
BASE_DIR="/opt/ovh-console"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态与映射端口
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        port_display="N/A"
        return 0
    fi
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${GREEN}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "20000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="20000"
        port_display="${webui_port}"
    else
        img_version="${RED}未安装${RESET}"
        port_display="N/A"
    fi
}

# 获取公网 IP (兼容双栈环境)
get_public_ip() {
    local mode=${1:-"auto"}
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":" ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":" ]] && echo "$ip" && return 0
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

# 部署 OVH Console
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR/data"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 访问安全配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 API 访问密钥 (API_SECRET_KEY) [可直接回车随机生成]: ${RESET}"
    read -r api_secret
    if [[ -z "$api_secret" ]]; then
        if command -v openssl &> /dev/null; then
            api_secret=$(openssl rand -hex 32)
        else
            api_secret="ovh_$(date +%s)_$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 24 | head -n 1)"
        fi
        echo -e "${GREEN}已自动为您生成随机密钥: ${api_secret}${RESET}"
    fi

    echo -e "\n${CYAN}====== 2. 网络端口与绑定配置 ======${RESET}"
    echo -ne "${YELLOW}请输入访问端口 [默认: 20000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="20000"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -e "${YELLOW}1) 仅本机访问 (127.0.0.1 - 推荐，配合反向代理)${RESET}"
    echo -e "${YELLOW}2) 开放全部网卡 (0.0.0.0 - 注意安全风险)${RESET}"
    echo -ne "${YELLOW}请选择监听绑定模式 [默认: 1]: ${RESET}"
    read -r bind_choice
    local bind_ip="127.0.0.1"
    [[ "$bind_choice" == "2" ]] && bind_ip="0.0.0.0"

    # 获取当前用户的 PUID / PGID
    local current_uid=$(id -u)
    local current_gid=$(id -g)

    # 生成 .env 文件
    echo -e "${YELLOW}正在生成 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
API_SECRET_KEY=${api_secret}
BIND_ADDR=${bind_ip}
HOST_PORT=${custom_port}
TZ=Asia/Shanghai
PUID=${current_uid}
PGID=${current_gid}
EOF

    # 生成 docker-compose.yml 文件
    echo -e "${YELLOW}正在生成规范的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  ovh-console:
    image: ghcr.io/gokele/ovh:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "\${BIND_ADDR:-127.0.0.1}:\${HOST_PORT:-20000}:20000"
    volumes:
      - ./data:/data
    environment:
      API_SECRET_KEY: \${API_SECRET_KEY:?请先设置 API_SECRET_KEY}
      OVH_DB_KEY:
      TZ: \${TZ:-Asia/Shanghai}
      PUID: \${PUID:-10001}
      PGID: \${PGID:-10001}
      CORS_ALLOWED_ORIGINS:
      TRUSTED_PROXIES:
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 OVH Console...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    OVH Console 部署成功！      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}访问地址     : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}API密钥      : ${api_secret}${RESET}"
    echo -e "${YELLOW}监听绑定     : ${bind_ip}${RESET}"
    echo -e "${YELLOW}数据挂载目录 : ${BASE_DIR}/data${RESET}"
    echo -e "${YELLOW}配置文件路径 : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载服务 (带分步清理确认)
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 ovh-console 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地数据目录及整个项目文件夹 (${BASE_DIR})？(y/n) [重要：包含凭据及数据库]: ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}项目及本地数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}访问地址       : http://${DETECT_IP}:${port_display}${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈ OVH Console 管理面板 ◈     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${port_display}${RESET}"
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
        1) install_utils ;;
        2) update_utils ;;
        3) uninstall_utils ;;
        4) start_utils ;;
        5) stop_utils ;;
        6) restart_utils ;;
        7) logs_utils ;;
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
