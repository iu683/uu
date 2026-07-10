#!/bin/bash
# =================================================================
# Link42 Looking Glass Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="link42-lg"
BASE_DIR="/opt/link42-lg"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 数据挂载本地的宿主机路径
DATA_DIR="$BASE_DIR/data"
CONFIG_DIR="$BASE_DIR/config"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 格式化 URL 中的 IP (如果是 IPv6 则加上方括号 [])
format_ip_for_url() {
    local ip="$1"
    if [[ "$ip" == *":"* ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

# 动态获取容器状态、映射端口和环境变量配置
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        return 0
    fi
    
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        local health_status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        if [[ "$health_status" == "healthy" ]]; then
            status="${GREEN}运行中 (健康)${RESET}"
        elif [[ "$health_status" == "unhealthy" ]]; then
            status="${RED}运行中 (不健康)${RESET}"
        elif [[ "$health_status" == "starting" ]]; then
            status="${YELLOW}运行中 (启动中)${RESET}"
        else
            status="${GREEN}运行中${RESET}"
        fi
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

        # 从容器状态提取端口（容器内部监听的是 8000 端口）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        # 兜底获取第一个绑定的端口
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8000"
    else
        # 容器未安装/未部署时的返回值
        img_version="${RED}未安装${RESET}"
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

# 部署 Link42 Looking Glass
install_lg() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    mkdir -p "$DATA_DIR"
    mkdir -p "$CONFIG_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入服务访问端口 (宿主机端口) [默认: 8000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8000"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入 LG 后台管理员密码 [默认: change-me]: ${RESET}"
    read -r admin_password
    [[ -z "$admin_password" ]] && admin_password="change-me"

    # 修改目录权限
    chmod -R 777 "$BASE_DIR"

    # 生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  link42-lg:
    image: pmman/link42-lg:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${custom_port}:8000"
    environment:
      - LG_ADMIN_PASSWORD=${admin_password}
      - LG_COOKIE_SECURE=true
      - LG_NODE_CONCURRENCY_LIMIT=2
      - LG_DATA_DIR=/app/data
      - LG_CONFIG_DIR=/app/config
      - LG_DB_PATH=/app/data/looking-glass.sqlite3
    volumes:
      - ${DATA_DIR}:/app/data
      - ${CONFIG_DIR}:/app/config
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Link42 Looking Glass 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}        Link42 Looking Glass 部署及启动成功！        ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}服务访问密码 : $admin_password${RESET}"
    echo -e "${YELLOW}数据挂载路径 : $DATA_DIR${RESET}"
    echo -e "${YELLOW}配置挂载路径 : $CONFIG_DIR${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
}

# 更新镜像
update_lg() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载服务
uninstall_lg() {
    echo -ne "${YELLOW}确定要卸载并删除 Link42 Looking Glass 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有本地配置文件及挂载数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置及本地数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_lg() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_lg() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_lg() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_lg() { 
    echo -e "${CYAN}--- 容器当前运行日志 (按 Ctrl+C 退出查看) ---${RESET}"
    docker logs -f "$CONTAINER_NAME"; 
}

show_info() {
    get_status_info
    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${YELLOW}当前状态     : $status"
    echo -e "${YELLOW}镜像名称     : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}服务访问密码 : $admin_password${RESET}"
    echo -e "${YELLOW}数据挂载路径 : ${DATA_DIR}${RESET}"
    echo -e "${YELLOW}配置挂载路径 : ${CONFIG_DIR}${RESET}"
    echo -e "${GREEN}========================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} ◈  Link42 Looking Glass  ◈   ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_lg ;;
        2) update_lg ;;
        3) uninstall_lg ;;
        4) start_lg ;;
        5) stop_lg ;;
        6) restart_lg ;;
        7) logs_lg ;;
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
