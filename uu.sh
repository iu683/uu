#!/bin/bash
# =================================================================
# frp-panel-server 服务端 一键管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="frp-panel-server"
BASE_DIR="/opt/frp-panel-server"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态和配置信息
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 从 .env 读取关键连接参数用于菜单展示
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        server_id="$FRPP_SERVER_ID"
    else
        server_id="N/A"
    fi
}

# 部署 frp-panel-server
install_utils() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义受控端参数配置 ======${RESET}"
    echo -e "${YELLOW}提示: 请确保以下参数与你 Master 主控面板中的设置完全一致。${RESET}"

    # 1. 配置 Master 的全局通讯密钥 (APP_GLOBAL_SECRET)
    echo -ne "${YELLOW}请输入 Master 节点的全局通信密钥 (-s) [默认: abc]: ${RESET}"
    read -r app_secret
    [[ -z "$app_secret" ]] && app_secret="abc"

    # 2. 配置当前受控端节点 ID
    echo -ne "${YELLOW}请输入该受控节点的唯一 ID (-i) [默认: user.s.server1]: ${RESET}"
    read -r client_id
    [[ -z "$client_id" ]] && client_id="user.s.server1"

    # 3. 配置 Master API 访问地址
    echo -ne "${YELLOW}请输入 Master API/WebUI 访问地址 [默认: http://frpp.example.com:9000]: ${RESET}"
    read -r master_api_url
    [[ -z "$master_api_url" ]] && master_api_url="http://frpp.example.com:9000"

    # 4. 配置 Master RPC 通讯地址
    echo -ne "${YELLOW}请输入 Master RPC 连接地址 [默认: grpc://frpp-rpc.example.com:9001]: ${RESET}"
    read -r master_rpc_url
    [[ -z "$master_rpc_url" ]] && master_rpc_url="grpc://frpp-rpc.example.com:9001"

    # 5. 配置通讯与 API 端口（解决 8999 端口冲突问题）
    echo -e "${CYAN}------------------------------------------------${RESET}"
    echo -e "${YELLOW}说明: server 默认会占用 8999 端口。若有冲突，请在下方修改。${RESET}"
    echo -ne "${YELLOW}请输入要使用的通信/API 端口 [默认: 8999]: ${RESET}"
    read -r server_port
    [[ -z "$server_port" ]] && server_port="8999"

    # 写入 .env 文件
    cat <<EOF > "$ENV_FILE"
FRPP_SECRET=${app_secret}
FRPP_SERVER_ID=${client_id}
FRPP_MASTER_API=${master_api_url}
FRPP_MASTER_RPC=${master_rpc_url}
FRPP_SERVER_PORT=${server_port}
EOF

    # 动态生成符合要求的 docker-compose.yml 配置文件
    # 保持 network_mode: host 并通过环境变量注入端口配置
    echo -e "${YELLOW}正在生成符合标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  frp-panel-server:
    image: vaalacat/frp-panel:latest
    container_name: ${CONTAINER_NAME}
    network_mode: host
    restart: unless-stopped
    environment:
      - SERVER_API_PORT=\${FRPP_SERVER_PORT}
      - INTERNAL_FRP_AUTH_SERVER_PORT=\${FRPP_SERVER_PORT}
    command: server -s \${FRPP_SECRET} -i \${FRPP_SERVER_ID} --api-url \${FRPP_MASTER_API} --rpc-url \${FRPP_MASTER_RPC}
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 frp-panel-server...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN}      frp-panel-server 受控端部署成功！           ${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -ne "${YELLOW}当前节点 ID     : ${client_id}\n"
    echo -ne "连接主控 API    : ${master_api_url}\n"
    echo -ne "连接主控 RPC    : ${master_rpc_url}\n"
    echo -ne "服务占用端口    : ${server_port} (已同步绑定 API 与 AUTH)\n"
    echo -ne "配置文件路径    : $COMPOSE_FILE\n${RESET}"
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
    echo -ne "${YELLOW}确定要卸载并删除 frp-panel-server 吗？(y/n) [默认: N]: ${RESET}"
    read -r confirm
    [[ -z "$confirm" ]] && confirm="N"
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}受控端容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地配置文件目录？(y/n) [默认: N]: ${RESET}"
            read -r clean_data
            [[ -z "$clean_data" ]] && clean_data="N"
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}受控端配置目录已彻底清理。${RESET}"
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
        echo -e "${YELLOW}当前节点 ID    : ${FRPP_SERVER_ID}${RESET}"
        echo -e "${YELLOW}连接主控 API   : ${FRPP_MASTER_API}${RESET}"
        echo -e "${YELLOW}连接主控 RPC   : ${FRPP_MASTER_RPC}${RESET}"
        echo -e "${YELLOW}运行占用端口   : ${FRPP_SERVER_PORT:-8999}${RESET}"
        echo -e "${YELLOW}通信秘密       : ${FRPP_SECRET}${RESET}"
        echo -e "${GREEN}================================================${RESET}"
    else
        echo -e "${RED}未检测到部署配置环境。${RESET}"
    fi
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈ frp-panel server管理面板 ◈  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态     :${RESET} $status"
    echo -e "${GREEN}服务端ID :${RESET} ${YELLOW}${server_id}${RESET}"
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
