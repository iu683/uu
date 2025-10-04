#!/usr/bin/env bash
# ========================================
# Koipy Docker 管理脚本
# ========================================

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

APP_DIR="/opt/koipy"
CONFIG_FILE="$APP_DIR/config.yaml"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONTAINER_NAME="koipy-app"
IMAGE_NAME="koipy/koipy:latest"

# ---------------------------
# 公用函数
# ---------------------------
pause() {
    echo
    read -rp "按回车键返回菜单..." key
}

# 检查 Docker
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}❌ 未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

# 检查 docker-compose
check_compose() {
    if command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    elif docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    else
        echo -e "${RED}❌ 未检测到 docker-compose，请安装 docker-compose 插件${RESET}"
        exit 1
    fi
}

# 下载并配置
setup_environment() {
    mkdir -p "$APP_DIR"
    echo -e "${GREEN}📂 创建目录: $APP_DIR${RESET}"

    echo -e "${GREEN}✅ 正在下载默认配置...${RESET}"
    curl -fsSL -o "$CONFIG_FILE" \
        https://raw.githubusercontent.com/koipy-org/koipy/master/resources/config.example.yaml
    echo -e "${GREEN}✅ 配置文件已保存: $CONFIG_FILE${RESET}"
}

# 自定义配置
customize_config() {
    echo -e "${GREEN}⚙️ 配置参数：${RESET}"

    read -r -p "License: " license
    read -r -p "Bot Token: " bot_token
    read -r -p "API ID(回车跳过): " api_id
    read -r -p "API Hash(回车跳过): " api_hash
    read -r -p "代理地址(回车跳过): " proxy
    read -r -p "HTTP Proxy(回车跳过): " http_proxy
    read -r -p "SOCKS5 Proxy(回车跳过): " socks5_proxy
    read -r -p "Slave ID: " slave_id
    read -r -p "Slave Token: " slave_token
    read -r -p "Slave Address(默认127.0.0.1:8765): " slave_address
    slave_address=${slave_address:-"127.0.0.1:8765"}
    read -r -p "Slave Path(默认/): " slave_path
    slave_path=${slave_path:-"/"}
    read -r -p "Slave Comment(后端备注): " slave_comment
    read -r -p "Slave Invoker(默认1): " slave_invoker
    slave_invoker=${slave_invoker:-"1"}
    read -r -p "启用 Sub-Store? (true/false, 默认false): " substore_enable
    substore_enable=${substore_enable:-"false"}
    read -r -p "自动部署 Sub-Store? (true/false, 默认false): " substore_autoDeploy
    substore_autoDeploy=${substore_autoDeploy:-"false"}

    sed -i "s|license:.*|license: \"$license\"|" "$CONFIG_FILE"
    sed -i "s|botToken:.*|botToken: \"$bot_token\"|" "$CONFIG_FILE"
    [[ -n "$api_id" ]] && sed -i "s|apiId:.*|apiId: \"$api_id\"|" "$CONFIG_FILE"
    [[ -n "$api_hash" ]] && sed -i "s|apiHash:.*|apiHash: \"$api_hash\"|" "$CONFIG_FILE"
    [[ -n "$proxy" ]] && sed -i "s|proxy:.*|proxy: \"$proxy\"|" "$CONFIG_FILE"
    [[ -n "$http_proxy" ]] && sed -i "s|httpProxy:.*|httpProxy: \"$http_proxy\"|" "$CONFIG_FILE"
    [[ -n "$socks5_proxy" ]] && sed -i "s|socks5Proxy:.*|socks5Proxy: \"$socks5_proxy\"|" "$CONFIG_FILE"
    sed -i "s|id:.*|id: \"$slave_id\"|" "$CONFIG_FILE"
    sed -i "s|token:.*|token: \"$slave_token\"|" "$CONFIG_FILE"
    sed -i "s|address:.*|address: \"$slave_address\"|" "$CONFIG_FILE"
    sed -i "s|path:.*|path: \"$slave_path\"|" "$CONFIG_FILE"
    sed -i "s|comment:.*|comment: \"$slave_comment\"|" "$CONFIG_FILE"
    sed -i "s|invoker:.*|invoker: $slave_invoker|" "$CONFIG_FILE"
    sed -i "s|subStoreEnable:.*|subStoreEnable: $substore_enable|" "$CONFIG_FILE"
    sed -i "s|subStoreAutoDeploy:.*|subStoreAutoDeploy: $substore_autoDeploy|" "$CONFIG_FILE"

    echo -e "${GREEN}✅ 配置文件已更新${RESET}"
}

# 生成 docker-compose.yml
generate_compose() {
    cat > "$COMPOSE_FILE" <<EOF
services:
  koipy:
    image: $IMAGE_NAME
    container_name: $CONTAINER_NAME
    stdin_open: true
    tty: true
    restart: always
    network_mode: host
    volumes:
      - $CONFIG_FILE:/app/config.yaml
EOF
    echo -e "${GREEN}✅ 已生成 docker-compose.yml${RESET}"
}

# ---------------------------
# 功能函数
# ---------------------------
install_start() {
    setup_environment
    customize_config
    generate_compose
    $COMPOSE_CMD up -d
    echo -e "${GREEN}🚀 Koipy 已安装并启动${RESET}"
    pause
}

update_service() {
    echo -e "${GREEN}✅ 正在更新 Koipy 镜像...${RESET}"
    docker pull $IMAGE_NAME
    $COMPOSE_CMD down
    $COMPOSE_CMD up -d
    echo -e "${GREEN}✅ 更新完成${RESET}"
    pause
}

uninstall_service() {
    echo -e "${RED} 卸载 Koipy (包含数据)...${RESET}"
    $COMPOSE_CMD down -v
    rm -rf "$APP_DIR" "$COMPOSE_FILE"
    echo -e "${GREEN}✅ 已卸载${RESET}"
    pause
}

view_logs() {
    $COMPOSE_CMD logs -f
    pause
}

restart_service() {
    $COMPOSE_CMD restart
    echo -e "${GREEN}✅ Koipy 已重启${RESET}"
    pause
}

# ---------------------------
# 菜单
# ---------------------------
menu() {
    clear
    echo -e "${GREEN}==== Koipy 管理脚本 ====${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 重启${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -r -p "请输入选项: " choice
    case $choice in
        1) install_start ;;
        2) update_service ;;
        3) uninstall_service ;;
        4) view_logs ;;
        5) restart_service ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误${RESET}"; pause ;;
    esac
}

# ---------------------------
# 主程序
# ---------------------------
check_docker
check_compose
while true; do
    menu
done
