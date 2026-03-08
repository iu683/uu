#!/bin/bash
# ========================================
# Sinbox-tuicv5 多节点管理脚本（完整版）
# Host模式 + 单节点管理 + 批量操作 + 全绿菜单
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="Singbox-tuicv5"
APP_DIR="/root/$APP_NAME"

# =========================
# Docker 检测
# =========================
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${GREEN}未检测到 Docker，正在安装...${RESET}"
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
    if ss -tuln | awk '{print $5}' | grep -qE "[:.]$1$"; then
        echo -e "${RED}端口 $1 已被占用！${RESET}"
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

add_jump_rules() {

    if [[ -z "$JUMP_START" || -z "$JUMP_END" ]]; then
        return
    fi

    SERVER_IP=$(hostname -I | awk '{print $1}')

    echo -e "${YELLOW}添加端口跳跃规则: $JUMP_START-$JUMP_END -> $PORT${RESET}"
    echo -e "${GREEN}服务器IP: $SERVER_IP${RESET}"

    # 防止重复
    while iptables -t nat -C PREROUTING -p udp \
        --dport $JUMP_START:$JUMP_END \
        -j DNAT --to-destination ${SERVER_IP}:$PORT 2>/dev/null
    do
        iptables -t nat -D PREROUTING -p udp \
            --dport $JUMP_START:$JUMP_END \
            -j DNAT --to-destination ${SERVER_IP}:$PORT
    done

    # 插入最前面
    iptables -t nat -I PREROUTING 1 -p udp \
        --dport $JUMP_START:$JUMP_END \
        -j DNAT --to-destination ${SERVER_IP}:$PORT

    echo -e "${GREEN}端口跳跃规则添加完成${RESET}"
}

remove_jump_rules() {

    if [[ -z "$JUMP_START" || -z "$JUMP_END" ]]; then
        return
    fi

    SERVER_IP=$(hostname -I | awk '{print $1}')

    while iptables -t nat -C PREROUTING -p udp \
        --dport $JUMP_START:$JUMP_END \
        -j DNAT --to-destination ${SERVER_IP}:$PORT 2>/dev/null
    do
        iptables -t nat -D PREROUTING -p udp \
            --dport $JUMP_START:$JUMP_END \
            -j DNAT --to-destination ${SERVER_IP}:$PORT
    done

    echo -e "${GREEN}端口跳跃规则已清理${RESET}"
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

    # 收集节点
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        nodes+=("$(basename "$node")")
        count=$((count+1))
        echo -e "${GREEN}[$count] ${nodes[-1]}${RESET}"
    done

    [ $count -eq 0 ] && { echo -e "${RED}无节点！${RESET}"; return 1; }

    # 输入节点编号或名称
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
# =========================
# 安装节点
# =========================
install_node() {
    check_docker
    read -p "请输入节点名称 [默认node$(date +%s)]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-node$(date +%s)}
    NODE_DIR="$APP_DIR/$NODE_NAME"
    mkdir -p "$NODE_DIR"

    read -p "请输入端口 [默认随机]: " input_port
    PORT=${input_port:-$(shuf -i 1025-65535 -n1)}
    check_port "$PORT" || return

    read -p "是否启用端口跳跃 [Y/n,回车默认Y]: " enable_jump
    enable_jump=$(echo "$enable_jump" | tr -d ' ')
    enable_jump=${enable_jump:-Y}

    if [[ "$enable_jump" =~ ^[Nn]$ ]]; then
        echo "已关闭端口跳跃"
        JUMP_START=""
        JUMP_END=""
    else
        read -p "起始端口: " JUMP_START
        read -p "结束端口: " JUMP_END
    fi

    add_jump_rules
    echo "PORT=$PORT" > "$NODE_DIR/jump.conf"
    echo "JUMP_START=$JUMP_START" >> "$NODE_DIR/jump.conf"
    echo "JUMP_END=$JUMP_END" >> "$NODE_DIR/jump.conf"

    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c8)

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
      "type": "tuic",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "password": "${PASSWORD}"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "server_name": "www.bing.com",
        "certificate_path": "/etc/tuic/server.crt",
        "key_path": "/etc/tuic/server.key"
      }
    }
  ],
  "outbounds": [
    { "type": "direct" }
  ]
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
      - ./config.json:/etc/tuic/config.json
      - ./server.crt:/etc/tuic/server.crt
      - ./server.key:/etc/tuic/server.key
    command: run -c /etc/tuic/config.json
EOF

    cd "$NODE_DIR" || return
    docker compose up -d

    SERVER_IP=$(get_public_ip)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    echo
    echo -e "${GREEN}📂 安装目录: $NODE_DIR${RESET}"
    echo -e "${GREEN}✅ Singbox-TUICv5 节点已启动${RESET}"
    echo -e "${YELLOW}🌐 IP: ${SERVER_IP}${RESET}"
    echo -e "${YELLOW}🔌 端口: ${PORT}${RESET}"
    echo -e "${YELLOW}🆔 UUID: ${UUID}${RESET}"
    echo -e "${YELLOW}🔑 密码: ${PASSWORD}${RESET}"
    if [[ -n "$JUMP_START" ]]; then
        echo -e "${YELLOW}🟢 端口跳跃: $JUMP_START-$JUMP_END -> $PORT${RESET}"
    else
        echo -e "${YELLOW}🟢 端口跳跃: 未启用${RESET}"
    fi
    echo
    echo -e "${YELLOW}📄 V6VPS替换IP地址为V6 ★${RESET}"
    echo -e "${YELLOW}📄 端口跳跃只适配V4 ★${RESET}"
    echo -e "${YELLOW}📄 客户端链接:${RESET}"
    echo -e "${YELLOW}tuic://${UUID}:${PASSWORD}@${SERVER_IP}:${PORT}?congestion_control=bbr&alpn=h3&sni=www.bing.com&udp_relay_mode=native&allow_insecure=1#${NODE_NAME}${RESET}"
    echo
    cat > "$NODE_DIR/node.txt" <<EOF
跳跃端口: ${JUMP_START:-未启用}-${JUMP_END:-未启用}
tuic://${UUID}:${PASSWORD}@${SERVER_IP}:${PORT}?congestion_control=bbr&alpn=h3&sni=www.bing.com&udp_relay_mode=native&allow_insecure=1#$NODE_NAME
EOF
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

# =========================
# 单节点管理菜单
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
        echo -e "${GREEN}6) 查看节点信息${RESET}"
        echo -e "${GREEN}0) 返回${RESET}"

        # ✅ 输入存到 choice
        read -r -p $'\033[32m请选择操作:\033[0m ' choice

        case $choice in
            1) docker pause "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose -f "$NODE_DIR/docker-compose.yml" pull && docker compose -f "$NODE_DIR/docker-compose.yml" up -d ;;
            4) docker logs -f "$NODE_NAME" ;;
            5)
               source "$NODE_DIR/jump.conf" 2>/dev/null
               remove_jump_rules
               docker compose -f "$NODE_DIR/docker-compose.yml" down
               rm -rf "$NODE_DIR"
               return
               ;;
            6) cat "$NODE_DIR/node.txt" ;;
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

    # ✅ 先读 choice
    read -r -p $'\033[32m请选择操作:\033[0m ' choice

    # 立即处理 0 返回
    if [[ "$choice" == "0" ]]; then
        return
    fi

    # 构建节点数组
    declare -A NODE_MAP
    local count=0
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        count=$((count+1))
        NODE_MAP[$count]=$(basename "$node")
        echo -e "${GREEN}[$count] ${NODE_MAP[$count]}${RESET}"
    done

    [ $count -eq 0 ] && { echo -e "${GREEN}无节点${RESET}"; read -r -p $'\033[32m按回车返回菜单...\033[0m'; return; }

    read -r -p $'\033[32m 请输入节点序号（空格分隔，或 all 全选）:\033[0m ' input

    # 处理输入
    if [[ "$input" == "all" ]]; then
        SELECTED=("${NODE_MAP[@]}")
    else
        SELECTED=()
        for i in $input; do
            [ -n "${NODE_MAP[$i]}" ] && SELECTED+=("${NODE_MAP[$i]}")
        done
    fi

    # 批量执行操作
    for NODE_NAME in "${SELECTED[@]}"; do
        NODE_DIR="$APP_DIR/$NODE_NAME"
        cd "$NODE_DIR" || continue

        case $choice in
            1) docker pause "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose pull && docker compose up -d ;;
            4)
               source "$NODE_DIR/jump.conf" 2>/dev/null
               remove_jump_rules
               docker compose down
               rm -rf "$NODE_DIR"
               ;;
        esac

        echo -e "${GREEN}已操作 $NODE_NAME${RESET}"
    done

    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}
# =========================
# 状态查看
# =========================
show_all_status() {
    echo -e "${GREEN}=== 所有节点状态 ===${RESET}"
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        NODE_NAME=$(basename "$node")
        
        # 从 docker-compose.yml 读取端口
        PORT=$(grep 'listen_port' "$node/config.json" | awk -F: '{gsub(/[ ,"]/,"",$2); print $2}')
        
        # 获取 Docker 状态
        STATUS=$(docker inspect -f '{{.State.Status}}' "$NODE_NAME" 2>/dev/null)
        [ -z "$STATUS" ] && STATUS="未启动"

        echo -e "${GREEN}$NODE_NAME | ${PORT:-未知端口} | $STATUS${RESET}"
    done
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

# =========================
# 主菜单
# =========================
menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Singbox-tuicv5 多节点管理 ===${RESET}"
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
