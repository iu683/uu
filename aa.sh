#!/bin/bash
# ========================================
# Hysteria 多节点管理脚本
# Host Docker + 自签证书 + 端口跳跃 + 必应伪装
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="hysteria"
APP_DIR="/opt/$APP_NAME"
MASQ_URL="https://bing.com"

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
    if ss -tuln | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用！${RESET}"
        return 1
    fi
}

generate_cert() {
    mkdir -p "$NODE_DIR/cert"
    if [ ! -f "$NODE_DIR/cert/server.crt" ]; then
        echo -e "${YELLOW}生成自签证书 CN=bing.com...${RESET}"
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "$NODE_DIR/cert/server.key" \
            -out "$NODE_DIR/cert/server.crt" \
            -subj "/CN=bing.com" \
            -days 36500 >/dev/null 2>&1
    fi
}

add_jump_rules() {
    if [[ -n "$JUMP_START" && -n "$JUMP_END" ]]; then
        iptables -t nat -A PREROUTING -p udp \
            --dport $JUMP_START:$JUMP_END \
            -j REDIRECT --to-ports $PORT

        ip6tables -t nat -A PREROUTING -p udp \
            --dport $JUMP_START:$JUMP_END \
            -j REDIRECT --to-ports $PORT

        echo -e "${GREEN}端口跳跃规则添加完成${RESET}"
    fi
}

remove_jump_rules() {
    if [[ -n "$JUMP_START" && -n "$JUMP_END" ]]; then
        iptables -t nat -D PREROUTING -p udp \
            --dport $JUMP_START:$JUMP_END \
            -j REDIRECT --to-ports $PORT 2>/dev/null

        ip6tables -t nat -D PREROUTING -p udp \
            --dport $JUMP_START:$JUMP_END \
            -j REDIRECT --to-ports $PORT 2>/dev/null
    fi
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

    # 收集节点
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        nodes+=("$(basename "$node")")
        count=$((count+1))
        echo -e "${GREEN}[$count] ${nodes[-1]}${RESET}"
    done

    [ $count -eq 0 ] && { echo -e "${RED}无节点！${RESET}"; return 1; }

    while true; do
        read -r -p $'\033[32m请输入节点名称或编号:\033[0m ' input

        # 输入编号
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            if (( input >= 1 && input <= count )); then
                NODE_NAME="${nodes[$((input-1))]}"
                break
            else
                echo -e "${RED}编号无效！请重新输入${RESET}"
            fi
        else
            # 输入名称
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

install_node() {
    check_docker

    read -p "请输入节点名称 [node$(date +%s)]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-node$(date +%s)}
    NODE_DIR="$APP_DIR/$NODE_NAME"
    mkdir -p "$NODE_DIR"

    read -p "监听端口 [默认随机]: " input_port
    PORT=${input_port:-$(shuf -i 1025-65535 -n1)}
    check_port "$PORT" || return

    PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c16)

    read -p "是否启用端口跳跃 [y/N]: " enable_jump
    if [[ "$enable_jump" =~ ^[Yy]$ ]]; then
        read -p "起始端口: " JUMP_START
        read -p "结束端口: " JUMP_END
    fi

    generate_cert
    add_jump_rules

    cat > "$NODE_DIR/hysteria.yaml" <<EOF
listen: :$PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: $MASQ_URL
    rewriteHost: true
EOF

    cat > "$NODE_DIR/docker-compose.yml" <<EOF
services:
  ${NODE_NAME}:
    image: tobyxdd/hysteria
    container_name: ${NODE_NAME}
    restart: always
    network_mode: host
    volumes:
      - ./hysteria.yaml:/etc/hysteria.yaml
      - ./cert/server.crt:/etc/hysteria/server.crt
      - ./cert/server.key:/etc/hysteria/server.key
    command: ["server", "-c", "/etc/hysteria.yaml"]
EOF

    cd "$NODE_DIR" || return
    docker compose up -d

    IP=$(hostname -I | awk '{print $1}')
    HOSTNAME=$(hostname -s | sed 's/ /_/g')
    echo -e "${GREEN}节点已启动${RESET}"
    echo -e "${YELLOW}V2rayN: hysteria2://$PASSWORD@$IP:$PORT/?sni=bing.com&insecure=1#$HOSTNAME${RESET}"
    echo -e "${YELLOW}Surge:  $HOSTNAME = hysteria2, $IP, $PORT, password=$PASSWORD, skip-cert-verify=true, sni=www.bing.com${RESET}"
    read -p "回车返回菜单..."
}

node_action_menu() {
    while ! select_node; do
        echo -e "${YELLOW}请重新选择有效节点${RESET}"
    done

    while true; do
        echo -e "${GREEN}=== 节点 [$NODE_NAME] 管理 ===${RESET}"
        echo -e "${GREEN}1) 重启${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 查看日志${RESET}"
        echo -e "${GREEN}4) 卸载${RESET}"
        echo -e "${GREEN}0) 返回${RESET}"

        read -r -p $'\033[32m请选择操作:\033[0m ' choice
        case $choice in
            1) docker restart "$NODE_NAME" ;;
            2) docker compose -f "$NODE_DIR/docker-compose.yml" pull && docker compose -f "$NODE_DIR/docker-compose.yml" up -d ;;
            3) docker logs -f "$NODE_NAME" ;;
            4) docker compose -f "$NODE_DIR/docker-compose.yml" down && rm -rf "$NODE_DIR"; return ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" ;;
        esac
    done
}

show_all_status() {
    echo -e "${GREEN}=== 所有节点状态 ===${RESET}"
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        NODE_NAME=$(basename "$node")

        # 提取 listen 端口
        PORT=$(grep '^listen:' "$node/hysteria.yaml" | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')

        STATUS=$(docker inspect -f '{{.State.Status}}' "$NODE_NAME" 2>/dev/null)
        [ -z "$STATUS" ] && STATUS="未启动"

        echo -e "${GREEN}$NODE_NAME | ${PORT:-未知端口} | $STATUS${RESET}"
    done
    read -p "按回车返回菜单..."
}

batch_action() {
    echo -e "${GREEN}=== Hysteria 批量操作 ===${RESET}"
    echo -e "${GREEN}1) 批量停止${RESET}"
    echo -e "${GREEN}2) 批量重启${RESET}"
    echo -e "${GREEN}3) 批量更新${RESET}"
    echo -e "${GREEN}4) 批量卸载${RESET}"
    echo -e "${GREEN}0) 返回${RESET}"

    read -r -p $'\033[32m请选择操作:\033[0m ' choice
    [[ "$choice" == "0" ]] && return

    # 构建节点数组
    declare -A NODE_MAP
    local count=0
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        count=$((count+1))
        NODE_MAP[$count]=$(basename "$node")
        echo -e "${GREEN}[$count] ${NODE_MAP[$count]}${RESET}"
    done

    [ $count -eq 0 ] && { echo -e "${YELLOW}无节点${RESET}"; read -p "回车返回..."; return; }

    read -r -p $'\033[32m输入序号(空格分隔)或 all:\033[0m ' input

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
            1) docker stop "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose pull && docker compose up -d ;;
            4) docker compose down && rm -rf "$NODE_DIR" ;;
        esac
        echo -e "${GREEN}已操作 $NODE_NAME${RESET}"
    done

    read -p "回车返回..."
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Hysteria 多节点管理 ===${RESET}"
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
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
        esac
    done
}

menu
