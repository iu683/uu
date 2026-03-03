#!/bin/bash
# ========================================
# Snell 多节点管理脚本（彩色菜单 + 节点状态查看）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="snell-server"
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
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

list_nodes() {
    mkdir -p "$APP_DIR"
    echo -e "${GREEN}=== 已有 Snell 节点 ===${RESET}"
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
    mkdir -p "$NODE_DIR/data"

    # 监听端口
    read -p "请输入监听端口 [1025-65535, 默认随机]: " input_port
    PORT=${input_port:-$(shuf -i 1025-65535 -n1)}
    check_port "$PORT" || return

    # 随机 PSK
    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c32)

    # IPv6 开关
    read -p "是否启用 IPv6 [true/false, 默认 false]: " ipv6
    IPv6=${ipv6:-false}

    # 混淆
    read -p "混淆模式 [off/http, 默认 off]: " obfs
    OBFS=${obfs:-off}
    if [ "$OBFS" = "http" ]; then
        read -p "请输入混淆 Host [默认 example.com]: " obfs_host
        OBFS_HOST=${obfs_host:-example.com}
    else
        OBFS_HOST=""
    fi

    # TCP Fast Open
    read -p "是否启用 TCP Fast Open [true/false, 默认 true]: " tfo
    TFO=${tfo:-true}

    # ECN
    ECN=true

    # ========================
    # 生成 snell-server.conf
    # ========================
    CONF_FILE="$NODE_DIR/snell-server.conf"
    cat > "$CONF_FILE" <<EOF
[snell-server]
listen = 0.0.0.0:$PORT
psk = $PSK
tfo = $TFO
ecn = $ECN
EOF

    # 条件写入 IPv6
    if [[ "$IPv6" == "true" ]]; then
        echo "listen = [::]:$PORT" >> "$CONF_FILE"
    fi

    # 条件写入 OBFS
    if [[ "$OBFS" != "off" ]]; then
        echo "obfs = $OBFS" >> "$CONF_FILE"
        if [[ "$OBFS" == "http" && -n "$OBFS_HOST" ]]; then
            echo "obfs-host = $OBFS_HOST" >> "$CONF_FILE"
        fi
    fi

    # ========================
    # 生成 docker-compose.yml
    # ========================
    cat > "$NODE_DIR/docker-compose.yml" <<EOF
services:
  $NODE_NAME:
    image: 1byte/snell-server:latest
    container_name: $NODE_NAME
    restart: always
    network_mode: host
    volumes:
      - ./snell-server.conf:/app/snell-server.conf:ro
EOF

    # 启动节点
    cd "$NODE_DIR" || return
    docker compose up -d

    IP=$(hostname -I | awk '{print $1}')
    echo -e "${GREEN}📂 安装目录: $NODE_DIR${RESET}"
    echo -e "${GREEN}📄 V6VPS替换IP地址为V6⭐${RESET}"
    echo -e "${GREEN}✅ 节点 ${NODE_NAME} 已启动${RESET}"
    echo -e "${YELLOW}🌐 端口: ${PORT}${RESET}"
    echo -e "${YELLOW}🔑 PSK: ${PSK}${RESET}"
    echo -e "${YELLOW}📄 客户端配置:${RESET}"
    echo -e "${YELLOW}$NODE_NAME = snell, ${IP}, ${PORT}, psk=${PSK}, version=5, reuse=true, tfo=${TFO}, ecn=${ECN}${RESET}"
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
            1) docker pause "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose -f "$NODE_DIR/docker-compose.yml" pull && docker compose -f "$NODE_DIR/docker-compose.yml" up -d ;;
            4) docker logs -f "$NODE_NAME" ;;
            5)
               echo -e "${YELLOW} 正在卸载节点 $NODE_NAME ...${RESET}"
               cd "$APP_DIR" || cd /
               docker compose -f "$NODE_DIR/docker-compose.yml" down
               rm -rf "$NODE_DIR"
               echo -e "${GREEN}✅ 节点 $NODE_NAME 已卸载${RESET}"
               return
               ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" ;;
        esac
    done
}

batch_action() {
    echo -e "${GREEN}=== 批量操作 ===${RESET}"
    echo -e "${GREEN}1) 暂停节点${RESET}"
    echo -e "${GREEN}2) 重启节点${RESET}"
    echo -e "${GREEN}3) 更新节点${RESET}"
    echo -e "${GREEN}4) 卸载节点${RESET}"
    echo -e "${GREEN}0) 返回主菜单${RESET}"

    read -r -p $'\033[32m请选择操作: \033[0m' choice

    case "$choice" in
        1|2|3|4) ;;
        0) return ;;
        *)
            echo -e "${RED}无效选择${RESET}"
            sleep 1
            return
            ;;
    esac

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

    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}无节点${RESET}"
        read -r -p $'\033[32m按回车返回菜单...\033[0m'
        return
    fi

    read -r -p $'\033[32m请输入节点序号（空格分隔，或 all 全选）: \033[0m' input_nodes

    if [ -z "$input_nodes" ]; then
        echo -e "${YELLOW}未选择节点${RESET}"
        sleep 1
        return
    fi

    if [[ "$input_nodes" == "all" ]]; then
        SELECTED_NODES=("${NODE_MAP[@]}")
    else
        SELECTED_NODES=()
        for i in $input_nodes; do
            NODE=${NODE_MAP[$i]}
            if [ -n "$NODE" ]; then
                SELECTED_NODES+=("$NODE")
            else
                echo -e "${YELLOW}⚠ 序号 $i 无效，已跳过${RESET}"
            fi
        done
    fi

    if [ ${#SELECTED_NODES[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有有效节点${RESET}"
        sleep 1
        return
    fi

    # ===== 执行批量操作 =====
    for NODE_NAME in "${SELECTED_NODES[@]}"; do
        NODE_DIR="$APP_DIR/$NODE_NAME"

        if [ ! -f "$NODE_DIR/docker-compose.yml" ]; then
            echo -e "${YELLOW}⚠ 跳过 $NODE_NAME：未找到 docker-compose.yml${RESET}"
            continue
        fi

        cd "$NODE_DIR" || continue

        case $choice in
            1)
                docker compose pause
                ;;
            2)
                docker compose restart
                ;;
            3)
                docker compose pull
                docker compose up -d
                ;;
            4)
                docker compose down
                rm -rf "$NODE_DIR"
                ;;
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
        CONF_FILE="$node/snell-server.conf"

        # 从配置文件读取第一个 listen 端口
        if [ -f "$CONF_FILE" ]; then
            PORT=$(grep -E '^listen\s*=' "$CONF_FILE" | head -n1 | awk -F: '{print $2}')
        else
            PORT="未知"
        fi

        STATUS=$(docker ps --filter "name=$NODE_NAME" --format "{{.Status}}")
        [ -z "$STATUS" ] && STATUS="未启动"

        echo -e "${GREEN}$NODE_NAME${RESET} | ${YELLOW}端口: ${PORT}${RESET} | ${YELLOW}状态: ${STATUS}${RESET}"
    done
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Snell 节点管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动新节点${RESET}"
        echo -e "${GREEN}2) 管理已有节点${RESET}"
        echo -e "${GREEN}3) 查看所有节点状态${RESET}"
        echo -e "${GREEN}4) 批量操作所有节点${RESET}"
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
