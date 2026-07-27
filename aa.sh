#!/bin/bash
# =================================================================
# Ports-Box Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="ports-box"
BASE_DIR="/opt/ports-box"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
CONFIG_FILE="$BASE_DIR/config.json"
DATA_DIR="$BASE_DIR/data"

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

# 动态获取容器状态
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        api_port="N/A"
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

    # 2. 如果容器存在，提取镜像版本与 API 监听端口
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 因为使用的是 host 网络模式，端口从本地 config.json 读取或回退默认 7070
        if [ -f "$CONFIG_FILE" ]; then
            api_port=$(grep -o '"listen"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -n 1 | awk -F'"' '{print $4}' | awk -F':' '{print $2}')
        fi
        [[ -z "$api_port" ]] && api_port="7070"
    else
        img_version="${RED}未安装${RESET}"
        api_port="N/A"
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

# 部署 Ports-Box 并初始化配置
install_portsbox() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    mkdir -p "$DATA_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 API 监听端口 [默认: 7070]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="7070"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入 API 访问 Token [默认: changeme]: ${RESET}"
    read -r custom_token
    [[ -z "$custom_token" ]] && custom_token="changeme"

    echo -ne "${YELLOW}请输入系统总流量配额 Total Quota [默认: 100GB]: ${RESET}"
    read -r custom_quota
    [[ -z "$custom_quota" ]] && custom_quota="100GB"

    # 生成符合标准的 config.json 配置文件
    echo -e "${YELLOW}正在生成 config.json 配置文件...${RESET}"
    cat <<EOF > "$CONFIG_FILE"
{
  "state_file": {
    "enabled": true,
    "path": "state.db",
    "flush_secs": 10
  },
  "api": {
    "listen": "0.0.0.0:${custom_port}",
    "token": "${custom_token}"
  },
  "total_quota": "${custom_quota}",
  "users": [
    {
      "name": "alice",
      "quota": "30GB",
      "rules": [
        { "listen": "0.0.0.0:8080", "target": "10.0.0.2:80", "fallback": "10.0.0.3:80", "tag": "web" },
        { "listen": "0.0.0.0:5353", "target": "10.0.0.2:53", "protocol": "udp" }
      ]
    }
  ]
}
EOF

    # 生成 docker-compose.yml (基于 host 网络模式)
    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  ports-box:
    image: yuu518/ports-box:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    network_mode: host
    environment:
      RUST_LOG: ports_box=info
    volumes:
      - ./config.json:/etc/ports-box/config.json:ro
      - ./data:/var/lib/ports-box
    command: ["-c", "/etc/ports-box/config.json", "-d", "/var/lib/ports-box"]
EOF

    # 赋予权限
    chmod -R 777 "$BASE_DIR"

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Ports-Box 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}        Ports-Box 部署及启动成功！                  ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}API 监听地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}API Token    : ${custom_token}${RESET}"
    echo -e "${YELLOW}配置文件路径 : ${CONFIG_FILE}${RESET}"
    echo -e "${YELLOW}数据目录路径 : ${DATA_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_portsbox() {
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
uninstall_portsbox() {
    echo -ne "${YELLOW}确定要卸载并删除 Ports-Box 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地配置及数据目录？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置及数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_portsbox() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_portsbox() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_portsbox() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_portsbox() { 
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
    echo -e "${YELLOW}API 访问地址 : http://${DETECT_IP}:${api_port}${RESET}"
    echo -e "${YELLOW}项目目录路径 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}========================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}     ◈  Ports-Box 管理面板  ◈     ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${api_port}${RESET}"
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
        1) install_portsbox ;;
        2) update_portsbox ;;
        3) uninstall_portsbox ;;
        4) start_portsbox ;;
        5) stop_portsbox ;;
        6) restart_portsbox ;;
        7) logs_portsbox ;;
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
