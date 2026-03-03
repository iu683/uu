#!/bin/bash
# ========================================
# Snell + ShadowTLS 多节点管理脚本（Host 模式 + 彩色菜单 + 批量操作）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="SnellShadowTLS"
APP_DIR="/opt/$APP_NAME"

# ===== Docker 检测 =====
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

# ===== 检查端口，循环直到可用 =====
check_port_loop() {
    local port=$1
    while true; do
        if ss -tlnp 2>/dev/null | grep -q ":$port\b"; then
            echo -e "${RED}端口 $port 已被占用，请重新输入！${RESET}"
            read -p "请输入新的端口: " port
        else
            echo $port
            return
        fi
    done
}

# ===== 列出节点 =====
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

# ===== 安装新节点 =====
install_node() {
    check_docker
    read -p "请输入节点名称 [node$(date +%s)]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-node$(date +%s)}
    NODE_DIR="$APP_DIR/$NODE_NAME"
    mkdir -p "$NODE_DIR"

    # ===== Snell 内部端口 =====
    read -p "请输入 Snell 内部端口 [20000-40000, 默认随机]: " input_port
    input_port=${input_port:-$(shuf -i 20000-40000 -n1)}
    PORT=$(check_port_loop "$input_port")

    # ===== ShadowTLS 对外端口 =====
    read -p "请输入 ShadowTLS 对外端口 [默认 8443]: " tls_input
    tls_input=${tls_input:-8443}
    TLS_PORT=$(check_port_loop "$tls_input")

    # ===== IPv6 开关 =====
    read -p "是否启用 IPv6 [true/false, 默认 false]: " ipv6
    IPv6=${ipv6:-false}

    # ===== 密钥 =====
    read -s -p "请输入 Snell PSK（留空自动生成）: " input_psk; echo
    PSK=${input_psk:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c32)}

    read -s -p "请输入 ShadowTLS 密码（留空自动生成）: " input_tls; echo
    TLS_PASSWORD=${input_tls:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c16)}

    read -p "请输入 TLS 伪装域名 [默认 captive.apple.com]: " tls_host
    TLS_HOST=${tls_host:-captive.apple.com}

    # ===== Snell 配置 =====
    CONF_FILE="$NODE_DIR/snell-server.conf"
    cat > "$CONF_FILE" <<EOF
[snell-server]
listen = 0.0.0.0:$PORT
psk = $PSK
tfo = true
ecn = true
EOF

    [[ "$IPv6" == "true" ]] && echo "listen = [::]:$PORT" >> "$CONF_FILE"

    # ===== ShadowTLS 地址 =====
    if [[ "$IPv6" == "true" ]]; then
        SERVER_ADDR="[::1]:${PORT}"
        TLS_LISTEN="[::]:${TLS_PORT}"
    else
        SERVER_ADDR="127.0.0.1:${PORT}"
        TLS_LISTEN="0.0.0.0:${TLS_PORT}"
    fi

    # ===== Docker Compose =====
    COMPOSE_FILE="$NODE_DIR/docker-compose.yml"
    cat > "$COMPOSE_FILE" <<EOF
services:
  snell:
    image: 1byte/snell-server:latest
    container_name: snell-$NODE_NAME
    restart: always
    network_mode: host
    volumes:
      - ./snell-server.conf:/app/snell-server.conf:ro

  shadow-tls:
    image: ghcr.io/ihciah/shadow-tls:latest
    container_name: shadow-tls-$NODE_NAME
    restart: unless-stopped
    network_mode: host
    environment:
      MODE: "server"
      V3: "1"
      LISTEN: "${TLS_LISTEN}"
      SERVER: "${SERVER_ADDR}"
      TLS: "${TLS_HOST}:443"
      PASSWORD: "${TLS_PASSWORD}"
EOF

    # ===== 启动 =====
    cd "$NODE_DIR" || return
    docker compose up -d

    # ===== 输出客户端配置 =====
    IP=$(hostname -I | awk '{print $1}')
    HOSTNAME=$(hostname -s | sed 's/ /_/g')
    echo
    echo -e "${GREEN}📂 安装目录: $NODE_DIR${RESET}"
    echo -e "${GREEN}✅ Snell + ShadowTLS 已启动${RESET}"
    echo -e "${YELLOW}🌐 Snell 内部端口: $PORT${RESET}"
    echo -e "${YELLOW}🌐 ShadowTLS 对外端口: $TLS_PORT${RESET}"
    echo -e "${YELLOW}🔑 Snell PSK: $PSK${RESET}"
    echo -e "${YELLOW}🔑 ShadowTLS 密码: $TLS_PASSWORD${RESET}"
    echo -e "${YELLOW}🌐 SNI: $TLS_HOST${RESET}"
    echo
    echo -e "${GREEN}📄 V6VPS替换IP地址为V6⭐${RESET}"
    echo -e "${YELLOW}📄 客户端配置模板:${RESET}"
    echo -e "${YELLOW}$NODE_NAME = snell, ${IP}, ${TLS_PORT}, psk = ${PSK}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${TLS_PASSWORD}, shadow-tls-sni = ${TLS_HOST}, shadow-tls-version = 3${RESET}"
    read -p "按回车返回菜单..."
}

# ===== 节点操作菜单 =====
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
            1) docker pause snell-$NODE_NAME shadow-tls-$NODE_NAME ;;
            2) docker restart snell-$NODE_NAME shadow-tls-$NODE_NAME ;;
            3) docker compose -f "$NODE_DIR/docker-compose.yml" pull && docker compose -f "$NODE_DIR/docker-compose.yml" up -d ;;
            4) docker compose -f "$NODE_DIR/docker-compose.yml" logs -f ;;
            5) docker compose -f "$NODE_DIR/docker-compose.yml" down && rm -rf "$NODE_DIR" && return ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" ;;
        esac
    done
}

# ===== 批量操作 =====
batch_action() {
    echo -e "${GREEN}=== 批量操作节点 ===${RESET}"
    echo -e "${GREEN}1) 暂停节点${RESET}"
    echo -e "${GREEN}2) 重启节点${RESET}"
    echo -e "${GREEN}3) 更新节点${RESET}"
    echo -e "${GREEN}4) 卸载节点${RESET}"
    echo -e "${GREEN}0) 返回主菜单${RESET}"

    read -r -p $'\033[32m请选择操作: \033[0m' choice
    [[ "$choice" == 0 ]] && return

    mkdir -p "$APP_DIR"
    declare -A NODE_MAP
    local count=0

    # ===== 列出节点 =====
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        count=$((count+1))
        NODE_NAME=$(basename "$node")
        NODE_MAP[$count]="$NODE_NAME"
        echo -e "${YELLOW}[$count] $NODE_NAME${RESET}"
    done

    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}无节点${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    # ===== 选择节点 =====
    read -r -p $'\033[32m请输入节点序号（空格分隔，或 all 全选）: \033[0m' input_nodes
    if [[ "$input_nodes" == "all" ]]; then
        SELECTED_NODES=("${NODE_MAP[@]}")
    else
        SELECTED_NODES=()
        for i in $input_nodes; do
            NODE=${NODE_MAP[$i]}
            [ -n "$NODE" ] && SELECTED_NODES+=("$NODE")
        done
    fi

    # ===== 执行操作 =====
    for NODE_NAME in "${SELECTED_NODES[@]}"; do
        NODE_DIR="$APP_DIR/$NODE_NAME"
        [ ! -f "$NODE_DIR/docker-compose.yml" ] && continue
        cd "$NODE_DIR" || continue
        case "$choice" in
            1) docker pause snell-$NODE_NAME 2>/dev/null && docker pause shadow-tls-$NODE_NAME 2>/dev/null ;;
            2) docker restart snell-$NODE_NAME 2>/dev/null && docker restart shadow-tls-$NODE_NAME 2>/dev/null ;;
            3) docker compose pull && docker compose up -d ;;
            4) docker compose down && rm -rf "$NODE_DIR" ;;
        esac
        echo -e "${GREEN}✅ 节点 $NODE_NAME 操作完成${RESET}"
    done
    read -p "按回车返回菜单..."
}

# ===== 查看所有节点状态 =====
show_all_status() {
    list_nodes
    echo -e "${GREEN}=== 节点状态 ===${RESET}"
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        NODE_NAME=$(basename "$node")
        PORT=$(grep 'listen' "$node/snell-server.conf" | grep -oE '[0-9]{4,5}' | head -n1)
        TLS_PORT=$(grep 'LISTEN:' "$node/docker-compose.yml" | head -n1 | awk -F: '{print $NF}' | tr -d '"')
        STATUS=$(docker ps --filter "name=snell-$NODE_NAME" --format "{{.Status}}")
        [ -z "$STATUS" ] && STATUS="未启动"
        echo -e "${GREEN}$NODE_NAME${RESET} | ${YELLOW}Snell端口: ${PORT}${RESET} | ${YELLOW}ShadowTLS端口: ${TLS_PORT}${RESET} | ${YELLOW}状态: ${STATUS}${RESET}"
    done
    read -p "按回车返回菜单..."
}

# ===== 主菜单 =====
menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Snell + ShadowTLS 多节点管理 ===${RESET}"
        echo -e "${GREEN}1) 安装新节点${RESET}"
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
