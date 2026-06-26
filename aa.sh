#!/bin/bash
# =================================================================
# Xboard Node 后端 Docker Compose 运维管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="xboard-node"
BASE_DIR="/opt/xboard-node"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
CONFIG_FILE="$BASE_DIR/config/config.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、Node ID 及镜像信息
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 从本地配置文件中动态抓取 Node ID 和对接域名
    if [[ -f "$CONFIG_FILE" ]]; then
        panel_url=$(grep -E '^[[:space:]]*url:' "$CONFIG_FILE" | awk -F'"' '{print $2}')
        node_id=$(grep -E '^[[:space:]]*node_id:' "$CONFIG_FILE" | awk '{print $2}')
        [[ -z "$node_id" ]] && node_id="未知"
        [[ -z "$panel_url" ]] && panel_url="未知"
    else
        node_id="N/A"
        panel_url="N/A"
    fi

    # 3. 如果容器存在，获取镜像版本
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"
    else
        img_version="${RED}未安装${RESET}"
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

# 部署 Xboard Node
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR/config"

    echo -e "${CYAN}====== 对接参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 Xboard 面板 URL (如 https://xxx.com): ${RESET}"
    read -r custom_url
    [[ -z "$custom_url" ]] && echo -e "${RED}错误: 面板 URL 不能为空！${RESET}" && return

    echo -ne "${YELLOW}请输入 面板通讯 Token (通讯密钥): ${RESET}"
    read -r custom_token
    [[ -z "$custom_token" ]] && echo -e "${RED}错误: 通讯 Token 不能为空！${RESET}" && return

    echo -ne "${YELLOW}请输入 节点 ID (Node ID) [默认: 8]: ${RESET}"
    read -r custom_node_id
    [[ -z "$custom_node_id" ]] && custom_node_id="8"
    if ! [[ "$custom_node_id" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 节点 ID 必须是纯数字！${RESET}"
        return
    fi

    # 1. 动态生成后端专用的 config.yml
    echo -e "${YELLOW}正在生成 config.yml 配置文件...${RESET}"
    cat <<EOF > "$CONFIG_FILE"
panel:
  url: "${custom_url}"
  token: "${custom_token}"
  node_id: ${custom_node_id}

kernel:
  type: "singbox"
  config_dir: "/etc/xboard-node"
  log_level: "warn"

log:
  level: "info"
  output: "stdout"
EOF

    # 2. 动态生成 docker-compose.yml 配置文件 (采用 host 网络模式)
    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  xboard-node:
    image: ghcr.io/cedar2025/xboard-node:latest
    container_name: ${CONTAINER_NAME}
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./config:/etc/xboard-node
    command: ["-c", "/etc/xboard-node/config.yml"]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Xboard Node...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化并建立同步 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Xboard Node 部署成功！    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}面板域名   : ${custom_url}${RESET}"
    echo -e "${YELLOW}绑定节点 ID: ${custom_node_id}${RESET}"
    echo -e "${YELLOW}节点公网 IP: ${DETECT_IP}${RESET}"
    echo -e "${YELLOW}配置目录   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 Xboard Node 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Xboard Node 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！后端已处于最新状态。${RESET}"
}

# 卸载 Xboard Node
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 Xboard Node 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地所有配置及证书文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置及证书目录已彻底清理。${RESET}"
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
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态     : $status"
    echo -e "${YELLOW}后端镜像     : ${img_version}${RESET}"
    echo -e "${YELLOW}对接面板     : ${panel_url}${RESET}"
    echo -e "${YELLOW}绑定节点 ID  : ${node_id}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      ◈  Xboard Node 管理面板 ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}节点 :${RESET} ${YELLOW}节点 ID [ ${node_id} ]${RESET}"
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
