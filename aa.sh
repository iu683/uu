#!/bin/bash
# ========================================
# Xray Reality 多节点管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="xray-reality"
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

list_nodes() {
    mkdir -p "$APP_DIR"
    echo -e "${GREEN}=== 已有 Xray Reality 节点 ===${RESET}"
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

generate_keys() {
    UUID=$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)
    read -p "是否自动生成 Reality 密钥对？[Y/n]: " keygen
    keygen=${keygen:-Y}
    if [[ "$keygen" =~ ^[Yy]$ ]]; then
        X25519=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519)
        PRIVATE_KEY=$(echo "$X25519" | awk 'NR==1{print $1}')
        PUBLIC_KEY=$(echo "$X25519" | awk 'NR==2{print $1}')
    else
        read -p "请输入 PrivateKey: " PRIVATE_KEY
        read -p "请输入 PublicKey: " PUBLIC_KEY
    fi
    SHORT_ID=$(openssl rand -hex 8)
}

install_node() {
    check_docker
    read -p "请输入节点名称 [node$(date +%s)]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-node$(date +%s)}
    NODE_DIR="$APP_DIR/$NODE_NAME"
    mkdir -p "$NODE_DIR"

    # 随机端口
    random_port() {
        while :; do
            PORT=$(shuf -i 2000-65000 -n1)
            ss -lnt | awk '{print $4}' | grep -q ":$PORT$" || break
        done
        echo "$PORT"
    }

    read -p "请输入监听端口 [默认随机]: " PORT
    PORT=${PORT:-$(random_port)}
    echo -e "${YELLOW}使用端口: ${PORT}${RESET}"

    read -p "请输入伪装域名 [默认 itunes.apple.com]: " DOMAIN
    DOMAIN=${DOMAIN:-itunes.apple.com}

    UUID=$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)
    X25519=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519)

    PRIVATE_KEY=$(echo "$X25519" | grep "PrivateKey" | awk -F': ' '{print $2}')
    PUBLIC_KEY=$(echo "$X25519"  | grep "Password"   | awk -F': ' '{print $2}')
    SHORT_ID=$(openssl rand -hex 8)

    CONFIG_FILE="$NODE_DIR/config.json"
    COMPOSE_FILE="$NODE_DIR/compose.yml"

    # 生成 config.json（去掉 DNS 配置）
    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log", "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": { "clients": [{"id":"$UUID","flow":"xtls-rprx-vision","level":0,"email":"user@example.com"}], "decryption":"none" },
      "streamSettings": {
        "network":"tcp",
        "security":"reality",
        "realitySettings": {"show":false,"dest":"$DOMAIN:443","xver":0,"serverNames":["$DOMAIN"],"privateKey":"$PRIVATE_KEY","shortIds":["$SHORT_ID"]}
      }
    }
  ],
  "outbounds":[{"protocol":"freedom","settings":{}}]
}
EOF

    # 生成 docker-compose.yml（host 网络模式）
    cat > "$COMPOSE_FILE" <<EOF
services:
  $NODE_NAME:
    image: ghcr.io/xtls/xray-core:latest
    container_name: $NODE_NAME
    restart: unless-stopped
    network_mode: "host"
    command: ["run","-c","/etc/xray/config.json"]
    volumes:
      - ./config.json:/etc/xray/config.json:ro
EOF

    cd "$NODE_DIR" || exit
    docker compose up -d

    IP=$(hostname -I | awk '{print $1}')
    TAG=$(hostname -s)
    VLESS_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${TAG}"

    echo -e "${GREEN}✅ 节点 $NODE_NAME 已启动${RESET}"
    echo -e "${YELLOW}$VLESS_LINK${RESET}"
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
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
        echo -e "${GREEN}0) 返回主菜单${RESET}"
        read -r -p $'\033[32m请选择操作: \033[0m' choice
        case $choice in
            1) docker pause "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose -f "$NODE_DIR/compose.yml" pull && docker compose -f "$NODE_DIR/compose.yml" up -d ;;
            4) docker logs -f "$NODE_NAME" ;;
            5) docker compose -f "$NODE_DIR/compose.yml" down && rm -rf "$NODE_DIR" && return ;;
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
        PORT=$(grep -oP '^\s+- "\K[0-9]+(?=:)' "$node/compose.yml")
        STATUS=$(docker ps --filter "name=$NODE_NAME" --format "{{.Status}}")
        [ -z "$STATUS" ] && STATUS="未启动"
        echo -e "${GREEN}$NODE_NAME${RESET} | ${YELLOW}端口: ${RESET}${YELLOW}$PORT${RESET} | ${YELLOW}状态: ${STATUS}${RESET}"
    done
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

batch_action() {
    echo -e "${GREEN}=== 批量操作 ===${RESET}"
    echo -e "${GREEN}1) 暂停节点${RESET}"
    echo -e "${GREEN}2) 重启节点${RESET}"
    echo -e "${GREEN}3) 更新节点${RESET}"
    echo -e "${GREEN}4) 卸载节点${RESET}"
    echo -e "${GREEN}0) 返回主菜单${RESET}"
    read -r -p $'\033[32m请选择操作: \033[0m' choice

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
    [ $count -eq 0 ] && { echo -e "${YELLOW}无节点${RESET}"; read -r -p $'\033[32m按回车返回菜单...\033[0m' ; return ; }

    read -r -p $'\033[32m请输入要操作的节点序号（用空格分隔，或输入 all 全选）: \033[0m' input_nodes
    if [[ "$input_nodes" == "all" ]]; then
        SELECTED_NODES=("${NODE_MAP[@]}")
    else
        SELECTED_NODES=()
        for i in $input_nodes; do
            NODE=${NODE_MAP[$i]}
            [ -n "$NODE" ] && SELECTED_NODES+=("$NODE") || echo -e "${YELLOW}⚠ 序号 $i 无效，跳过${RESET}"
        done
    fi

    for NODE_NAME in "${SELECTED_NODES[@]}"; do
        NODE_DIR="$APP_DIR/$NODE_NAME"
        [ -d "$NODE_DIR" ] || continue
        [ -f "$NODE_DIR/compose.yml" ] || { echo -e "${YELLOW}⚠ 节点 $NODE_NAME docker-compose.yml 不存在，跳过${RESET}"; continue; }
        cd "$NODE_DIR" || continue

        case $choice in
            1) docker pause "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose pull && docker compose up -d ;;
            4) docker compose down && rm -rf "$NODE_DIR" ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" ; return ;;
        esac
        echo -e "${GREEN}✅ 节点 $NODE_NAME 操作完成${RESET}"
    done
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Xray Reality 多节点管理菜单 ===${RESET}"
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
