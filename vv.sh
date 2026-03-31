#!/bin/bash
# ========================================
# Xray VMess WS 多节点管理脚本（无TLS）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="xray-vmess-ws"
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
    if ! command -v jq &>/dev/null; then
        echo -e "${YELLOW}安装 jq...${RESET}"
        apt update && apt install -y jq
    fi
}

random_port() {
    while :; do
        PORT=$(shuf -i 2000-65000 -n1)
        ss -lntu | grep -q ":$PORT " || break
    done
    echo "$PORT"
}

list_nodes() {
    mkdir -p "$APP_DIR"
    echo -e "${GREEN}=== 已有 VMess 节点 ===${RESET}"
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
        NODE_NAME=$(ls -d "$APP_DIR"/* 2>/dev/null | sed -n "${input}p" | xargs basename)
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

    read -p "请输入节点名称 [默认node$(date +%s)]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-node$(date +%s)}
    NODE_DIR="$APP_DIR/$NODE_NAME"
    mkdir -p "$NODE_DIR"

    read -p "请输入端口 [默认随机]: " PORT
    PORT=${PORT:-$(random_port)}

    if ss -lntu | grep -q ":$PORT "; then
        echo -e "${RED}端口已被占用${RESET}"
        return
    fi

    read -p "请输入服务器IP或域名: " DOMAIN
    [ -z "$DOMAIN" ] && { echo -e "${RED}不能为空${RESET}"; return; }

    read -p "请输入 WebSocket Host (可留空): " WS_HOST

    read -p "请输入 WebSocket Path [默认 /ws]: " WS_PATH
    WS_PATH=${WS_PATH:-/ws}

    UUID=$(cat /proc/sys/kernel/random/uuid)

    CONFIG_FILE="$NODE_DIR/config.json"
    COMPOSE_FILE="$NODE_DIR/docker-compose.yml"

cat > "$CONFIG_FILE" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vmess",
      "settings": {
        "clients": [
          { "id": "$UUID", "alterId": 0 }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "$WS_PATH",
          "headers": {
            "Host": "$WS_HOST"
          }
        }
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
    command: ["run","-c","/etc/xray/config.json"]
    volumes:
      - ./config.json:/etc/xray/config.json:ro
    ports:
      - "$PORT:$PORT/tcp"
EOF

    cd "$NODE_DIR"
    docker compose up -d

VMESS_JSON=$(jq -n \
--arg v "2" \
--arg ps "$NODE_NAME" \
--arg add "$DOMAIN" \
--arg port "$PORT" \
--arg id "$UUID" \
--arg aid "0" \
--arg net "ws" \
--arg type "none" \
--arg host "$WS_HOST" \
--arg path "$WS_PATH" \
--arg tls "" \
'{
v:$v,
ps:$ps,
add:$add,
port:$port,
id:$id,
aid:$aid,
net:$net,
type:$type,
host:$host,
path:$path,
tls:$tls
}' | base64 | tr -d '\n')

echo
echo -e "${GREEN}📂 安装目录: $NODE_DIR${RESET}"
echo -e "${GREEN}✅ VMess-WS 节点已启动${RESET}"
echo -e "${YELLOW}🌐 地址: ${DOMAIN}${RESET}"
echo -e "${YELLOW}🔌 端口: ${PORT}${RESET}"
echo -e "${YELLOW}🆔 UUID: ${UUID}${RESET}"
echo -e "${YELLOW}🌐 Host: $WS_HOST${RESET}"
echo -e "${YELLOW}🌐 Path: $WS_PATH${RESET}"

echo
echo -e "${YELLOW}📄 V2rayN链接:${RESET}"
echo -e "${YELLOW}vmess://${VMESS_JSON}${RESET}"

echo -e "${YELLOW}📄 Surge配置:${RESET}"
echo -e "${YELLOW}$NODE_NAME = vmess, ${DOMAIN}, ${PORT}, username=${UUID}, ws=true, ws-path=$WS_PATH, ws-headers=Host:\"$WS_HOST\", vmess-aead=true, tls=false${RESET}"

cat > "$NODE_DIR/node.txt" <<EOF
V2rayN链接
vmess://${VMESS_JSON}

Surge配置
$NODE_NAME = vmess, ${DOMAIN}, ${PORT}, username=${UUID}, ws=true, ws-path=$WS_PATH, ws-headers=Host:"$WS_HOST", vmess-aead=true, tls=false
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
        echo -e "${GREEN}0) 返回主菜单${RESET}"
        read -r -p $'\033[32m请选择操作: \033[0m' choice
        case $choice in
            1) docker pause "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) (cd "$NODE_DIR" && docker compose pull && docker compose up -d) ;;
            4) docker logs -f "$NODE_NAME" ;;
            5) docker compose -f "$NODE_DIR/docker-compose.yml" down && rm -rf "$NODE_DIR" && return ;;
            6) cat "$NODE_DIR/node.txt" ;;
            0) return ;;
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
        echo -e "${GREEN}$NODE_NAME | 端口:$PORT | 状态:$STATUS${RESET}"
    done
    read -p "按回车返回菜单..."
}

batch_action() {

    mkdir -p "$APP_DIR"

    NODE_LIST=()
    local count=0

    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        count=$((count+1))
        NODE_NAME=$(basename "$node")
        NODE_LIST+=("$NODE_NAME")
    done

    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}无节点${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    echo -e "${GREEN}=== 批量管理节点 ===${RESET}"
    echo -e "${GREEN}1) 暂停节点${RESET}"
    echo -e "${GREEN}2) 重启节点${RESET}"
    echo -e "${GREEN}3) 更新节点${RESET}"
    echo -e "${GREEN}4) 卸载节点${RESET}"
    echo -e "${GREEN}0) 返回菜单${RESET}"
    read -r -p $'\033[32m请选择: \033[0m' action

    [[ "$action" == "0" ]] && return

    echo
    echo -e "${GREEN}节点列表:${RESET}"

    count=0
    for node in "${NODE_LIST[@]}"; do
        count=$((count+1))
        echo -e "${YELLOW}[$count] $node${RESET}"
    done

    echo
    read -r -p $'\033[32m请输入节点序号（空格分隔，或输入 all）: \033[0m' input

    SELECTED=()

    if [[ "$input" == "all" ]]; then
        SELECTED=("${NODE_LIST[@]}")
    else
        for i in $input; do
            if [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "${#NODE_LIST[@]}" ]; then
                SELECTED+=("${NODE_LIST[$((i-1))]}")
            fi
        done
    fi

    for NODE_NAME in "${SELECTED[@]}"; do

        NODE_DIR="$APP_DIR/$NODE_NAME"

        case $action in

            1)
                docker pause "$NODE_NAME"
                ;;

            2)
                docker restart "$NODE_NAME"
                ;;

            3)
                (cd "$NODE_DIR" && docker compose pull && docker compose up -d)
                ;;

            4)
                (cd "$NODE_DIR" && docker compose down && rm -rf "$NODE_DIR")
                ;;

        esac

        echo -e "${GREEN}完成 $NODE_NAME${RESET}"

    done

    read -p "按回车返回菜单..."
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Xray VMess WS 多节点管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动新节点${RESET}"
        echo -e "${GREEN}2) 管理已有节点${RESET}"
        echo -e "${GREEN}3) 查看所有节点状态${RESET}"
        echo -e "${GREEN}4) 管理所有节点${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -r -p $'\033[32m请选择操作: \033[0m' choice
        case $choice in
            1) install_node ;;
            2) node_action_menu ;;
            3) show_all_status ;;
            4) batch_action ;;
            0) exit 0 ;;
        esac
    done
}

menu
