#!/bin/bash
# ========================================
# Shadowsocks-rust 多节点管理脚本（支持 2022-blake3-aes-256-gcm）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="ss-rust"
APP_DIR="/opt/$APP_NAME"

# ===== 检查 Docker =====
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

# ===== 检查端口 =====
check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

# ===== 列出节点 =====
list_nodes() {
    mkdir -p "$APP_DIR"
    echo -e "${GREEN}=== 已有 Shadowsocks 节点 ===${RESET}"
    local count=0
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        count=$((count+1))
        echo -e "${YELLOW}[$count] $(basename "$node")${RESET}"
    done
    [ $count -eq 0 ] && echo -e "${YELLOW}无节点${RESET}"
}

# ===== 选择节点 =====
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

# ===== 安装节点 =====
install_node() {
    check_docker
    read -p "请输入节点名称 [node$(date +%s)]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-node$(date +%s)}
    NODE_DIR="$APP_DIR/$NODE_NAME"
    mkdir -p "$NODE_DIR"

    read -p "请输入监听端口 [1025-65535, 默认随机]: " input_port
    PORT=${input_port:-$(shuf -i 1025-65000 -n1)}
    check_port "$PORT" || return

    METHOD="2022-blake3-aes-256-gcm"

    # 自动生成二进制 key 文件
    KEY_FILE="$NODE_DIR/ss2022.key"
    openssl rand 32 > "$KEY_FILE"

    # 生成 docker-compose.yml
    cat > "$NODE_DIR/docker-compose.yml" <<EOF
services:
  ${NODE_NAME}:
    image: teddysun/shadowsocks-rust
    container_name: ${NODE_NAME}
    restart: always
    ports:
      - "${PORT}:${PORT}/tcp"
      - "${PORT}:${PORT}/udp"
    environment:
      - SERVER_PORT=${PORT}
      - METHOD=${METHOD}
      - PASSWORD_FILE=/key/ss2022.key
    volumes:
      - ./ss2022.key:/key/ss2022.key:ro
EOF

    cd "$NODE_DIR" || return
    docker compose up -d

    IP4=$(hostname -I | awk '{print $1}')
    IP6=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n1)

    # 读取 key 文件生成 Base64 显示给客户端
    PASSWORD=$(cat "$KEY_FILE" | base64)

    echo "————————————————————————————————————————"
    echo "Shadowsocks Rust 配置："
    echo " 地址：$IP4"
    [ -n "$IP6" ] && echo " 地址：$IP6"
    echo " 端口：$PORT"
    echo " 密码：$PASSWORD"
    echo " 加密：$METHOD"
    echo " TFO ：true"
    echo "————————————————————————————————————————"
    echo "链接 [IPv4]：ss://${METHOD}:${PASSWORD}@$IP4:$PORT"
    [ -n "$IP6" ] && echo "链接 [IPv6]：ss://${METHOD}:${PASSWORD}@$IP6:$PORT"
    echo "—————————————————————————"
    echo "[信息] Surge 配置："
    echo "localhost = ss, $IP4,$PORT, encrypt-method=$METHOD, password=$PASSWORD, tfo=true, udp-relay=true, ecn=true"
    echo "————————————————————————————————————————"

    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

# ===== 节点单独管理菜单 =====
node_action_menu() {
    select_node || return
    while true; do
        echo -e "${GREEN}=== 节点 [$NODE_NAME] 管理 ===${RESET}"
        echo -e "${GREEN}1) 暂停${RESET}"
        echo -e "${GREEN}2) 重启${RESET}"
        echo -e "${GREEN}3) 更新镜像并重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 卸载${RESET}"
        echo -e "${GREEN}0) 返回主菜单${RESET}"
        read -r -p $'\033[32m请选择操作: \033[0m' choice
        case $choice in
            1) docker pause "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose -f "$NODE_DIR/docker-compose.yml" pull && docker compose -f "$NODE_DIR/docker-compose.yml" up -d ;;
            4) docker logs -f "$NODE_NAME" ;;
            5) docker compose -f "$NODE_DIR/docker-compose.yml" down && rm -rf "$NODE_DIR" && return ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" ;;
        esac
    done
}

# ===== 查看所有节点状态 =====
show_all_status() {
    list_nodes
    echo -e "${GREEN}=== 节点状态 ===${RESET}"
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        NODE_NAME=$(basename "$node")
        PORT=$(grep -oP 'SERVER_PORT=\K[0-9]+' "$node/docker-compose.yml")
        STATUS=$(docker ps --filter "name=$NODE_NAME" --format "{{.Status}}")
        [ -z "$STATUS" ] && STATUS="未启动"
        echo -e "${GREEN}$NODE_NAME${RESET} | ${YELLOW}端口: ${PORT}${RESET} | ${YELLOW}状态: ${STATUS}${RESET}"
    done
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

# ===== 批量操作 =====
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
            [ -n "$NODE" ] && SELECTED_NODES+=("$NODE")
        done
    fi

    for NODE_NAME in "${SELECTED_NODES[@]}"; do
        NODE_DIR="$APP_DIR/$NODE_NAME"
        [ ! -d "$NODE_DIR" ] && continue

        cd "$NODE_DIR" || continue
        case $choice in
            1) docker pause "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose pull && docker compose up -d ;;
            4) docker compose down && rm -rf "$NODE_DIR" ;;
            0) return ;;
        esac
        echo -e "${GREEN}✅ 节点 $NODE_NAME 操作完成${RESET}"
    done

    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

# ===== 主菜单 =====
menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Shadowsocks-rust 节点管理菜单 ===${RESET}"
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
