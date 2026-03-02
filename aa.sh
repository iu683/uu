#!/bin/bash
# ========================================
# Shadowsocks Rust + ShadowTLS 多节点管理（Host Docker）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="ShadowsocksRust+shadow-tls"
APP_DIR="/opt/$APP_NAME"
METHOD="2022-blake3-aes-256-gcm"

# =========================
# Docker 检测
# =========================
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

# =========================
# 端口检测
# =========================
check_port() {
    if ss -tuln | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用！${RESET}"
        return 1
    fi
}

# =========================
# 列出节点
# =========================
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

# =========================
# 选择节点
# =========================
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

    while true; do
        read -r -p $'\033[32m请输入节点名称或编号:\033[0m ' input
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            if (( input >= 1 && input <= count )); then
                NODE_NAME="${nodes[$((input-1))]}"
                break
            else
                echo -e "${RED}编号无效！请重新输入${RESET}"
            fi
        else
            if [ -d "$APP_DIR/$input" ]; then
                NODE_NAME="$input"
                break
            else
                echo -e "${RED}节点不存在！请重新输入${RESET}"
            fi
        fi
    done

    NODE_DIR="$APP_DIR/$NODE_NAME"
}

# =========================
# 安装新节点
# =========================
install_node() {
    check_docker
    mkdir -p "$APP_DIR"

    read -p "请输入节点名称 [node$(date +%s)]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-node$(date +%s)}
    NODE_DIR="$APP_DIR/$NODE_NAME"
    mkdir -p "$NODE_DIR"

    # ShadowTLS 对外端口
    read -p "ShadowTLS 对外端口 [默认 8443]: " TLS_PORT
    TLS_PORT=${TLS_PORT:-8443}
    check_port "$TLS_PORT" || return

    read -p "伪装域名 SNI [默认 captive.apple.com]: " TLS_HOST
    TLS_HOST=${TLS_HOST:-captive.apple.com}

    read -p "Shadowsocks 内部监听端口 [默认 8388]: " SS_PORT
    SS_PORT=${SS_PORT:-8388}
    check_port "$SS_PORT" || return

    SS_PASSWORD=$(openssl rand -base64 32)
    TLS_PASSWORD=$(openssl rand -base64 16)

    CONFIG_FILE="$NODE_DIR/config.json"
    COMPOSE_FILE="$NODE_DIR/docker-compose.yml"

    # ================= SS 配置 =================
    cat > "$CONFIG_FILE" <<EOF
{
    "server": "127.0.0.1",
    "server_port": $SS_PORT,
    "password": "$SS_PASSWORD",
    "method": "$METHOD",
    "mode": "tcp_and_udp",
    "fast_open": true
}
EOF

    # ================= Docker Compose =================
    cat > "$COMPOSE_FILE" <<EOF
services:
  ss:
    image: ghcr.io/shadowsocks/ssserver-rust:latest
    container_name: $NODE_NAME-ss
    restart: unless-stopped
    network_mode: host
    command: ssserver -c /etc/shadowsocks/config.json
    volumes:
      - ./config.json:/etc/shadowsocks/config.json:ro

  shadow-tls:
    image: ghcr.io/ihciah/shadow-tls:latest
    container_name: $NODE_NAME-tls
    restart: unless-stopped
    network_mode: host
    environment:
      - MODE=server
      - V3=1
      - LISTEN=0.0.0.0:${TLS_PORT}
      - SERVER=127.0.0.1:${SS_PORT}
      - TLS=${TLS_HOST}:443
      - PASSWORD=${TLS_PASSWORD}
EOF

    cd "$NODE_DIR" || exit
    docker compose up -d

    IP4=$(hostname -I | awk '{print $1}')
    HOSTNAME=$(hostname -s | sed 's/ /_/g')
    echo -e "${GREEN}✅ 节点 $NODE_NAME 已部署${RESET}"
    echo "ShadowTLS 对外端口: $TLS_PORT"
    echo "Shadowsocks 内部端口: $SS_PORT"
    echo "SNI: $TLS_HOST"
    echo "SS密码: $SS_PASSWORD"
    echo "TLS密码: $TLS_PASSWORD"
    # 生成 ss 链接
    BASE=$(echo -n "${METHOD}:${SS_PASSWORD}@${IP4}:${TLS_PORT}" | base64 -w 0)

    PLUGIN="shadow-tls%3Bhost%3D${TLS_HOST}%3Bpassword%3D${TLS_PASSWORD}%3Bv3%3D1"

    SS_LINK="ss://${BASE}?plugin=${PLUGIN}"

    echo
    echo "ShadowTLS 专用链接："
    echo "----------------------------------"
    echo "$SS_LINK"
    echo "----------------------------------"
    echo "Surge配置:$HOSTNAME = ss, $IP4, $TLS_PORT, encrypt-method=$METHOD, password=$SS_PASSWORD, shadow-tls-password=$TLS_PASSWORD, shadow-tls-sni=$TLS_HOST, shadow-tls-version=3, tfo=true, udp-relay=true, ecn=true "
    read -p "按回车返回菜单..."
}

# =========================
# 单节点管理
# =========================
node_action_menu() {
    select_node || return
    while true; do
        echo -e "${GREEN}=== 节点 [$NODE_NAME] 管理 ===${RESET}"
        echo -e "${GREEN}1) 暂停${RESET}"
        echo -e "${GREEN}2) 重启${RESET}"
        echo -e "${GREEN}3) 更新${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 卸载${RESET}"
        echo -e "${GREEN}0) 返回${RESET}"
        read -r -p $'\033[32m请选择操作:\033[0m ' choice
        case $choice in
            1) docker pause "$NODE_NAME-ss" "$NODE_NAME-tls" ;;
            2) docker restart "$NODE_NAME-ss" "$NODE_NAME-tls" ;;
            3) cd "$NODE_DIR" && docker compose pull && docker compose up -d ;;
            4) docker logs -f "$NODE_NAME-ss" ;;
            5) cd "$NODE_DIR" && docker compose down && rm -rf "$NODE_DIR"; return ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" ;;
        esac
    done
}

# =========================
# 批量操作
# =========================
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
    [ $count -eq 0 ] && { echo -e "${YELLOW}无节点${RESET}"; read -p "按回车返回菜单..."; return; }
    read -r -p $'\033[32m输入序号(空格)或 all:\033[0m ' input
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
            1) docker stop "$NODE_NAME-ss" "$NODE_NAME-tls" ;;
            2) docker restart "$NODE_NAME-ss" "$NODE_NAME-tls" ;;
            3) docker compose pull && docker compose up -d ;;
            4) docker compose down && rm -rf "$NODE_DIR" ;;
        esac
        echo -e "${GREEN}已操作 $NODE_NAME${RESET}"
    done
    read -p "按回车返回菜单..."
}

# =========================
# 查看所有节点状态
# =========================
show_all_status() {
    echo -e "${GREEN}=== 所有节点状态 ===${RESET}"
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        NODE_NAME=$(basename "$node")
        TLS_PORT=$(grep 'LISTEN=' "$node/docker-compose.yml" | cut -d: -f2 | tr -d '"')
        STATUS=$(docker inspect -f '{{.State.Status}}' "$NODE_NAME-ss" 2>/dev/null)
        [ -z "$STATUS" ] && STATUS="未启动"
        echo -e "${GREEN}$NODE_NAME | ${TLS_PORT:-未知端口} | $STATUS${RESET}"
    done
    read -p "按回车返回菜单..."
}

# =========================
# 主菜单
# =========================
menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Shadowsocks Rust + ShadowTLS 多节点管理 ===${RESET}"
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
