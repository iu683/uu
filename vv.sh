#!/bin/bash
# ========================================
# Heki 多实例节点管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="heki"
APP_BASE_DIR="/root/$APP_NAME"

mkdir -p "$APP_BASE_DIR"

# ==============================
# 检查 Docker
# ==============================
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

# ==============================
# 列出实例
# ==============================
list_instances() {
    echo -e "${GREEN}=== 已有实例 ===${RESET}"
    local count=0
    for inst in "$APP_BASE_DIR"/*; do
        [ -d "$inst" ] || continue
        count=$((count+1))
        echo -e "${YELLOW}[$count] $(basename "$inst")${RESET}"
    done
    [ $count -eq 0 ] && echo -e "${YELLOW}无实例${RESET}"
}

# ==============================
# 选择实例
# ==============================
select_instance() {
    list_instances
    read -r -p $'\033[32m请输入实例编号或名称: \033[0m' input
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        INSTANCE=$(ls -d "$APP_BASE_DIR"/* | sed -n "${input}p" | xargs basename)
    else
        INSTANCE="$input"
    fi
    INSTANCE_DIR="$APP_BASE_DIR/$INSTANCE"
    [ -d "$INSTANCE_DIR" ] || { echo -e "${RED}实例不存在${RESET}"; return 1; }
    return 0
}

# ==============================
# 安装实例
# ==============================
install_instance() {
    check_docker
    read -p "请输入实例名称 [默认 node$(date +%s)]: " INSTANCE
    INSTANCE=${INSTANCE:-node$(date +%s)}
    INSTANCE_DIR="$APP_BASE_DIR/$INSTANCE"
    mkdir -p "$INSTANCE_DIR"

    read -p "请输入 Panel 类型 [默认:xboard]: " PANEL_TYPE
    PANEL_TYPE=${PANEL_TYPE:-xboard}
    read -p "请输入 Server 类型 [默认:vless]: " SERVER_TYPE
    SERVER_TYPE=${SERVER_TYPE:-vless}
    read -p "请输入 Node ID(节点ID): " NODE_ID
    read -p "请输入 Panel URL(面板网址): " PANEL_URL
    read -p "请输入 Panel Key(节点密钥): " PANEL_KEY

    cat > "$INSTANCE_DIR/docker-compose.yml" <<EOF
services:
  heki_${INSTANCE}:
    image: hekicore/heki:latest
    container_name: heki_${INSTANCE}
    restart: on-failure
    network_mode: host
    environment:
      type: ${PANEL_TYPE}
      server_type: ${SERVER_TYPE}
      node_id: ${NODE_ID}
      panel_url: ${PANEL_URL}
      panel_key: ${PANEL_KEY}
    volumes:
      - $INSTANCE_DIR:/etc/heki/
EOF

    cd "$INSTANCE_DIR" || return
    docker compose up -d
    echo -e "${GREEN}✅ 实例 $INSTANCE 已启动${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 单实例操作
# ==============================
instance_action() {
    select_instance || return
    while true; do
    echo -e "${GREEN}=== 实例 [$INSTANCE] 管理 ===${RESET}"
    echo -e "${GREEN}1) 启动${RESET}"
    echo -e "${GREEN}2) 暂停${RESET}"       # 新增暂停
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 更新${RESET}"
    echo -e "${GREEN}5) 查看日志${RESET}"
    echo -e "${GREEN}6) 卸载${RESET}"
    echo -e "${GREEN}0) 返回${RESET}"
    read -r -p $'\033[32m请选择操作: \033[0m' choice

    cd "$INSTANCE_DIR" || break
    case $choice in
        1) docker compose up -d ;;
        2) docker stop heki_${INSTANCE} ;;       # 暂停容器
        3) docker restart heki_${INSTANCE} ;;
        4) docker compose pull && docker compose up -d ;;
        5) docker logs -f heki_${INSTANCE} ;;
        6) docker compose down && rm -rf "$INSTANCE_DIR" && break ;;
        0) break ;;
        *) echo -e "${RED}无效选择${RESET}" ;;
    esac
done
}



# ==============================
# 查看所有实例状态
# ==============================
show_all_status() {
    echo -e "${GREEN}=== 所有实例状态 ===${RESET}"
    for inst in "$APP_BASE_DIR"/*; do
        [ -d "$inst" ] || continue
        NAME=$(basename "$inst")
        STATUS=$(docker ps --format '{{.Names}}' | grep -q "^heki_$NAME$" && echo "运行中" || echo "已停止")
        echo -e "${YELLOW}$NAME${RESET} ${YELLOW}| 状态: $STATUS${RESET}"
    done
    read -p "按回车返回菜单..."
}

# ==============================
# 批量操作实例
# ==============================
batch_action() {
    list_instances
    echo -e "${GREEN}0) 返回菜单${RESET}"  
    read -r -p $'\033[32m请输入要操作的实例编号(空格分隔，或 all 全选): \033[0m' input
    [[ "$input" == "0" ]] && return    # 如果输入0，直接返回菜单

    if [[ "$input" == "all" ]]; then
        SELECTED=($(ls -d "$APP_BASE_DIR"/* | xargs -n1 basename))
    else
        SELECTED=()
        for i in $input; do
            NODE=$(ls -d "$APP_BASE_DIR"/* | sed -n "${i}p" | xargs basename)
            [ -n "$NODE" ] && SELECTED+=("$NODE")
        done
    fi

    [ ${#SELECTED[@]} -eq 0 ] && { echo -e "${YELLOW}没有有效节点${RESET}"; sleep 1; return; }

    read -r -p $'\033[32m选择操作: 1) 启动 2) 暂停 3) 重启 4) 更新 5) 卸载 0) 返回: \033[0m' action
    [[ "$action" == "0" ]] && return  

    for INSTANCE in "${SELECTED[@]}"; do
        INSTANCE_DIR="$APP_BASE_DIR/$INSTANCE"
        cd "$INSTANCE_DIR" || continue
        case "$action" in
            1) docker compose up -d ;;
            2) docker stop heki_${INSTANCE} ;;  
            3) docker restart heki_${INSTANCE} ;;
            4) docker compose pull && docker compose up -d ;;
            5) docker compose down && rm -rf "$INSTANCE_DIR" ;;
            *) echo -e "${RED}无效操作${RESET}" ;;
        esac
        echo -e "${GREEN}✅ 实例 $INSTANCE 操作完成${RESET}"
    done
    read -p "按回车返回菜单..."
}

# ==============================
# 主菜单
# ==============================
menu() {
    check_docker
    while true; do
        clear
        echo -e "${GREEN}=== Heki 多实例管理 ===${RESET}"
        echo -e "${GREEN}1) 安装新实例${RESET}"
        echo -e "${GREEN}2) 管理单个实例${RESET}"
        echo -e "${GREEN}3) 查看所有实例状态${RESET}"
        echo -e "${GREEN}4) 批量操作实例${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"

        read -r -p $'\033[32m请选择操作: \033[0m' choice
        case $choice in
            1) install_instance ;;
            2) instance_action ;;
            3) show_all_status ;;
            4) batch_action ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
        esac
    done
}

menu
