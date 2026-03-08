#!/bin/bash
# ========================================
# Sing-box AnyTLS 多节点管理脚本（Host模式 + 自签证书）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="Singbox-AnyTLS"
APP_DIR="/root/$APP_NAME"

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
    if ss -tulnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。" && return
}

list_nodes() {
    mkdir -p "$APP_DIR"
    local count=0
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        count=$((count+1))
        echo -e "${GREEN}[$count] $(basename "$node")${RESET}"
    done
    [ $count -eq 0 ] && echo -e "${GREEN}无节点${RESET}"
}

select_node() {
    mkdir -p "$APP_DIR"
    local nodes=()
    local count=0
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        nodes+=("$(basename "$node")")
        count=$((count+1))
        echo -e "${GREEN}[$count] ${nodes[-1]}${RESET}"
    done
    [ $count -eq 0 ] && { echo -e "${RED}无节点！${RESET}"; return 1; }

    read -r -p $'\033[32m请输入节点名称或编号:\033[0m ' input

    if [[ "$input" =~ ^[0-9]+$ ]]; then
        if (( input >= 1 && input <= count )); then
            NODE_NAME="${nodes[$((input-1))]}"
        else
            echo -e "${RED}编号无效！${RESET}"
            return 1
        fi
    else
        NODE_NAME="$input"
        if [ ! -d "$APP_DIR/$NODE_NAME" ]; then
            echo -e "${RED}节点不存在！${RESET}"
            return 1
        fi
    fi
    NODE_DIR="$APP_DIR/$NODE_NAME"
}

install_node() {
    check_docker
    read -p "请输入节点名称 [默认node$(date +%s)]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-node$(date +%s)}
    NODE_DIR="$APP_DIR/$NODE_NAME"
    mkdir -p "$NODE_DIR"

    read -p "请输入端口 [默认随机]: " input_port
    PORT=${input_port:-$(shuf -i 20000-60000 -n1)}
    check_port "$PORT" || return

    read -p "请输入密码（留空将自动生成16位随机密码）: " PASSWORD
    PASSWORD=${PASSWORD:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c16)}

    echo -e "${YELLOW}正在生成自签证书...${RESET}"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$NODE_DIR/server.key" \
        -out "$NODE_DIR/server.crt" \
        -days 36500 \
        -subj "/CN=www.bing.com" \
        -addext "subjectAltName=DNS:www.bing.com" >/dev/null 2>&1

    cat > "$NODE_DIR/config.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "anytls",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [{ "password": "${PASSWORD}" }],
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "certificate_path": "/etc/sing-box/server.crt",
        "key_path": "/etc/sing-box/server.key"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

    cat > "$NODE_DIR/docker-compose.yml" <<EOF
services:
  ${NODE_NAME}:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: ${NODE_NAME}
    restart: always
    network_mode: host
    volumes:
      - ./config.json:/etc/sing-box/config.json
      - ./server.crt:/etc/sing-box/server.crt
      - ./server.key:/etc/sing-box/server.key
    command: run -c /etc/sing-box/config.json
EOF

    cd "$NODE_DIR" || return
    docker compose up -d

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}📂 安装目录: $NODE_DIR${RESET}"
    echo -e "${GREEN}✅ Singbox-AnyTLS 已启动${RESET}"
    echo -e "${YELLOW}🌐 IP: ${SERVER_IP}${RESET}"
    echo -e "${YELLOW}🔌 端口: ${PORT}${RESET}"
    echo -e "${YELLOW}🔑 密码: ${PASSWORD}${RESET}"
    echo
    echo -e "${YELLOW}📄 V6VPS替换IP地址为V6 ★${RESET}"
    echo -e "${YELLOW}V2rayN:${RESET}"
    echo -e "${YELLOW}anytls://${PASSWORD}@${SERVER_IP}:${PORT}/?sni=www.bing.com&insecure=1#${NODE_NAME}${RESET}"
    echo -e "${YELLOW}Surge :${RESET}"
    echo -e "${YELLOW}${NODE_NAME} = anytls, ${SERVER_IP}, ${PORT}, password=${PASSWORD}, tfo=true, skip-cert-verify=true, reuse=false${RESET}"
    echo
    cat > "$NODE_DIR/node.txt" <<EOF
V2rayN
anytls://${PASSWORD}@${SERVER_IP}:${PORT}/?sni=www.bing.com&insecure=1#${NODE_NAME}
Surge
${NODE_NAME} = anytls, ${SERVER_IP}, ${PORT}, password=${PASSWORD}, tfo=true, skip-cert-verify=true, reuse=false
EOF
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
        echo -e "${GREEN}6) 查看节点信息${RESET}"
        echo -e "${GREEN}0) 返回${RESET}"
        read -r -p $'\033[32m请选择操作:\033[0m ' choice
        case $choice in
            1) docker pause "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose -f "$NODE_DIR/docker-compose.yml" pull && docker compose -f "$NODE_DIR/docker-compose.yml" up -d ;;
            4) docker logs -f "$NODE_NAME" ;;
            5) docker compose -f "$NODE_DIR/docker-compose.yml" down && rm -rf "$NODE_DIR"; return ;;
            6) cat "$NODE_DIR/node.txt" ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" ;;
        esac
    done
}

batch_action() {
    echo -e "${GREEN}=== 批量操作 ===${RESET}"
    echo -e "${GREEN}1) 批量暂停${RESET}"
    echo -e "${GREEN}2) 批量重启${RESET}"
    echo -e "${GREEN}3) 批量更新${RESET}"
    echo -e "${GREEN}4) 批量卸载${RESET}"
    echo -e "${GREEN}0) 返回${RESET}"
    read -r -p $'\033[32m请选择操作:\033[0m ' choice
    [[ "$choice" == "0" ]] && return

    declare -A NODE_MAP
    local count=0
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        count=$((count+1))
        NODE_MAP[$count]=$(basename "$node")
        echo -e "${GREEN}[$count] ${NODE_MAP[$count]}${RESET}"
    done
    [ $count -eq 0 ] && { echo -e "${GREEN}无节点${RESET}"; read -r -p "回车返回..."; return; }

    read -r -p $'\033[32m请输入节点序号（空格分隔，或 all 全选）:\033[0m ' input
    if [[ "$input" == "all" ]]; then
        SELECTED=("${NODE_MAP[@]}")
    else
        SELECTED=()
        for i in $input; do
            [ -n "${NODE_MAP[$i]}" ] && SELECTED+=("${NODE_MAP[$i]}")
        done
    fi

    for NODE_NAME in "${SELECTED[@]}"; do
        NODE_DIR="$APP_DIR/$NODE_NAME"
        cd "$NODE_DIR" || continue
        case $choice in
            1) docker pause "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose pull && docker compose up -d ;;
            4) docker compose down && rm -rf "$NODE_DIR" ;;
        esac
        echo -e "${GREEN}已操作 $NODE_NAME${RESET}"
    done
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

show_all_status() {
    echo -e "${GREEN}=== 所有节点状态 ===${RESET}"
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        NODE_NAME=$(basename "$node")
        PORT=$(grep 'listen_port' "$node/config.json" | awk -F: '{gsub(/[ ,"]/,"",$2); print $2}')
        STATUS=$(docker inspect -f '{{.State.Status}}' "$NODE_NAME" 2>/dev/null)
        [ -z "$STATUS" ] && STATUS="未启动"
        echo -e "${GREEN}$NODE_NAME | ${PORT:-未知端口} | $STATUS${RESET}"
    done
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Singbox-AnyTLS 多节点管理 ===${RESET}"
        echo -e "${GREEN}1) 安装新节点${RESET}"
        echo -e "${GREEN}2) 单节点管理${RESET}"
        echo -e "${GREEN}3) 查看所有节点状态${RESET}"
        echo -e "${GREEN}4) 批量操作${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -r -p $'\033[32m请选择:\033[0m ' choice
        case $choice in
            1) install_node ;;
            2) node_action_menu ;;
            3) show_all_status ;;
            4) batch_action ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

menu
