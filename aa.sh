#!/bin/bash
# =================================================================
# frp-panel Master 工具箱 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="frpp-master"
BASE_DIR="/opt/frpp-master"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 生成随机密钥
generate_secret() {
    if command -v openssl &> /dev/null; then
        openssl rand -hex 16
    else
        echo "frp_panel_secret_$(date +%s)"
    fi
}

# 动态获取容器状态和端口信息（由于是 host 模式，从 .env 文件或默认值回显）
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 从 .env 读取配置端口用于菜单展示
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        webui_port="$FRPP_API_PORT"
        rpc_port="$FRPP_RPC_PORT"
    else
        webui_port="9000"
        rpc_port="9001"
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

# 部署 frp-panel Master
install_utils() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    echo -e "${YELLOW}正在获取系统公网 IP 作为默认配置...${RESET}"
    DETECT_IP=$(get_public_ip)

    # 1. 配置服务器外部 IP / 域名
    echo -ne "${YELLOW}请输入服务器公网 IP 或域名 [默认: ${DETECT_IP}]: ${RESET}"
    read -r custom_ip
    [[ -z "$custom_ip" ]] && custom_ip="$DETECT_IP"

    # 2. 配置 WebUI/API 端口
    echo -ne "${YELLOW}请输入 WebUI/API 监听端口 [默认: 9000]: ${RESET}"
    read -r custom_api_port
    [[ -z "$custom_api_port" ]] && custom_api_port="9000"
    if ! [[ "$custom_api_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 3. 配置 RPC 监听端口
    echo -ne "${YELLOW}请输入 Master RPC 监听端口 [默认: 9001]: ${RESET}"
    read -r custom_rpc_port
    [[ -z "$custom_rpc_port" ]] && custom_rpc_port="9001"
    if ! [[ "$custom_rpc_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 4. 生成全局密钥
    app_secret=$(generate_secret)

    # 写入 .env 文件
    cat <<EOF > "$ENV_FILE"
FRPP_SECRET=${app_secret}
FRPP_HOST=${custom_ip}
FRPP_API_PORT=${custom_api_port}
FRPP_RPC_PORT=${custom_rpc_port}
EOF

    # 动态生成符合要求的 docker-compose.yml 配置文件 (使用 host 网络)
    echo -e "${YELLOW}正在生成符合标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  frpp-master:
    image: vaalacat/frp-panel:latest
    container_name: ${CONTAINER_NAME}
    network_mode: host
    environment:
      APP_GLOBAL_SECRET: \${FRPP_SECRET}
      MASTER_RPC_HOST: 0.0.0.0
      MASTER_RPC_PORT: \${FRPP_RPC_PORT}
      MASTER_API_HOST: 0.0.0.0
      MASTER_API_PORT: \${FRPP_API_PORT}
      CLIENT_RPC_URL: grpc://\${FRPP_HOST}:\${FRPP_RPC_PORT}
      CLIENT_API_URL: http://\${FRPP_HOST}:\${FRPP_API_PORT}
    volumes:
      - ./data:/data
    restart: unless-stopped
    command: master
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 frp-panel Master...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN}      frp-panel Master 部署成功！               ${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW}WebUI 面板地址  : http://${custom_ip}:${custom_api_port}${RESET}"
    echo -e "${YELLOW}RPC 通信连接地址: grpc://${custom_ip}:${custom_rpc_port}${RESET}"
    echo -e "${YELLOW}全局通讯通信密钥: ${app_secret}${RESET}"
    echo -e "${YELLOW}数据挂载路径    : $BASE_DIR/data${RESET}"
    echo -e "${YELLOW}配置文件路径    : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================================${RESET}"
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

# 卸载容器
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 frp-panel Master 吗？(y/n) [默认: N]: ${RESET}"
    read -r confirm
    [[ -z "$confirm" ]] && confirm="N"
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地数据与配置文件？(y/n) [默认: N]: ${RESET}"
            read -r clean_data
            [[ -z "$clean_data" ]] && clean_data="N"
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}整个面板配置及 SQLite 数据目录已彻底清理。${RESET}"
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
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        echo -e "${GREEN}================================================${RESET}"
        echo -e "${YELLOW}当前状态       : $status"
        echo -e "${YELLOW}WebUI 访问地址 : http://${FRPP_HOST}:${FRPP_API_PORT}${RESET}"
        echo -e "${YELLOW}RPC 连接地址   : grpc://${FRPP_HOST}:${FRPP_RPC_PORT}${RESET}"
        echo -e "${YELLOW}全局通信密钥   : ${FRPP_SECRET}${RESET}"
        echo -e "${GREEN}================================================${RESET}"
    else
        echo -e "${RED}未检测到部署配置环境。${RESET}"
    fi
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} ◈ frp-panel Master 管理面板 ◈  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}WebUI:${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}RPC  :${RESET} ${YELLOW}${rpc_port}${RESET}"
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
