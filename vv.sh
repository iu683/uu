#!/bin/bash
# ========================================
# Xray Reality XHTTP 多节点管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="xray-realityxhttp"
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

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP"
}

list_nodes() {
    mkdir -p "$APP_DIR"
    echo -e "${GREEN}=== 已有节点 ===${RESET}"
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
        echo -e "${RED}节点不存在${RESET}"
        return 1
    fi
}

install_node() {

    check_docker
    mkdir -p "$APP_DIR"

    read -p "请输入节点名称 [默认node$(date +%s)]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-node$(date +%s)}

    NODE_DIR="$APP_DIR/$NODE_NAME"
    mkdir -p "$NODE_DIR"

    random_port() {
        while :; do
            PORT=$(shuf -i 2000-65000 -n 1)
            ss -lnt | awk '{print $4}' | grep -q ":$PORT$" || break
        done
        echo "$PORT"
    }

    read -p "请输入监听端口 [默认随机]: " PORT
    [[ -z "$PORT" ]] && PORT=$(random_port)

    echo -e "${YELLOW}使用端口: ${PORT}${RESET}"

    read -p "请输入伪装域名 [默认 learn.microsoft.com]: " DOMAIN
    DOMAIN=${DOMAIN:-learn.microsoft.com}

    X25519=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519)

    PRIVATE_KEY=$(echo "$X25519" | grep "PrivateKey" | awk -F': ' '{print $2}')
    PUBLIC_KEY=$(echo "$X25519" | grep "PublicKey" | awk -F': ' '{print $2}')

    UUID=$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)

    SHORT_ID=$(openssl rand -hex 8)

    XHTTP_PATH="/$(openssl rand -hex 4)"

    CONFIG_FILE="$NODE_DIR/config.json"
    COMPOSE_FILE="$NODE_DIR/compose.yml"

cat > "$CONFIG_FILE" <<EOF
{
"log": {
"loglevel": "warning"
},
"inbounds": [
{
"port": $PORT,
"protocol": "vless",
"settings": {
"clients": [
{
"id": "$UUID",
"level": 0
}
],
"decryption": "none"
},
"streamSettings": {
"network": "xhttp",
"security": "reality",
"realitySettings": {
"show": false,
"dest": "$DOMAIN:443",
"xver": 0,
"serverNames": ["$DOMAIN"],
"privateKey": "$PRIVATE_KEY",
"shortIds": ["$SHORT_ID"]
},
"xhttpSettings": {
"path": "$XHTTP_PATH",
"mode": "auto"
}
},
"sniffing": {
"enabled": true,
"destOverride": ["http","tls","quic"]
}
}
],
"outbounds": [
{ "protocol": "freedom" }
]
}
EOF

cat > "$COMPOSE_FILE" <<EOF
services:
  $NODE_NAME:
    image: ghcr.io/xtls/xray-core:latest
    container_name: $NODE_NAME
    restart: unless-stopped
    network_mode: host
    command: ["run","-c","/etc/xray/config.json"]
    volumes:
      - ./config.json:/etc/xray/config.json:ro
EOF

    cd "$NODE_DIR" || exit

    docker compose up -d

    IP=$(get_public_ip)

    TAG=$NODE_NAME

    ENCODED_PATH=$(echo -n "$XHTTP_PATH" | sed 's/\//%2F/g')

    VLESS_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${ENCODED_PATH}&mode=auto#${TAG}"

    echo
    echo -e "${GREEN}--- Xray VLESS-Reality-XHTTP 订阅信息 ---${RESET}"

    echo -e "${YELLOW}名称: ${TAG}${RESET}"
    echo -e "${YELLOW}地址: ${IP}${RESET}"
    echo -e "${YELLOW}端口: ${PORT}${RESET}"
    echo -e "${YELLOW}UUID: ${UUID}${RESET}"
    echo -e "${YELLOW}路径: ${XHTTP_PATH}${RESET}"
    echo -e "${YELLOW}SNI: ${DOMAIN}${RESET}"
    echo -e "${YELLOW}公钥: ${PUBLIC_KEY}${RESET}"
    echo -e "${YELLOW}ShortId: ${SHORT_ID}${RESET}"

    echo "------------------------------------------------"
    echo -e "${YELLOW}V6VPS替换IP地址为V6${RESET}"
    echo -e "${GREEN}订阅链接:${RESET}"
    echo -e "${YELLOW}${VLESS_LINK}${RESET}"

cat > "$NODE_DIR/node.txt" <<EOF
Xray VLESS-Reality-XHTTP 订阅信息
名称: ${TAG}
地址: ${IP}
端口: ${PORT}
UUID: ${UUID}
路径: ${XHTTP_PATH}
SNI: ${DOMAIN}
公钥: ${PUBLIC_KEY}
ShortId: ${SHORT_ID}
订阅链接:
${VLESS_LINK}
EOF

    read -p "按回车返回菜单..."
}

node_action_menu() {

    select_node || return

    while true; do

        echo -e "${GREEN}=== 节点 [$NODE_NAME] 管理 ===${RESET}"
        echo -e "${GREEN}1) 暂停${RESET}"
        echo -e "${GREEN}2) 重启${RESET}"
        echo -e "${GREEN}3) 更新${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 卸载${RESET}"
        echo -e "${GREEN}6) 查看节点信息${RESET}"
        echo -e "${GREEN}0) 返回${RESET}"

        read -r -p $'\033[32m请选择操作: \033[0m' choice

        case $choice in
            1) docker pause "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose -f "$NODE_DIR/compose.yml" pull && docker compose -f "$NODE_DIR/compose.yml" up -d ;;
            4) docker logs -f "$NODE_NAME" ;;
            5) docker compose -f "$NODE_DIR/compose.yml" down && rm -rf "$NODE_DIR" && return ;;
            6) cat "$NODE_DIR/node.txt" ;;
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

        PORT=$(grep '"port"' "$node/config.json" | head -n1 | awk -F': ' '{print $2}' | tr -d ',')

        STATUS=$(docker inspect -f '{{.State.Status}}' "$NODE_NAME" 2>/dev/null)

        case "$STATUS" in
            running) STATUS_COLOR="${GREEN}运行中${RESET}" ;;
            paused) STATUS_COLOR="${YELLOW}已暂停${RESET}" ;;
            *) STATUS_COLOR="${RED}未启动${RESET}" ;;
        esac

        echo -e "${GREEN}$NODE_NAME${RESET} | 端口: ${YELLOW}$PORT${RESET} | 状态: $STATUS_COLOR"

    done

    read -p "按回车返回菜单..."
}

batch_action() {

    echo -e "${GREEN}=== 批量操作 ===${RESET}"
    echo -e "${GREEN}1) 暂停节点${RESET}"
    echo -e "${GREEN}2) 重启节点${RESET}"
    echo -e "${GREEN}3) 更新节点${RESET}"
    echo -e "${GREEN}4) 卸载节点${RESET}"
    echo -e "${GREEN}0) 返回${RESET}"

    read -r -p $'\033[32m请选择操作: \033[0m' choice

    case "$choice" in
        1|2|3|4) ;;
        0) return ;;
        *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ; return ;;
    esac

    mkdir -p "$APP_DIR"

    declare -A NODE_MAP

    local count=0

    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        count=$((count+1))
        NODE_NAME=$(basename "$node")
        NODE_MAP[$count]="$NODE_NAME"
        echo -e "${YELLOW}[$count] $NODE_NAME${RESET}"
    done

    read -r -p $'\033[32m请输入节点序号（空格分隔或 all）: \033[0m' input_nodes

    if [[ "$input_nodes" == "all" ]]; then
        SELECTED_NODES=("${NODE_MAP[@]}")
    else
        SELECTED_NODES=()
        for i in $input_nodes; do
            NODE=${NODE_MAP[$i]}
            [ -n "$NODE" ] && SELECTED_NODES+=("$NODE")
        done
    fi

    for NODE_NAME in "${SELECTED_NODES[@]}"; do

        NODE_DIR="$APP_DIR/$NODE_NAME"

        cd "$NODE_DIR" || continue

        case "$choice" in
            1) docker pause "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose pull && docker compose up -d ;;
            4) docker compose down && rm -rf "$NODE_DIR" ;;
        esac

        echo -e "${GREEN}节点 $NODE_NAME 操作完成${RESET}"

    done

    read -p "按回车返回菜单..."
}

menu() {

    while true; do

        clear

        echo -e "${GREEN}=== Xray-Reality-XHTTP 多节点管理 ===${RESET}"
        echo -e "${GREEN}1) 安装启动新节点${RESET}"
        echo -e "${GREEN}2) 管理已有节点${RESET}"
        echo -e "${GREEN}3) 查看所有节点状态${RESET}"
        echo -e "${GREEN}4) 批量操作节点${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"

        read -r -p $'\033[32m请选择操作: \033[0m' choice

        case $choice in
            1) install_node ;;
            2) node_action_menu ;;
            3) show_all_status ;;
            4) batch_action ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
        esac
    done
}

menu
