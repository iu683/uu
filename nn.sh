#!/bin/bash
# ========================================
# MTG 多节点管理脚本（Host 模式）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="MTProto"
APP_DIR="/opt/$APP_NAME"

# ========================================
# Docker 检测
# ========================================
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

# ========================================
# 端口检测
# ========================================
check_port() {
    if ss -tuln | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用！${RESET}"
        return 1
    fi
}

random_port() {
    while :; do
        PORT=$(shuf -i 10000-65535 -n1)
        ss -tuln | grep -q ":$PORT " || break
    done
    echo "$PORT"
}

# ========================================
# 列出节点
# ========================================
list_nodes() {
    mkdir -p "$APP_DIR"
    echo -e "${GREEN}=== 已有 MTG 节点 ===${RESET}"
    local count=0
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        count=$((count+1))
        echo -e "${YELLOW}[$count] $(basename "$node")${RESET}"
    done
    [ $count -eq 0 ] && echo -e "${YELLOW}无节点${RESET}"
}

# ========================================
# 安装节点
# ========================================
install_node() {
    check_docker

    read -p "请输入节点名称 [node$(date +%s)]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-node$(date +%s)}
    NODE_DIR="$APP_DIR/$NODE_NAME"
    mkdir -p "$NODE_DIR"

    read -p "请输入监听端口 [默认随机]: " input_port
    PORT=${input_port:-$(random_port)}
    check_port "$PORT" || return

    read -p "请输入伪装域名 [默认 bing.com]: " input_domain
    DOMAIN=${input_domain:-bing.com}

    SECRET=$(docker run --rm nineseconds/mtg:master generate-secret --hex $DOMAIN)

    cat > "$NODE_DIR/config.toml" <<EOF
secret = "$SECRET"
bind-to = "0.0.0.0:${PORT}"
EOF

    cat > "$NODE_DIR/compose.yml" <<EOF
services:
  $NODE_NAME:
    image: nineseconds/mtg:master
    container_name: $NODE_NAME
    restart: always
    network_mode: host
    volumes:
      - ./config.toml:/config.toml
EOF

    cd "$NODE_DIR" || return
    docker compose up -d

    SERVER_IP=$(curl -s ipv4.icanhazip.com 2>/dev/null)
    [ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')

    echo
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${GREEN}✅ 节点 $NODE_NAME 已启动${RESET}"
    echo -e "${YELLOW}端口: $PORT${RESET}"
    echo -e "${YELLOW}Secret: $SECRET${RESET}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${YELLOW}tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=${SECRET}${RESET}"
    echo
    read -p "按回车返回菜单..."
}

# ========================================
# 节点管理
# ========================================
node_action_menu() {
    list_nodes
    read -r -p $'\033[32m请输入节点名称或编号: \033[0m' input
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        NODE_NAME=$(ls -d "$APP_DIR"/* | sed -n "${input}p" | xargs basename)
    else
        NODE_NAME="$input"
    fi
    NODE_DIR="$APP_DIR/$NODE_NAME"
    [ -d "$NODE_DIR" ] || { echo -e "${RED}节点不存在${RESET}"; return; }

    while true; do
        echo -e "${GREEN}=== 节点 [$NODE_NAME] 管理 ===${RESET}"
        echo -e "${GREEN}1) 暂停${RESET}"
        echo -e "${GREEN}2) 重启${RESET}"
        echo -e "${GREEN}3) 更新${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 卸载${RESET}"
        echo -e "${GREEN}0) 返回${RESET}"
        read -r -p $'\033[32m请选择操作: \033[0m' choice

        case $choice in
            1) docker pause "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose -f "$NODE_DIR/compose.yml" pull && docker compose -f "$NODE_DIR/compose.yml" up -d ;;
            4) docker logs -f "$NODE_NAME" ;;
            5) docker compose -f "$NODE_DIR/compose.yml" down && rm -rf "$NODE_DIR" && return ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" ;;
        esac
    done
}


# ========================================
# 查看所有节点状态（读取 config.toml）
# ========================================
show_all_status() {
    echo -e "${GREEN}=== 节点状态 ===${RESET}"
    mkdir -p "$APP_DIR"

    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue

        NODE_NAME=$(basename "$node")
        CONFIG_FILE="$node/config.toml"

        PORT="未找到"
        SECRET="未找到"

        # 从 config.toml 读取端口和 secret
        if [ -f "$CONFIG_FILE" ]; then
            PORT=$(grep -oP 'bind-to\s*=\s*".*:\K[0-9]+' "$CONFIG_FILE")
            SECRET=$(grep -oP 'secret\s*=\s*"\K[^"]+' "$CONFIG_FILE")
        fi

        # 检查容器状态
        if docker ps --format '{{.Names}}' | grep -q "^${NODE_NAME}$"; then
            STATUS="${GREEN}运行中${RESET}"
        else
            STATUS="${RED}已停止${RESET}"
        fi

        echo -e "${YELLOW}${NODE_NAME}${RESET} | 端口: ${PORT} | 状态: ${STATUS}"
    done

    read -p "按回车返回菜单..."
}

# ========================================
# 批量操作节点
# ========================================
batch_action() {
    echo -e "${GREEN}=== 批量操作 ===${RESET}"
    echo -e "${GREEN}1) 暂停节点${RESET}"
    echo -e "${GREEN}2) 重启节点${RESET}"
    echo -e "${GREEN}3) 更新节点${RESET}"
    echo -e "${GREEN}4) 卸载节点${RESET}"
    echo -e "${GREEN}0) 返回${RESET}"
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

    [ $count -eq 0 ] && {
        echo -e "${YELLOW}无节点${RESET}"
        read -p "按回车返回菜单..."
        return
    }

    read -r -p $'\033[32m请输入要操作的节点序号（空格分隔，或输入 all 全选）: \033[0m' input_nodes

    if [[ "$input_nodes" == "all" ]]; then
        SELECTED_NODES=("${NODE_MAP[@]}")
    else
        SELECTED_NODES=()
        for i in $input_nodes; do
            NODE=${NODE_MAP[$i]}
            if [ -n "$NODE" ]; then
                SELECTED_NODES+=("$NODE")
            else
                echo -e "${YELLOW}⚠ 序号 $i 无效，跳过${RESET}"
            fi
        done
    fi

    for NODE_NAME in "${SELECTED_NODES[@]}"; do
        NODE_DIR="$APP_DIR/$NODE_NAME"

        [ -d "$NODE_DIR" ] || continue
        [ -f "$NODE_DIR/compose.yml" ] || {
            echo -e "${YELLOW}⚠ 节点 $NODE_NAME compose.yml 不存在，跳过${RESET}"
            continue
        }

        cd "$NODE_DIR" || continue

        case $choice in
            1)
                docker pause "$NODE_NAME"
                ;;
            2)
                docker restart "$NODE_NAME"
                ;;
            3)
                docker compose pull
                docker compose up -d
                ;;
            4)
                docker compose down
                rm -rf "$NODE_DIR"
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选择${RESET}"
                return
                ;;
        esac

        echo -e "${GREEN}✅ 节点 $NODE_NAME 操作完成${RESET}"
    done

    read -p "按回车返回菜单..."
}

# ========================================
# 主菜单
# ========================================
menu() {
    while true; do
        clear
        echo -e "${GREEN}=== MTProto 多节点管理 ===${RESET}"
        echo -e "${GREEN}1) 创建新节点${RESET}"
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
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

menu
