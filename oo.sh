#!/bin/bash
# =================================================================
# Xboard Node 后端 Docker Compose 多实例运维管理面板 (编号切换版)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# 基础持久化路径
GLOBAL_BASE="/opt/xboard-multinode"
mkdir -p "$GLOBAL_BASE"

# 默认实例名
INSTANCE_FILE="$GLOBAL_BASE/.current_instance"
if [[ -f "$INSTANCE_FILE" ]]; then
    CURRENT_INSTANCE=$(cat "$INSTANCE_FILE")
else
    CURRENT_INSTANCE="node-1"
    echo "$CURRENT_INSTANCE" > "$INSTANCE_FILE"
fi

# 根据当前实例动态计算路径和容器名
update_instance_env() {
    CONTAINER_NAME="xboard-${CURRENT_INSTANCE}"
    BASE_DIR="${GLOBAL_BASE}/${CURRENT_INSTANCE}"
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
    CONFIG_FILE="$BASE_DIR/config/config.yml"
}
update_instance_env

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取当前实例的状态、Node ID 及镜像信息
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        panel_url=$(grep -E '^[[:space:]]*url:' "$CONFIG_FILE" | awk -F'"' '{print $2}')
        node_id=$(grep -E '^[[:space:]]*node_id:' "$CONFIG_FILE" | awk '{print $2}')
        [[ -z "$node_id" ]] && node_id="未知"
        [[ -z "$panel_url" ]] && panel_url="未知"
    else
        node_id="N/A"
        panel_url="N/A"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"
    else
        img_version="${RED}未安装${RESET}"
    fi
}

# 获取公网 IP (兼容双栈环境)
get_public_ip() {
    local mode=${1:-"auto"}
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
}


# 编号切换/新建实例
switch_instance() {
    clear
    echo -e "${CYAN}====== 节点切换与新建 ======${RESET}"
    echo -e "${YELLOW}当前已检测到以下节点：${RESET}"
    
    # 获取实例列表到数组
    local idx=1
    declare -A instance_map
    
    # 强制确保默认的 node-1 文件夹即使没创建也显示
    if [[ ! -d "$GLOBAL_BASE/node-1" ]]; then
        mkdir -p "$GLOBAL_BASE/node-1"
    fi

    for dir in $(ls -1 "$GLOBAL_BASE" | grep -v '^\.'); do
        if [[ "$dir" == "$CURRENT_INSTANCE" ]]; then
            echo -e " [${GREEN}${idx}${RESET}] ${dir} ${GREEN}(当前选择)${RESET}"
        else
            echo -e " [${CYAN}${idx}${RESET}] ${dir}"
        fi
        instance_map[$idx]="$dir"
        ((idx++))
    done
    
    echo -e " [${YELLOW}n${RESET}] 添加节点 (Create New Instance)"
    echo -e " [${RED}0${RESET}] 返回主菜单"
    echo -e "----------------------------------------"
    echo -ne "${YELLOW}请输入对应编号: ${RESET}"
    read -r inst_choice

    if [[ "$inst_choice" == "0" ]]; then
        return
    elif [[ "$inst_choice" == "n" || "$inst_choice" == "N" ]]; then
        echo -ne "${YELLOW}请输入新节点的名称 (建议字母加数字，如 node-2): ${RESET}"
        read -r new_name
        if [[ -z "$new_name" ]]; then
            echo -e "${RED}错误：节点名不能为空！${RESET}"
            sleep 2
            return
        fi
        CURRENT_INSTANCE="$new_name"
    elif [[ -n "${instance_map[$inst_choice]}" ]]; then
        CURRENT_INSTANCE="${instance_map[$inst_choice]}"
    else
        echo -e "${RED}无效选择！${RESET}"
        sleep 1
        return
    fi

    # 保存并更新环境
    echo "$CURRENT_INSTANCE" > "$INSTANCE_FILE"
    update_instance_env
    echo -e "${GREEN}成功切换至节点: ${CURRENT_INSTANCE}${RESET}"
    sleep 1.5
}

# 部署当前 Xboard Node 实例
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR/config"
    mkdir -p "$BASE_DIR/certs"

    echo -e "${CYAN}====== 部署节点: [ ${CURRENT_INSTANCE} ] ======${RESET}"
    
    echo -ne "${YELLOW}请输入 Xboard 面板 URL (如 https://xxx.com): ${RESET}"
    read -r custom_url
    [[ -z "$custom_url" ]] && echo -e "${RED}错误: 面板 URL 不能为空！${RESET}" && return

    echo -ne "${YELLOW}请输入 面板通讯 Token (通讯密钥): ${RESET}"
    read -r custom_token
    [[ -z "$custom_token" ]] && echo -e "${RED}错误: 通讯 Token 不能为空！${RESET}" && return

    echo -ne "${YELLOW}请输入 节点 ID (Node ID): ${RESET}"
    read -r custom_node_id
    if ! [[ "$custom_node_id" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 节点 ID 必须是纯数字！${RESET}"
        return
    fi

    # 1. 生成独占的 config.yml
    echo -e "${YELLOW}正在生成 config.yml 配置文件...${RESET}"
    cat <<EOF > "$CONFIG_FILE"
panel:
  url: "${custom_url}"
  token: "${custom_token}"
  node_id: ${custom_node_id}

kernel:
  type: "singbox"
  config_dir: "/etc/xboard-node"
  log_level: "warn"

log:
  level: "info"
  output: "stdout"
EOF

    # 2. 生成独占的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  xboard-node:
    image: ghcr.io/cedar2025/xboard-node:latest
    container_name: ${CONTAINER_NAME}
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./config:/etc/xboard-node
      - ./certs:/etc/xboard-node/certs
    command: ["-c", "/etc/xboard-node/config.yml"]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

    echo -e "${YELLOW}正在启动实例 [ ${CURRENT_INSTANCE} ] ...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化并建立同步 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   节点 [ ${CURRENT_INSTANCE} ] 部署成功！    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}绑定容器名 : ${CONTAINER_NAME}${RESET}"
    echo -e "${YELLOW}面板域名   : ${custom_url}${RESET}"
    echo -e "${YELLOW}绑定节点 ID: ${custom_node_id}${RESET}"
    echo -e "${YELLOW}配置目录   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新当前实例镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 当前实例未部署配置文件！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}当前实例更新完成！${RESET}"
}

# 卸载当前实例
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除节点 [ ${CURRENT_INSTANCE} ] 吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除当前节点的本地配置和证书？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}该实例文件夹已彻底清理。${RESET}"
                # 重置为默认实例名
                echo "node-1" > "$INSTANCE_FILE"
                update_instance_env
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}实例容器已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}实例容器已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}实例容器已重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前管理实例 : ${CYAN}${CURRENT_INSTANCE}${RESET}"
    echo -e "${YELLOW}状态         : $status"
    echo -e "${YELLOW}容器名称     : ${CONTAINER_NAME}${RESET}"
    echo -e "${YELLOW}后端镜像     : ${img_version}${RESET}"
    echo -e "${YELLOW}对接面板     : ${panel_url}${RESET}"
    echo -e "${YELLOW}绑定节点 ID  : ${node_id}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  Xboard 多节点管理面板 ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}当前管理实例 :${RESET} ${CYAN}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}当前实例状态 :${RESET} $status"
    echo -e "${GREEN}当前绑节点 ID :${RESET} [ ${YELLOW}${node_id}${RESET} ]"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署/启动当前实例${RESET}"
    echo -e "${GREEN}2. 更新当前实例${RESET}"
    echo -e "${GREEN}3. 卸载当前实例${RESET}"
    echo -e "${GREEN}4. 启动当前实例${RESET}"
    echo -e "${GREEN}5. 停止当前实例${RESET}"
    echo -e "${GREEN}6. 重启当前实例${RESET}"
    echo -e "${GREEN}7. 查看当前实例日志${RESET}"
    echo -e "${GREEN}8. 查看当前实例详细配置${RESET}"
    echo -e "${GREEN}9. 切换 / 新建实例${RESET}  ${YELLOW}← 添加节点${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_utils ;;
        2) update_utils ;;
        3) uninstall_utils ;;
        4) start_utils ;;
        5) stop_utils ;;
        6) restart_utils ;;
        7) logs_utils ;;
        8) show_info ;;
        9) switch_instance ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
