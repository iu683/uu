#!/bin/bash
# =================================================================
# mtg (MTProto 代理) 工具箱 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="mtg-proxy"
BASE_DIR="/opt/mtg-proxy"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
CONFIG_FILE="$BASE_DIR/config.toml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
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

# 动态获取容器状态和配置信息
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 从 .env 读取关键连接参数用于菜单展示
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        webui_port="$MTG_PORT" # 这里借用变量回显端口
    else
        webui_port="N/A"
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

# 部署 mtg
install_utils() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义 MTProto 参数配置 ======${RESET}"

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

    # 检查端口可用性
    check_port "$PORT" || return

    # 2. 配置伪装域名
    echo -ne "${YELLOW}请输入伪装域名 [默认: bing.com]: ${RESET}"
    read -r input_domain
    [[ -z "$input_domain" ]] && input_domain="bing.com"

    echo -e "${YELLOW}正在通过 nineseconds/mtg 镜像动态生成安全混淆密钥 (Secret)...${RESET}"
    # 动态拉取并生成密钥
    SECRET=$(docker run --rm nineseconds/mtg:master generate-secret --hex "$input_domain" 2>/dev/null)
    
    if [[ -z "$SECRET" ]]; then
        echo -e "${RED}错误: 密钥生成失败，请检查 Docker 网络是否能够拉取 nineseconds/mtg:master 镜像！${RESET}"
        return
    fi

    # 写入 .env 文件
    cat <<EOF > "$ENV_FILE"
MTG_PORT=${PORT}
MTG_DOMAIN=${input_domain}
MTG_SECRET=${SECRET}
EOF

    # 3. 生成 config.toml
    cat > "$CONFIG_FILE" <<EOF
secret = "$SECRET"
bind-to = "0.0.0.0:${PORT}"
EOF

    # 4. 动态生成符合要求的 docker-compose.yml 配置文件 (使用 host 网络)
    echo -e "${YELLOW}正在生成符合标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  mtg:
    image: nineseconds/mtg:master
    container_name: ${CONTAINER_NAME}
    restart: always
    network_mode: host
    volumes:
      - ${CONFIG_FILE}:/config.toml
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 mtg 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN}          MTG MTProto 代理部署成功！             ${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW}服务器端口     : ${PORT}${RESET}"
    echo -e "${YELLOW}伪装域名       : ${input_domain}${RESET}"
    echo -e "${YELLOW}混淆密钥 (Hex) : ${SECRET}${RESET}"
    echo -e "${CYAN}Telegram 点击直连内置链接:${RESET}"
    echo -e "${GREEN}tg://proxy?server=${DETECT_IP}&port=${PORT}&secret=${SECRET}${RESET}"
    echo -e "${GREEN}================================================${RESET}"
}

# 更新镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载容器
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 mtg 容器吗？(y/n) [默认: N]: ${RESET}"
    read -r confirm
    [[ -z "$confirm" ]] && confirm="N"
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地数据与所有配置文件？(y/n) [默认: N]: ${RESET}"
            read -r clean_data
            [[ -z "$clean_data" ]] && clean_data="N"
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}所有配置文件及密钥目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        DETECT_IP=$(get_public_ip)
        echo -e "${GREEN}================================================${RESET}"
        echo -e "${YELLOW}当前状态       : $status"
        echo -e "${YELLOW}代理端口       : ${MTG_PORT}"
        echo -e "${YELLOW}伪装域名       : ${MTG_DOMAIN}"
        echo -e "${YELLOW}混淆密钥       : ${MTG_SECRET}"
        echo -e "${CYAN}Telegram 快捷连接链接:${RESET}"
        echo -e "${GREEN}tg://proxy?server=${DETECT_IP}&port=${MTG_PORT}&secret=${MTG_SECRET}${RESET}"
        echo -e "${GREEN}================================================${RESET}"
    else
        echo -e "${RED}未检测到部署配置环境。${RESET}"
    fi
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  MTProto 代理管理面板 ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
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
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
