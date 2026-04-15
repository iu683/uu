#!/bin/bash
# ========================================
# Sing-box AnyReality 多节点管理
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="Singbox-AnyReality"
APP_DIR="/root/$APP_NAME"

# ===== 基础函数 =====
info(){ echo -e "${GREEN}$1${RESET}"; }
warn(){ echo -e "${YELLOW}$1${RESET}"; }
error(){ echo -e "${RED}$1${RESET}"; }

rand_str(){ tr -dc a-z0-9 </dev/urandom | head -c ${1:-8}; }

check_docker(){
    if ! command -v docker &>/dev/null; then
        warn "未检测到 Docker，正在安装..."
        curl -fsSL https://get.docker.com | bash
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
    return
}

# ===== 端口检测 =====
check_port_loop(){
    local port=$1
    while ss -tuln | grep -q ":$port "; do
        error "端口 $port 已占用"
        read -p "重新输入端口: " port
    done
    echo "$port"
}

# ===== 列出节点 =====
list_nodes(){
    mkdir -p "$APP_DIR"
    shopt -s nullglob
    local i=1
    echo -e "${GREEN}=== 已有节点 ===${RESET}"
    for node in "$APP_DIR"/*; do
        echo -e "${YELLOW}[$i] $(basename "$node")${RESET}"
        i=$((i+1))
    done
    [ $i -eq 1 ] && warn "无节点"
}

# ===== 选择节点 =====
select_node(){
    mkdir -p "$APP_DIR"

    mapfile -t NODE_LIST < <(find "$APP_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

    if [ ${#NODE_LIST[@]} -eq 0 ]; then
        error "无节点"
        return 1
    fi

    echo -e "${GREEN}=== 已有节点 ===${RESET}"
    for i in "${!NODE_LIST[@]}"; do
        echo -e "${YELLOW}[$((i+1))] $(basename "${NODE_LIST[$i]}")${RESET}"
    done

    read -p "输入节点名称或编号: " input

    if [[ "$input" =~ ^[0-9]+$ ]]; then
        NODE_NAME=$(basename "${NODE_LIST[$((input-1))]}")
    else
        NODE_NAME="$input"
    fi

    NODE_DIR="$APP_DIR/$NODE_NAME"

    if [ ! -d "$NODE_DIR" ]; then
        error "节点不存在"
        return 1
    fi
}

# ===== 安装节点 =====
install_node(){
    check_docker

    read -p "节点名称 [默认node$(date +%s)]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-node$(date +%s)}
    NODE_DIR="$APP_DIR/$NODE_NAME"
    mkdir -p "$NODE_DIR"

    read -p "端口(默认随机): " input_port
    input_port=${input_port:-$(shuf -i 20000-60000 -n1)}
    PORT=$(check_port_loop "$input_port")

    USERNAME=$(rand_str 8)
    PASSWORD=$(rand_str 16)

    read -p "伪装域名(默认 www.amazon.com): " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-www.amazon.com}

    SERVER_IP=$(get_public_ip)

    info "生成 Reality 密钥..."
    KEY_PAIR=$(docker run --rm ghcr.io/sagernet/sing-box generate reality-keypair)

    PRIVATE_KEY=$(echo "$KEY_PAIR" | grep PrivateKey | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | grep PublicKey | awk '{print $2}')
    SHORT_ID=$(openssl rand -hex 4)

    # ===== 配置 =====
    cat > "$NODE_DIR/config.json" <<EOF
{
  "log": {"level": "info"},
  "inbounds": [{
    "type": "anytls",
    "listen": "::",
    "listen_port": ${PORT},
    "users": [{
      "name": "${USERNAME}",
      "password": "${PASSWORD}"
    }],
    "tls": {
      "enabled": true,
      "server_name": "${SERVER_NAME}",
      "reality": {
        "enabled": true,
        "handshake": {
          "server": "${SERVER_NAME}",
          "server_port": 443
        },
        "private_key": "${PRIVATE_KEY}",
        "short_id": "${SHORT_ID}"
      }
    }
  }],
  "outbounds": [{"type": "direct"}]
}
EOF

    # ===== docker =====
    cat > "$NODE_DIR/docker-compose.yml" <<EOF
services:
  singbox:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: singbox-${NODE_NAME}
    network_mode: host
    restart: always
    volumes:
      - ./config.json:/etc/sing-box/config.json
    command: run -c /etc/sing-box/config.json
EOF

    docker compose -f "$NODE_DIR/docker-compose.yml" up -d

    # ===== 保存节点信息 =====
    cat > "$NODE_DIR/node.txt" <<EOF
服务器 IP: ${SERVER_IP}
端口: ${PORT}
用户名: ${USERNAME}
密码: ${PASSWORD}
SNI: ${SERVER_NAME}
PublicKey: ${PUBLIC_KEY}
ShortID: ${SHORT_ID}
备注: ${NODE_NAME}
EOF

    info "节点创建完成"
    show_node_info "$NODE_NAME"
}

# ===== 查看节点信息=====
show_node_info(){
    if [ -n "$1" ]; then
        NODE_NAME="$1"
        NODE_DIR="$APP_DIR/$NODE_NAME"
        [ ! -d "$NODE_DIR" ] && error "节点不存在" && return
    else
        select_node || return
    fi

    clear
    info "当前节点 [$NODE_NAME]"

    cat "$NODE_DIR/node.txt"
    echo

    SERVER_IP=$(grep "服务器 IP" $NODE_DIR/node.txt | awk '{print $3}')
    PORT=$(grep "端口" $NODE_DIR/node.txt | awk '{print $2}')
    PASSWORD=$(grep "密码" $NODE_DIR/node.txt | awk '{print $2}')
    SERVER_NAME=$(grep "SNI" $NODE_DIR/node.txt | awk '{print $2}')
    PUBLIC_KEY=$(grep "PublicKey" $NODE_DIR/node.txt | awk '{print $2}')
    SHORT_ID=$(grep "ShortID" $NODE_DIR/node.txt | awk '{print $2}')

    echo -e "${GREEN}QuantumultX:${RESET}"
    echo "anytls=${SERVER_IP}:${PORT}, password=${PASSWORD}, over-tls=true, tls-host=${SERVER_NAME}, tls-verification=false, reality-base64-pubkey=${PUBLIC_KEY}, reality-hex-shortid=${SHORT_ID}, udp-relay=true, tag=${NODE_NAME}"
    echo

    echo -e "${GREEN}sing-box 客户端:${RESET}"
    cat <<EOF
{
  "type": "anytls",
  "tag": "${NODE_NAME}",
  "server": "${SERVER_IP}",
  "server_port": ${PORT},
  "password": "${PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${SERVER_NAME}",
    "reality": {
      "enabled": true,
      "public_key": "${PUBLIC_KEY}",
      "short_id": "${SHORT_ID}"
    }
  }
}
EOF

    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

# ===== 节点管理 =====
node_action_menu(){
    select_node || return

    while true; do
        echo -e "${GREEN}=== 节点 [$NODE_NAME] 管理 ===${RESET}"
        echo -e "${GREEN}1) 停止${RESET}"
        echo -e "${GREEN}2) 启动${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 更新${RESET}"
        echo -e "${GREEN}5) 查看日志${RESET}"
        echo -e "${GREEN}6) 查看节点信息${RESET}"
        echo -e "${GREEN}7) 卸载${RESET}"
        echo -e "${GREEN}0) 返回主菜单${RESET}"

        read -r -p $'\033[32m请选择操作: \033[0m' choice

        case $choice in
            1) docker stop singbox-$NODE_NAME ;;
            2) docker start singbox-$NODE_NAME ;;
            3) docker restart singbox-$NODE_NAME ;;
            4)
                docker compose -f "$NODE_DIR/docker-compose.yml" pull
                docker compose -f "$NODE_DIR/docker-compose.yml" up -d
                ;;
            5) docker logs -f singbox-$NODE_NAME ;;
            6) show_node_info "$NODE_NAME" ;;
            7)
               docker rm -f singbox-$NODE_NAME && rm -rf "$NODE_DIR" && return
               ;;
            0) return ;;
        esac
    done
}

# ===== 批量操作节点 =====
batch_action(){
    echo -e "${GREEN}=== 批量操作节点 ===${RESET}"
    echo -e "${GREEN}1) 停止节点${RESET}"
    echo -e "${GREEN}2) 启动节点${RESET}"
    echo -e "${GREEN}3) 重启节点${RESET}"
    echo -e "${GREEN}4) 更新节点${RESET}"
    echo -e "${GREEN}5) 卸载节点${RESET}"
    echo -e "${GREEN}0) 返回主菜单${RESET}"

    read -r -p $'\033[32m请选择操作: \033[0m' choice
    [[ "$choice" == "0" ]] && return

    mkdir -p "$APP_DIR"
    declare -A NODE_MAP
    local count=0

    echo -e "${GREEN}=== 节点列表 ===${RESET}"
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        count=$((count+1))
        NODE_NAME=$(basename "$node")
        NODE_MAP[$count]="$NODE_NAME"

        STATUS=$(docker ps --filter "name=singbox-$NODE_NAME" --format "{{.Status}}")
        [ -z "$STATUS" ] && STATUS="未运行"

        echo -e "${YELLOW}[$count] $NODE_NAME${RESET} | ${GREEN}$STATUS${RESET}"
    done

    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}无节点${RESET}"
        read -r -p $'\033[32m按回车返回菜单...\033[0m'
        return
    fi

    # ===== 选择节点 =====
    read -r -p $'\033[32m请输入节点序号（空格分隔，或 all 全选）: \033[0m' input

    if [[ "$input" == "all" ]]; then
        SELECTED_NODES=("${NODE_MAP[@]}")
    else
        SELECTED_NODES=()
        for i in $input; do
            NODE=${NODE_MAP[$i]}
            [ -n "$NODE" ] && SELECTED_NODES+=("$NODE")
        done
    fi

    # ===== 执行操作 =====
    for NODE_NAME in "${SELECTED_NODES[@]}"; do
        NODE_DIR="$APP_DIR/$NODE_NAME"

        case "$choice" in
            1)
                docker stop singbox-$NODE_NAME 2>/dev/null
                ;;
            2)
                docker start singbox-$NODE_NAME 2>/dev/null
                ;;
            3)
                docker restart singbox-$NODE_NAME 2>/dev/null
                ;;
            4)
                docker compose -f "$NODE_DIR/docker-compose.yml" pull
                docker compose -f "$NODE_DIR/docker-compose.yml" up -d
                ;;
            5)
                docker rm -f singbox-$NODE_NAME 2>/dev/null
                rm -rf "$NODE_DIR"
                ;;
        esac

        echo -e "${GREEN}✅ $NODE_NAME 操作完成${RESET}"
    done

    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

# ===== 状态 =====
show_all_status(){
    list_nodes
    echo -e "${GREEN}=== 状态 ===${RESET}"
    for node in "$APP_DIR"/*; do
        NODE_NAME=$(basename "$node")
        STATUS=$(docker ps --filter name=singbox-$NODE_NAME --format "{{.Status}}")
        [ -z "$STATUS" ] && STATUS="未运行"
        echo "$NODE_NAME | $STATUS"
    done
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

# ===== 主菜单 =====
menu(){
    while true; do
        clear
        echo -e "${GREEN}=== Sing-box AnyReality 多节点管理 ===${RESET}"
        echo -e "${GREEN}1) 安装节点${RESET}"
        echo -e "${GREEN}2) 管理节点${RESET}"
        echo -e "${GREEN}3) 查看所有节点状态${RESET}"
        echo -e "${GREEN}4) 批量操作节点${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -r -p $'\033[32m请选择操作: \033[0m' choice

        case $choice in
            1) install_node ;;
            2) node_action_menu ;;
            3) show_all_status ;;
            4) batch_action ;;
            0) exit ;;
            *) warn "无效选择" ;;
        esac
    done
}

menu
