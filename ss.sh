#!/bin/bash
# =================================================================
# MTProto (mtg) 代理 Docker Compose 多节点管理面板 (兼容修复版)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# 基础持久化路径
GLOBAL_BASE="/opt/mtg-multinode"
mkdir -p "$GLOBAL_BASE"

# 默认节点名
INSTANCE_FILE="$GLOBAL_BASE/.current_instance"
if [[ -f "$INSTANCE_FILE" ]]; then
    CURRENT_INSTANCE=$(cat "$INSTANCE_FILE")
else
    CURRENT_INSTANCE="node-1"
    echo "$CURRENT_INSTANCE" > "$INSTANCE_FILE"
fi

# 根据当前节点动态计算路径和容器名
update_instance_env() {
    CONTAINER_NAME="mtg-${CURRENT_INSTANCE}"
    BASE_DIR="${GLOBAL_BASE}/${CURRENT_INSTANCE}"
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
    ENV_FILE="$BASE_DIR/.env"
    CONFIG_FILE="$BASE_DIR/config.toml"
}
update_instance_env

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! docker compose version &> /dev/null && ! command -v docker-compose &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker Compose 插件！${RESET}"
        exit 1
    fi
    if ! command -v wget &> /dev/null; then
        echo -e "${RED}错误: 未检测到 wget，请先安装 (如: apt install wget)${RESET}"
        exit 1
    fi
}

# 随机端口生成函数
random_port() {
    local port
    while true; do
        port=$((RANDOM % 16383 + 49152))
        if ! ss -tuln | grep -q ":$port "; then
            echo "$port"
            return 0
        fi
    done
}

# 检查端口是否被占用
check_port() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        echo -e "${RED}错误: 端口 $port 已被占用，请更换端口或选择随机端口！${RESET}"
        return 1
    fi
    return 0
}

# 动态获取当前节点的状态及配置参数
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${GREEN}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE"
        mtg_port="${MTG_PORT:-N/A}"
    else
        mtg_port="N/A"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"
    else
        img_version="${RED}未安装${RESET}"
    fi
}

# 获取公网 IP
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

# 编号切换/新建节点
switch_instance() {
    clear
    echo -e "${GREEN}====== 节点切换与添加 ======${RESET}"
    echo -e "${YELLOW}当前已检测到以下节点：${RESET}"
    
    local idx=1
    declare -A instance_map
    
    if [[ ! -d "$GLOBAL_BASE/node-1" ]]; then
        mkdir -p "$GLOBAL_BASE/node-1"
    fi

    for dir in $(ls -1 "$GLOBAL_BASE" | grep -v '^\.'); do
        if [[ "$dir" == "$CURRENT_INSTANCE" ]]; then
            echo -e " ${GREEN}[${idx}] ${dir}${RESET} ${YELLOW}(当前选择)${RESET}"
        else
            echo -e " ${GREEN}[${idx}] ${dir}${RESET}"
        fi
        instance_map[$idx]="$dir"
        ((idx++))
    done
    
    echo -e " ${YELLOW}[n] 添加节点${RESET}"
    echo -e " ${RED}[0] 返回主菜单${RESET}"
    echo -e "${GREEN}---------------------------${RESET}"
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

# 部署当前节点
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 部署 MTProto 节点: [ ${CURRENT_INSTANCE} ] ======${RESET}"
    
    # 1. 配置监听端口
    echo -ne "${YELLOW}请输入监听端口 [默认随机]: ${RESET}"
    read -r input_port
    if [[ -z "$input_port" ]]; then
        PORT=$(random_port)
        echo -e "${GREEN}已自动生成随机端口: $PORT${RESET}"
    else
        PORT=$input_port
        if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
            return
        fi
    fi

    check_port "$PORT" || return

    # 2. 生成绝对合规的纯 32 位 Hex 密钥（必须为 16 字节，纯 0-9a-f，绝无 dd 或 ee 前缀）
    echo -e "${YELLOW}正在生成符合 mtg 服务端要求的标准 32 位 Hex 密钥...${RESET}"
    RAW_SECRET=$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | xxd -p)
    
    # 强制校验并过滤异常字符
    RAW_SECRET=$(echo "$RAW_SECRET" | tr -cd 'a-f0-9' | cut -c 1-32)

    # 客户端展示用的带 dd 混淆密钥
    CLIENT_SECRET="dd${RAW_SECRET}"

    # 3. 写入 .env 文件
    cat <<EOF > "$ENV_FILE"
MTG_PORT=${PORT}
MTG_SECRET=${RAW_SECRET}
MTG_CLIENT_SECRET=${CLIENT_SECRET}
EOF

    # 4. 生成 config.toml (只写入标准的纯 Hex 密钥)
    cat > "$CONFIG_FILE" <<EOF
secret = "$RAW_SECRET"
bind-to = "0.0.0.0:${PORT}"
EOF

    # 5. 生成 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  mtg:
    image: nineseconds/mtg:master
    container_name: ${CONTAINER_NAME}
    network_mode: host
    restart: always
    command: run /config.toml
    volumes:
      - ./config.toml:/config.toml
EOF

    echo -e "${YELLOW}正在启动节点 [ ${CURRENT_INSTANCE} ] ...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN} 节点 [ ${CURRENT_INSTANCE} ] 部署成功！             ${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW}绑定容器名     : ${CONTAINER_NAME}${RESET}"
    echo -e "${YELLOW}服务器端口     : ${PORT}${RESET}"
    echo -e "${YELLOW}服务端原生密钥 : ${RAW_SECRET}${RESET}"
    echo -e "${YELLOW}客户端混淆密钥 : ${CLIENT_SECRET}${RESET}"
    echo -e "${GREEN}------------------------------------------------${RESET}"
    echo -e "${CYAN}Telegram 点击直连内置链接:${RESET}"
    echo -e "${GREEN}tg://proxy?server=${DETECT_IP}&port=${PORT}&secret=${CLIENT_SECRET}${RESET}"
    echo -e "${GREEN}------------------------------------------------${RESET}"
    echo -e "${CYAN}Surge 配置文件格式片段:${RESET}"
    echo -e "${YELLOW}[MTProto]${RESET}"
    echo -e "interface = ${DETECT_IP}"
    echo -e "port = ${PORT}"
    echo -e "secret = ${CLIENT_SECRET}"
    echo -e "ipv6 = true"
    echo -e "${GREEN}================================================${RESET}"
}

# 更新当前节点镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 当前节点未部署配置文件！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}当前节点更新完成！${RESET}"
}

# 卸载当前节点
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除节点 [ ${CURRENT_INSTANCE} ] 吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除当前节点的本地配置文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}该节点文件夹已彻底清理。${RESET}"
                echo "node-1" > "$INSTANCE_FILE"
                update_instance_env
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" 2>/dev/null && docker compose start && echo -e "${GREEN}节点容器已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" 2>/dev/null && docker compose stop && echo -e "${YELLOW}节点容器已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" 2>/dev/null && docker compose restart && echo -e "${GREEN}节点容器已重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        DETECT_IP=$(get_public_ip)
        
        # 兜底清理逻辑：确保 MTG_SECRET 中绝对不包含非 Hex 前缀
        MTG_SECRET=$(echo "$MTG_SECRET" | tr -cd 'a-f0-9' | cut -c 1-32)
        MTG_CLIENT_SECRET="dd${MTG_SECRET}"

        echo -e "${GREEN}================================================${RESET}"
        echo -e "${YELLOW}当前管理节点   : ${CYAN}${CURRENT_INSTANCE}${RESET}"
        echo -e "${YELLOW}状态           : $status"
        echo -e "${YELLOW}容器名称       : ${CONTAINER_NAME}${RESET}"
        echo -e "${YELLOW}后端镜像       : ${img_version}${RESET}"
        echo -e "${YELLOW}代理端口       : ${MTG_PORT}${RESET}"
        echo -e "${YELLOW}服务端 Hex 密钥: ${MTG_SECRET}${RESET}"
        echo -e "${YELLOW}客户端带 dd 密钥: ${MTG_CLIENT_SECRET}${RESET}"
        echo -e "${GREEN}------------------------------------------------${RESET}"
        echo -e "${CYAN}Telegram 快捷连接链接:${RESET}"
        echo -e "${GREEN}tg://proxy?server=${DETECT_IP}&port=${MTG_PORT}&secret=${MTG_CLIENT_SECRET}${RESET}"
        echo -e "${GREEN}------------------------------------------------${RESET}"
        echo -e "${CYAN}Surge 配置文件格式片段:${RESET}"
        echo -e "${YELLOW}[MTProto]${RESET}"
        echo -e "interface = 127.0.0.1"
        echo -e "port = ${MTG_PORT}"
        echo -e "secret = ${MTG_CLIENT_SECRET}"
        echo -e "ipv6 = true"
        echo -e "${GREEN}================================================${RESET}"
    else
        echo -e "${RED}未检测到当前节点的部署环境文件。${RESET}"
    fi
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈ MTProto 多节点管理面板 ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}当前管理节点 :${RESET} ${CYAN}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}当前节点状态 :${RESET} $status"
    echo -e "${GREEN}当前节点端口 :${RESET} ${YELLOW}[ ${mtg_port} ]${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署当前节点${RESET}"
    echo -e "${GREEN}2. 更新当前节点${RESET}"
    echo -e "${GREEN}3. 卸载当前节点${RESET}"
    echo -e "${GREEN}4. 启动当前节点${RESET}"
    echo -e "${GREEN}5. 停止当前节点${RESET}"
    echo -e "${GREEN}6. 重启当前节点${RESET}"
    echo -e "${GREEN}7. 查看当前节点日志${RESET}"
    echo -e "${GREEN}8. 查看当前节点配置${RESET}"
    echo -e "${GREEN}9. 管理节点${RESET}  ${YELLOW}← 添加 / 切换节点${RESET}"
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
