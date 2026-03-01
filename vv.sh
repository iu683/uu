#!/bin/bash
# ========================================
# Snell 多节点管理脚本（彩色菜单 + 节点状态查看）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="snell-server"
APP_DIR="/opt/$APP_NAME"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi
    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2，请升级 Docker${RESET}"
        exit 1
    fi
}

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

list_nodes() {
    mkdir -p "$APP_DIR"
    echo -e "${GREEN}=== 已有 Snell 节点 ===${RESET}"
    local count=0
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        count=$((count+1))
        echo -e "${YELLOW}[$count] $(basename "$node")${RESET}"
    done
    [ $count -eq 0 ] && echo -e "${YELLOW}无节点${RESET}"
}

select_node() {
    list_nodes
    read -r -p $'\033[32m请输入节点名称或编号: \033[0m' input
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        NODE_NAME=$(ls -d "$APP_DIR"/* | sed -n "${input}p" | xargs basename)
    else
        NODE_NAME="$input"
    fi
    NODE_DIR="$APP_DIR/$NODE_NAME"
    if [ ! -d "$NODE_DIR" ]; then
        echo -e "${RED}节点不存在！${RESET}"
        return 1
    fi
}

install_node() {
    check_docker
    read -p "请输入节点名称 [node$(date +%s)]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-node$(date +%s)}
    NODE_DIR="$APP_DIR/$NODE_NAME"
    mkdir -p "$NODE_DIR/data"

    read -p "请输入监听端口 [1025-65535, 默认随机]: " input_port
    PORT=${input_port:-$(shuf -i 1025-65535 -n1)}
    check_port "$PORT" || return

    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c32)

    read -p "是否启用 IPv6 [true/false, 默认 false]: " ipv6
    IPv6=${ipv6:-false}

    read -p "混淆模式 [off/http, 默认 off]: " obfs
    OBFS=${obfs:-off}
    if [ "$OBFS" = "http" ]; then
        read -p "请输入混淆 Host [默认 example.com]: " obfs_host
        OBFS_HOST=${obfs_host:-example.com}
    else
        OBFS_HOST=""
    fi

    read -p "是否启用 TCP Fast Open [true/false, 默认 true]: " tfo
    TFO=${tfo:-true}

    read -p "请输入 DNS [默认 8.8.8.8,1.1.1.1]: " dns
    DNS=${dns:-8.8.8.8,1.1.1.1}

    ECN=true

    # 生成 docker-compose.yml
    cat > "$NODE_DIR/docker-compose.yml" <<EOF
services:
  ${NODE_NAME}:
    image: 1byte/snell-server:latest
    container_name: ${NODE_NAME}
    restart: always
    ports:
      - "${PORT}:${PORT}"
    environment:
      PORT: "${PORT}"
      PSK: "${PSK}"
      IPv6: "${IPv6}"
      OBFS: "${OBFS}"
      OBFS_HOST: "${OBFS_HOST}"
      TFO: "${TFO}"
      DNS: "${DNS}"
      ECN: "${ECN}"
EOF

    cd "$NODE_DIR" || return
    docker compose up -d

    IP=$(hostname -I | awk '{print $1}')
    echo -e "${GREEN}✅ 节点 ${NODE_NAME} 已启动${RESET}"
    echo -e "${YELLOW}🌐 端口: ${PORT}${RESET}"
    echo -e "${YELLOW}🔑 PSK: ${PSK}${RESET}"
    echo -e "${YELLOW}📄 客户端配置: $NODE_NAME = snell, ${IP}, ${PORT}, psk=${PSK}, version=5, reuse=true, tfo=${TFO}, ecn=${ECN}${RESET}"
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

node_action_menu() {
    select_node || return
    while true; do
        echo -e "${GREEN}=== 节点 [$NODE_NAME] 管理 ===${RESET}"
        echo -e "${GREEN}1) 启动${RESET}"
        echo -e "${GREEN}2) 重启${RESET}"
        echo -e "${GREEN}3) 更新${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 卸载${RESET}"
        echo -e "${GREEN}0) 返回主菜单${RESET}"
        read -r -p $'\033[32m请选择操作: \033[0m' choice
        case $choice in
            1) docker compose -f "$NODE_DIR/docker-compose.yml" up -d ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose -f "$NODE_DIR/docker-compose.yml" pull && docker compose -f "$NODE_DIR/docker-compose.yml" up -d ;;
            4) docker logs -f "$NODE_NAME" ;;
            5) docker compose -f "$NODE_DIR/docker-compose.yml" down && rm -rf "$NODE_DIR" && return ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" ;;
        esac
    done
}

show_all_status() {
    list_nodes
    echo -e "${GREEN}=== 节点状态 ===${RESET}"
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        NODE_NAME=$(basename "$node")
        PORT=$(grep -oP '^\s+- "\K[0-9]+(?=:)' "$node/docker-compose.yml")
        STATUS=$(docker ps --filter "name=$NODE_NAME" --format "{{.Status}}")
        [ -z "$STATUS" ] && STATUS="未启动"
        echo -e "${GREEN}$NODE_NAME${RESET} | ${YELLOW}端口: ${RESET}${YELLOW}$PORT${RESET} | ${YELLOW}状态: ${STATUS}${RESET}"
    done
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Snell 节点管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动新节点${RESET}"
        echo -e "${GREEN}2) 管理已有节点${RESET}"
        echo -e "${GREEN}3) 查看所有节点状态${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -r -p $'\033[32m请选择操作: \033[0m' choice
        case $choice in
            1) install_node ;;
            2) node_action_menu ;;
            3) show_all_status ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
        esac
    done
}

menu
