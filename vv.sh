#!/bin/bash
# ========================================
# Snell + ShadowTLS 多节点管理脚本（Host 模式 + 彩色菜单 + 批量操作）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="snelltls"
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
    if ss -tlnp | grep -q ":$1 " || ss -ulnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

list_nodes() {
    mkdir -p "$APP_DIR"
    echo -e "${GREEN}=== 已有 Snell + ShadowTLS 节点 ===${RESET}"
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
    mkdir -p "$NODE_DIR/snell-conf"

    # ===== Snell 架构 =====
    echo -e "${GREEN}请选择 Snell 架构:${RESET}"
    echo -e "1) amd64 (默认)"
    echo -e "2) armv7l"
    echo -e "3) 自定义 URL"
    read -p "选择 [1/2/3, 默认 1]: " arch_choice
    case $arch_choice in
        2) SNELL_URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-armv7l.zip" ;;
        3) read -p "请输入自定义 SNELL_URL: " custom_url
           SNELL_URL="$custom_url" ;;
        *) SNELL_URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip" ;;
    esac

    # ===== Snell 内部端口 =====
    read -p "请输入 Snell 内部端口 [1025-65535, 默认随机]: " input_port
    PORT=${input_port:-$(shuf -i 1025-65535 -n1)}
    check_port "$PORT" || return

    # ===== ShadowTLS 对外端口 =====
    read -p "请输入 ShadowTLS 对外端口 [默认 8443]: " tls_input
    TLS_PORT=${tls_input:-8443}
    check_port "$TLS_PORT" || return

    # ===== PSK / ShadowTLS 密码 / TLS伪装 =====
    read -p "请输入 Snell PSK（留空随机生成 32 位）: " input_psk
    PSK=${input_psk:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c32)}
    TLS_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c16)
    read -p "请输入 TLS 伪装域名 [默认 captive.apple.com]: " tls_host
    TLS_HOST=${tls_host:-captive.apple.com}

    # ===== 可选配置 =====
    read -p "是否启用 IPv6 [true/false, 默认 false]: " ipv6
    IPv6=${ipv6:-false}
    read -p "混淆模式 [off/http, 默认 off]: " obfs
    OBFS=${obfs:-off}
    [[ "$OBFS" == "http" ]] && read -p "请输入混淆 Host [默认 example.com]: " obfs_host && OBFS_HOST=${obfs_host:-example.com} || OBFS_HOST=""
    read -p "是否启用 TCP Fast Open [true/false, 默认 true]: " tfo
    TFO=${tfo:-true}
    ECN=true

    # ===== Snell 配置文件 =====
    cat > "$NODE_DIR/snell-conf/snell.conf" <<EOF
[snell-server]
listen = $( [[ "$IPv6" == "true" ]] && echo "::0" || echo "0.0.0.0" ):$PORT
psk = $PSK
ipv6 = $IPv6
$( [[ "$OBFS" == "http" ]] && echo "obfs = http" && echo "obfs_host = $OBFS_HOST" )
EOF

    # ===== Docker Compose 文件 =====
    cat > "$NODE_DIR/docker-compose.yml" <<EOF
services:
  snell:
    image: accors/snell:latest
    container_name: snell-$NODE_NAME
    restart: always
    network_mode: host
    environment:
      - SNELL_URL=${SNELL_URL}
    volumes:
      - ./snell-conf/snell.conf:/etc/snell-server.conf

  shadow-tls:
    image: ghcr.io/ihciah/shadow-tls:latest
    container_name: shadow-tls-$NODE_NAME
    restart: unless-stopped
    network_mode: host
    environment:
      MODE: server
      V3: 1
      LISTEN: 0.0.0.0:${TLS_PORT}
      SERVER: 127.0.0.1:${PORT}
      TLS: ${TLS_HOST}:443
      PASSWORD: ${TLS_PASSWORD}
EOF

    cd "$NODE_DIR" || return
    docker compose up -d

    IP=$(hostname -I | awk '{print $1}')
    echo -e "${GREEN}✅ 节点 ${NODE_NAME} 已启动${RESET}"
    echo -e "${YELLOW}🌐 公网IP: ${IP}${RESET}"
    echo -e "${YELLOW}🌐 ShadowTLS端口: ${TLS_PORT}${RESET}"
    echo -e "${YELLOW}🔑 Snell PSK: ${PSK}${RESET}"
    echo -e "${YELLOW}🔑 ShadowTLS 密码: ${TLS_PASSWORD}${RESET}"
    echo -e "${GREEN}📂 安装目录: $NODE_DIR${RESET}"
    echo -e "${GREEN}====== 客户端配置示例 ======${RESET}"
    echo -e "${YELLOW}ShadowTLS:${RESET}"
    echo -e "${YELLOW}地址: ${IP}${RESET}"
    echo -e "${YELLOW}端口: ${TLS_PORT}${RESET}"
    echo -e "${YELLOW}密码: ${TLS_PASSWORD}${RESET}"
    echo -e "${YELLOW}SNI: ${TLS_HOST}${RESET}"
    echo -e "${YELLOW}Snell:${RESET}${RESET}"
    echo -e "${YELLOW}${NODE_NAME} = snell, ${IP}, ${TLS_PORT}, psk=${PSK}, version=5, tfo=${TFO}, ecn=${ECN}, shadow-tls-password=${TLS_PASSWORD}, shadow-tls-sni=${TLS_HOST}, shadow-tls-version=3${RESET}"
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

batch_action() {
    echo -e "${GREEN}=== 批量操作节点 ===${RESET}"
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
    [ $count -eq 0 ] && { echo -e "${YELLOW}无节点${RESET}"; read -r -p $'\033[32m按回车返回菜单...\033[0m'; return; }

    read -r -p $'\033[32m请输入要操作的节点序号（空格分隔，或输入 all 全选）: \033[0m' input_nodes
    if [[ "$input_nodes" == "all" ]]; then
        SELECTED_NODES=("${NODE_MAP[@]}")
    else
        SELECTED_NODES=()
        for i in $input_nodes; do
            NODE=${NODE_MAP[$i]}
            [ -n "$NODE" ] && SELECTED_NODES+=("$NODE") || echo -e "${YELLOW}⚠ 序号 $i 无效，已跳过${RESET}"
        done
    fi

    for NODE_NAME in "${SELECTED_NODES[@]}"; do
        NODE_DIR="$APP_DIR/$NODE_NAME"
        [ ! -d "$NODE_DIR" ] || [ ! -f "$NODE_DIR/docker-compose.yml" ] && { echo -e "${YELLOW}⚠ 跳过节点 $NODE_NAME：目录或 docker-compose.yml 不存在${RESET}"; continue; }
        cd "$NODE_DIR" || continue
        case $choice in
            1) docker pause snell-$NODE_NAME shadow-tls-$NODE_NAME ;;
            2) docker restart snell-$NODE_NAME shadow-tls-$NODE_NAME ;;
            3) docker compose pull && docker compose up -d ;;
            4) docker compose down && rm -rf "$NODE_DIR" ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" ; return ;;
        esac
        echo -e "${GREEN}✅ 节点 $NODE_NAME 操作完成${RESET}"
    done

    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

show_all_status() {
    list_nodes
    echo -e "${GREEN}=== 节点状态 ===${RESET}"
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        NODE_NAME=$(basename "$node")
        PORT=$(grep 'listen' "$node/snell-conf/snell.conf" | awk -F: '{print $2}' | tr -d ' ')
        TLS_PORT=$(grep 'LISTEN:' "$node/docker-compose.yml" | head -n1 | sed -E 's/.*:([0-9]+).*/\1/')
        STATUS=$(docker ps --filter "name=snell-$NODE_NAME" --format "{{.Status}}")
        [ -z "$STATUS" ] && STATUS="未启动"
        echo -e "${GREEN}$NODE_NAME${RESET} | ${YELLOW}Snell端口: ${PORT}${RESET} | ${YELLOW}ShadowTLS端口: ${TLS_PORT}${RESET} | ${YELLOW}状态: ${STATUS}${RESET}"
    done
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Snell + ShadowTLS 多节点管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装新节点${RESET}"
        echo -e "${GREEN}2) 管理已有节点${RESET}"
        echo -e "${GREEN}3) 批量操作节点${RESET}"
        echo -e "${GREEN}4) 查看所有节点状态${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -r -p $'\033[32m请选择操作: \033[0m' choice
        case $choice in
            1) install_node ;;
            2) node_action_menu ;;
            3) batch_action ;;
            4) show_all_status ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
        esac
    done
}

menu
