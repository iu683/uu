#!/bin/bash
# MTProto Proxy 管理脚本 for Docker
# 数据统一存放在 /opt/mtproxy

NAME="mtproxy"
IMAGE="ellermister/mtproxy"
DATA_DIR="/opt/mtproxy"

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# 检测端口是否被占用
function check_port() {
    local port=$1
    if command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" >/dev/null 2>&1
    elif command -v ss >/dev/null 2>&1; then
        ss -tuln | grep -q ":$port "
    else
        netstat -tuln 2>/dev/null | grep -q ":$port "
    fi
    [[ $? -eq 0 ]] && return 1 || return 0
}

function get_random_port() {
    while true; do
        PORT=$(shuf -i 1025-65535 -n 1)
        check_port $PORT && { echo $PORT; break; }
    done
}

function get_ip() {
    curl -s https://api.ipify.org || curl -s ifconfig.me || curl -s icanhazip.com
}

# 读取原配置文件（如果存在）
function read_config() {
    CONFIG_FILE="$DATA_DIR/config.env"
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        PORT=8443
        DOMAIN="cloudflare.com"
        IPWL="OFF"
    fi
}

# 保存配置
function save_config() {
    mkdir -p "$DATA_DIR"
    cat > "$DATA_DIR/config.env" <<EOF
PORT=$PORT
DOMAIN=$DOMAIN
IPWL=$IPWL
EOF
}

# 安装或启动代理
function install_proxy() {
    mkdir -p "$DATA_DIR"

    echo -e "\n${GREEN}=== 安装/启动 MTProto Proxy ===${RESET}\n"
    read -p "请输入外部端口 (默认 8443, 留空随机): " input_port
    if [[ -z "$input_port" ]]; then
        PORT=$(get_random_port)
        echo "随机选择未占用端口: $PORT"
    else
        PORT=$input_port
        while ! check_port $PORT; do
            echo "端口 $PORT 已被占用，请重新输入"
            read -p "端口: " PORT
        done
    fi

    read -p "IP 白名单选项 (OFF/IP/IPSEG, 默认 OFF): " IPWL
    IPWL=${IPWL:-OFF}
    read -p "请输入 domain (伪装域名, 默认 cloudflare.com): " DOMAIN
    DOMAIN=${DOMAIN:-cloudflare.com}

    save_config

    docker rm -f ${NAME} >/dev/null 2>&1

    docker run -d --name ${NAME} \
        --restart=always \
        -v ${DATA_DIR}:/data \
        -e domain="${DOMAIN}" \
        -e ip_white_list="${IPWL}" \
        -p 8080:80 \
        -p ${PORT}:443 \
        ${IMAGE}

    echo "⏳ 等待 5 秒让容器启动..."
    sleep 5

    IP=$(get_ip)
    SECRET=$(docker logs --tail 50 ${NAME} 2>&1 | grep "MTProxy Secret" | awk '{print $NF}' | tail -n1)

    echo -e "\n${GREEN}✅ 安装完成！代理信息如下：${RESET}"
    echo "服务器 IP: $IP"
    echo "端口     : $PORT"
    echo "Secret   : $SECRET"
    echo "domain   : $DOMAIN"
    echo
    echo "👉 Telegram 链接："
    echo "tg://proxy?server=$IP&port=$PORT&secret=$SECRET"
}

# 卸载代理
function uninstall_proxy() {
    echo -e "\n${GREEN}=== 卸载 MTProto Proxy ===${RESET}\n"
    docker rm -f ${NAME} >/dev/null 2>&1
    rm -rf "$DATA_DIR"
    echo "✅ 已卸载并清理配置。"
}

# 查看日志
function show_logs() {
    if ! docker ps --format '{{.Names}}' | grep -Eq "^${NAME}\$"; then
        echo "❌ 容器未运行，请先安装或启动代理。"
        return
    fi
    echo -e "\n${GREEN}=== MTProto Proxy 日志 (最近50行) ===${RESET}\n"
    docker logs --tail=50 -f ${NAME}
}

# 修改配置并重启
function modify_proxy() {
    read_config
    echo -e "\n${YELLOW}=== 修改配置并重启 MTProto Proxy ===${RESET}\n"
    read -p "请输入新的端口 (留空则不修改): " NEW_PORT
    read -p "请输入新的 domain (留空则不修改): " NEW_DOMAIN
    read -p "IP 白名单选项 (OFF/IP/IPSEG, 留空则不修改): " NEW_IPWL

    PORT=${NEW_PORT:-$PORT}
    DOMAIN=${NEW_DOMAIN:-$DOMAIN}
    IPWL=${NEW_IPWL:-$IPWL}

    save_config
    docker rm -f ${NAME} >/dev/null 2>&1

    docker run -d --name ${NAME} \
        --restart=always \
        -v ${DATA_DIR}:/data \
        -e domain="${DOMAIN}" \
        -e ip_white_list="${IPWL}" \
        -p 8080:80 \
        -p ${PORT}:443 \
        ${IMAGE}

    sleep 5
    IP=$(get_ip)
    SECRET=$(docker logs --tail 50 ${NAME} 2>&1 | grep "MTProxy Secret:" | tail -n1 | sed 's/.*MTProxy Secret: //g' | tr -d '[:space:]')

    echo -e "\n${GREEN}✅ 配置修改完成！代理信息如下：${RESET}"
    echo "服务器 IP: $IP"
    echo "端口     : $PORT"
    echo "Secret   : $SECRET"
    echo "domain   : $DOMAIN"
    echo
    echo "👉 Telegram 链接："
    echo "tg://proxy?server=$IP&port=$PORT&secret=$SECRET"
}

# 更新镜像并保留配置
function update_proxy() {
    read_config
    echo -e "\n${GREEN}=== 更新 MTProto Proxy ===${RESET}\n"
    docker pull ${IMAGE}
    docker rm -f ${NAME} >/dev/null 2>&1

    docker run -d --name ${NAME} \
        --restart=always \
        -v ${DATA_DIR}:/data \
        -e domain="${DOMAIN}" \
        -e ip_white_list="${IPWL}" \
        -p 8080:80 \
        -p ${PORT}:443 \
        ${IMAGE}

    sleep 5
    echo -e "${GREEN}✅ MTProto Proxy 已更新并保持原配置${RESET}"
}

# 菜单
function menu() {
    echo -e "\n${GREEN}===== MTProto Proxy 管理脚本 =====${RESET}"
    echo -e "${GREEN}1. 安装启动代理${RESET}"
    echo -e "${GREEN}2. 卸载代理${RESET}"
    echo -e "${GREEN}3. 查看运行日志${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 更新代理${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}=================================${RESET}"
    read -p "请输入选项: " choice
    case "$choice" in
        1) install_proxy ;;
        2) uninstall_proxy ;;
        3) show_logs ;;
        4) modify_proxy ;;
        5) update_proxy ;;
        0) exit 0 ;;
        *) echo "❌ 无效输入" ;;
    esac
}

while true; do
    menu
done
