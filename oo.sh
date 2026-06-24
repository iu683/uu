#!/bin/bash
# =================================================================
# Miaospeed 服务 Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/miaospeed-panel"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
CONTAINER_NAME="miaospeed"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器的状态、映射端口
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ] || [ "$(docker ps -q -f name=miaospeed-panel-miaospeed-1)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ] || [ "$(docker ps -aq -f name=miaospeed-panel-miaospeed-1)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ -f "$ENV_FILE" ]; then
        bind_port=$(grep "^MIAO_PORT=" "$ENV_FILE" | cut -d'=' -f2 | sed 's/\r//g')
        [[ -z "$bind_port" ]] && bind_port="8765"
        
        miao_token=$(grep "^MIAO_TOKEN=" "$ENV_FILE" | cut -d'=' -f2 | sed 's/\r//g')
        miao_path=$(grep "^MIAO_PATH=" "$ENV_FILE" | cut -d'=' -f2 | sed 's/\r//g')
    else
        bind_port="N/A"
        miao_token="N/A"
        miao_path="N/A"
    fi
}

get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
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

# 部署 Miaospeed
install_translate() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 配置监听端口
    echo -ne "${YELLOW}请输入 Miaospeed 监听端口 [默认: 8765]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8765"

    # 2. 配置安全路径
    echo -ne "${YELLOW}请输入 WebSocket 连接路径 (必须以 / 开头) [默认: /miaospeed]: ${RESET}"
    read -r custom_path
    [[ -z "$custom_path" ]] && custom_path="/miaospeed"

    # 3. 配置连接 Token（默认随机，输入 y 手动指定）
    echo -e "\n${CYAN}--- Token (连接密码) 配置 ---${RESET}"
    echo -ne "${YELLOW}是否手动指定连接 Token？(y/n) [默认: n，将自动生成随机密码]: ${RESET}"
    read -r miao_confirm

    if [[ "$miao_confirm" != "y" && "$miao_confirm" != "Y" ]]; then
        # 自动生成 16 位随机强密码
        custom_token=$(tr -dc 'A-Za-z0-9{}?_' < /dev/urandom | head -c 16)
        echo -e "${GREEN}提示: 已自动为您生成强安全 Token: ${custom_token}${RESET}"
    else
        echo -ne "${YELLOW}请输入您的自定义连接 Token (避免使用特殊符号): ${RESET}"
        read -r custom_token
        while [[ -z "$custom_token" ]]; do
            echo -ne "${RED}错误: Token 不能为空，请重新输入: ${RESET}"
            read -r custom_token
        done
    fi

    # 生成环境变量 .env 配置文件
    cat <<EOF > "$ENV_FILE"
MIAO_PORT=${custom_port}
MIAO_PATH=${custom_path}
MIAO_TOKEN=${custom_token}
EOF

    # 动态生成符合官方标准的 docker-compose.yml 
    # 注意：使用 host 模式运行，端口由命令内部控制
    cat <<EOF > "$COMPOSE_FILE"
services:
  miaospeed:
    stdin_open: true
    tty: true
    container_name: ${CONTAINER_NAME}
    network_mode: host
    restart: always
    image: airportr/miaospeed:latest
    command: server -bind 0.0.0.0:\${MIAO_PORT:-8765} -path \${MIAO_PATH:-/miaospeed} -token '\${MIAO_TOKEN}' -mtls
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Miaospeed 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    sleep 2
    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}      Miaospeed 后端部署成功！                      ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}请将以下配置直接复制贴入您的 koipy 主控配置文件中:  ${RESET}"
    echo -e "${CYAN}"
    echo -e "    - type: miaospeed"
    echo -e "      id: \"localmiaospeed\""
    echo -e "      token: \"${custom_token}\""
    echo -e "      address: \"127.0.0.1:${custom_port}\""
    echo -e "      path: \"${custom_path}\""
    echo -e "      skipCertVerify: true"
    echo -e "      tls: true"
    echo -e "      comment: \"本地miaospeed后端\""
    echo -e "${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件！${RESET}"
        return
    fi
    cd "$BASE_DIR" && docker compose pull && docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！${RESET}"
}

# 卸载服务 (分层递进确认逻辑)
uninstall_translate() {
    get_status_info
    
    echo -ne "${YELLOW}确定要卸载并删除 Miaospeed 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            
            # 第二层确认：删除面板配置文件目录
            echo -ne "${YELLOW}是否同时删除面板配置环境目录 [${BASE_DIR}]？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}管理目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}所有容器已重启${RESET}"; }
logs_translate() { cd "$BASE_DIR" && docker compose logs -f; }

show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}Miaospeed 服务状态    : ${status}"
    echo -e "${YELLOW}当前本地监听端口       : ${bind_port}"
    echo -e "${YELLOW}当前通信安全路径       : ${miao_path}"
    echo -e "${YELLOW}当前对接通信 Token     : ${miao_token}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} ◈  Miaospeed 后端管理面板  ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态  : ${status}"
    echo -e "${GREEN}端口  : ${YELLOW}${bind_port}${RESET}"
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
