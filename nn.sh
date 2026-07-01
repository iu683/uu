#!/bin/bash
# =================================================================
# MCSManager 游戏面板 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

WEB_CONTAINER="mcsmanager-web"
DAEMON_CONTAINER="mcsmanager-daemon"
BASE_DIR="/opt/mcsmanager"
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
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        data_dir="N/A"
        return 0
    fi
    # 1. 检查 Web 和 Daemon 状态
    if [ "$(docker ps -q -f name=^/${WEB_CONTAINER}$)" ] && [ "$(docker ps -q -f name=^/${DAEMON_CONTAINER}$)" ]; then
        status="${YELLOW}运行中 (双端正常)${RESET}"
    elif [ "$(docker ps -aq -f name=^/${WEB_CONTAINER}$)" ] || [ "$(docker ps -aq -f name=^/${DAEMON_CONTAINER}$)" ]; then
        status="${RED}异常/部分停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果 Web 容器存在，提取 Web 端口
    if [ "$(docker ps -aq -f name=^/${WEB_CONTAINER}$)" ]; then
        web_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "23333/tcp") 0).HostPort}}' "$WEB_CONTAINER" 2>/dev/null)
        [[ -z "$web_port" ]] && web_port="23333"
    else
        web_port="N/A"
    fi

    # 3. 如果 Daemon 容器存在，提取 Daemon 端口
    if [ "$(docker ps -aq -f name=^/${DAEMON_CONTAINER}$)" ]; then
        daemon_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "24444/tcp") 0).HostPort}}' "$DAEMON_CONTAINER" 2>/dev/null)
        [[ -z "$daemon_port" ]] && daemon_port="24444"
    else
        daemon_port="N/A"
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

# 部署 MCSManager
install_mcsm() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 MCSManager 网页访问端口 [默认: 23333]: ${RESET}"
    read -r custom_web_port
    [[ -z "$custom_web_port" ]] && custom_web_port="23333"

    echo -ne "${YELLOW}请输入 MCSManager 守护进程端口 [默认: 24444]: ${RESET}"
    read -r custom_daemon_port
    [[ -z "$custom_daemon_port" ]] && custom_daemon_port="24444"

    echo -ne "${YELLOW}请输入 MCSManager 数据安装绝对路径 [默认: /opt/mcsmanager]: ${RESET}"
    read -r custom_path
    [[ -z "$custom_path" ]] && custom_path="/opt/mcsmanager"

    # 更新全局基础目录定义
    BASE_DIR="$custom_path"
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

    # 1. 创建所需的宿主机目录
    mkdir -p "$BASE_DIR/web/data" "$BASE_DIR/web/logs" "$BASE_DIR/daemon/data" "$BASE_DIR/daemon/logs"
    chmod -R 777 "$BASE_DIR"

    # 2. 动态生成 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  web:
    image: githubyumao/mcsmanager-web:latest
    container_name: ${WEB_CONTAINER}
    restart: unless-stopped
    ports:
      - "${custom_web_port}:23333"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ${BASE_DIR}/web/data:/opt/mcsmanager/web/data
      - ${BASE_DIR}/web/logs:/opt/mcsmanager/web/logs

  daemon:
    image: githubyumao/mcsmanager-daemon:latest
    container_name: ${DAEMON_CONTAINER}
    restart: unless-stopped
    ports:
      - "${custom_daemon_port}:24444"
    environment:
      - MCSM_DOCKER_WORKSPACE_PATH=${BASE_DIR}/daemon/data/InstanceData
    volumes:
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
      - ${BASE_DIR}/daemon/data:/opt/mcsmanager/daemon/data
      - ${BASE_DIR}/daemon/logs:/opt/mcsmanager/daemon/logs
      - /var/run/docker.sock:/var/run/docker.sock
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 MCSManager 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化并生成密钥 (约5秒)...${RESET}"
    sleep 5

    show_info
}

# 更新 MCSManager 镜像
update_mcsm() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 MCSManager 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 MCSManager
uninstall_mcsm() {
    echo -ne "${YELLOW}确定要卸载并删除 MCSManager 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有游戏实例数据、配置文件和日志？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}安装目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$WEB_CONTAINER" "$DAEMON_CONTAINER" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_mcsm() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_mcsm() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_mcsm() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_mcsm() {
    echo -e "${CYAN}1. 查看 Web 端日志${RESET}"
    echo -e "${CYAN}2. 查看 Daemon 端日志${RESET}"
    echo -ne "${YELLOW}请选择要查看的日志 [1-2]: ${RESET}"
    read -r log_choice
    if [[ "$log_choice" == "2" ]]; then
        docker logs -f "$DAEMON_CONTAINER"
    else
        docker logs -f "$WEB_CONTAINER"
    fi
}

show_info() {
    get_status_info
    local current_ip=$(get_public_ip)
    
    # 自动尝试提取守护进程密钥
    local daemon_key="未生成 (请先启动容器)"
    local key_file="$BASE_DIR/daemon/data/Config/global.json"
    if [[ -f "$key_file" ]]; then
        # 通过 grep 和 sed 简单提取 json 中的 key 值，无需依赖 jq
        local extracted_key=$(grep -o '"key":[^,]*' "$key_file" | head -n 1 | sed 's/"key"://' | sed 's/"//g' | tr -d '[:space:]')
        [[ -n "$extracted_key" ]] && daemon_key="$extracted_key"
    fi

    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${GREEN}                       MCSManager 配置信息                      ${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}网页访问地址   : http://${current_ip}:${web_port}${RESET}"
    echo -e "${YELLOW}守护进程节点IP : ${current_ip}${RESET}"
    echo -e "${YELLOW}守护进程端口   : ${daemon_port}${RESET}"
    echo -e "${RED}守护进程密钥   : ${daemon_key}${RESET}"
    echo -e "${YELLOW}宿主机安装路径 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${CYAN}💡 节点连接向导：${RESET}"
    echo -e "${YELLOW} 进网页 -> 点击「节点」 -> 「新增节点」 -> 填入上方公网IP、端口(${daemon_port})及密钥。${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  MCSManager 管理面板  ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态     :${RESET} $status"
    echo -e "${GREEN}网页端口 :${RESET} ${YELLOW}${web_port}${RESET}"   
    echo -e "${GREEN}守护端口 :${RESET} ${YELLOW}${daemon_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置与连接密钥${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_mcsm ;;
        2) update_mcsm ;;
        3) uninstall_mcsm ;;
        4) start_mcsm ;;
        5) stop_mcsm ;;
        6) restart_mcsm ;;
        7) logs_mcsm ;;
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
