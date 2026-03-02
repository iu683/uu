#!/bin/bash
# ========================================
# Snell + ShadowTLS 多节点管理（Host Docker）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="Snell+ShadowTLS"
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

    # Snell 内部端口
    read -p "Snell 内部端口 [20000-40000, 默认随机]: " SNELL_PORT
    SNELL_PORT=${SNELL_PORT:-$(shuf -i20000-40000 -n1)}
    check_port "$SNELL_PORT" || return

    # ShadowTLS 外部端口
    read -p "ShadowTLS 对外端口 [默认 443]: " TLS_PORT
    TLS_PORT=${TLS_PORT:-443}
    check_port "$TLS_PORT" || return

    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c32)
    TLS_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c16)

    read -p "TLS 伪装域名 [默认 captive.apple.com]: " TLS_HOST
    TLS_HOST=${TLS_HOST:-captive.apple.com}

    COMPOSE_FILE="$NODE_DIR/docker-compose.yml"

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:

  snell:
    image: 1byte/snell-server:latest
    container_name: ${NODE_NAME}-snell
    restart: always
    network_mode: host
    environment:
      PORT: "${SNELL_PORT}"
      PSK: "${PSK}"
      IPv6: "false"
      OBFS: "off"
      TFO: "true"
      ECN: "true"

  shadow-tls:
    image: ghcr.io/ihciah/shadow-tls:latest
    container_name: ${NODE_NAME}-tls
    restart: unless-stopped
    network_mode: host
    environment:
      MODE: server
      V3: 1
      LISTEN: 0.0.0.0:${TLS_PORT}
      SERVER: 127.0.0.1:${SNELL_PORT}
      TLS: ${TLS_HOST}:443
      PASSWORD: ${TLS_PASSWORD}
EOF

    cd "$NODE_DIR" || exit
    docker compose up -d

    IP=$(hostname -I | awk '{print $1}')
    HOSTNAME=$(hostname -s | sed 's/ /_/g')
    echo -e "${GREEN}✅ 节点 $NODE_NAME 已部署${RESET}"
    echo "公网IP: $IP"
    echo "Snell内部端口: $SNELL_PORT"
    echo "ShadowTLS外部端口: $TLS_PORT"
    echo "Snell PSK: $PSK"
    echo "ShadowTLS密码: $TLS_PASSWORD"
    echo "SNI: $TLS_HOST"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    echo -e "${YELLOW}Snell:${RESET}"
    echo -e "${YELLOW}$HOSTNAME = snell, ${IP}, ${TLS_PORT}, psk = ${PSK}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${TLS_PASSWORD}, shadow-tls-sni = ${TLS_HOST}, shadow-tls-version = 3${RESET}"
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
            1) docker pause "$NODE_NAME-snell" "$NODE_NAME-tls"  ;;
            2) docker restart "$NODE_NAME-snell" "$NODE_NAME-tls" ;;
            3) cd "$NODE_DIR" && docker compose pull && docker compose up -d ;;
            4) docker logs -f "$NODE_NAME-snell" ;;
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
            1) docker stop "$NODE_NAME-snell" "$NODE_NAME-tls" ;;
            2) docker restart "$NODE_NAME-snell" "$NODE_NAME-tls" ;;
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

        # 解析 ShadowTLS 对外端口
        TLS_PORT=$(grep 'LISTEN' "$node/docker-compose.yml" | head -n1 | awk -F: '{print $NF}' | tr -d ' ')
        [ -z "$TLS_PORT" ] && TLS_PORT="未知端口"

        # 获取 Snell 容器状态
        SNELL_STATUS=$(docker inspect -f '{{.State.Status}}' "$NODE_NAME-snell" 2>/dev/null)
        [ -z "$SNELL_STATUS" ] && SNELL_STATUS="未启动"

        # 获取 ShadowTLS 容器状态
        TLS_STATUS=$(docker inspect -f '{{.State.Status}}' "$NODE_NAME-tls" 2>/dev/null)
        [ -z "$TLS_STATUS" ] && TLS_STATUS="未启动"

        echo -e "${GREEN}$NODE_NAME | Snell: $SNELL_STATUS | TLS: $TLS_STATUS | Port: $TLS_PORT${RESET}"
    done
    read -p "按回车返回菜单..."
}

# =========================
# 主菜单
# =========================
menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Snell + ShadowTLS 多节点管理 ===${RESET}"
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
