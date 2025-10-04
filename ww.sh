#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# ========================================
# Koipy 一键管理脚本 (Docker)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="koipy"
APP_DIR="/opt/$APP_NAME"
CONFIG_FILE="$APP_DIR/config.yaml"
container_name="koipy"

# 安装环境
setup_environment() {
    mkdir -p "$APP_DIR"
    echo "创建了 $APP_DIR 文件夹。"

    if [ ! -f "$CONFIG_FILE" ]; then
        wget -O "$CONFIG_FILE" https://raw.githubusercontent.com/Polarisiu/app-store/refs/heads/main/config.example.yaml
        echo "下载 config.yaml 文件。"
    fi
}

# 检查 Docker
docker_check() {
    echo "正在检查 Docker 安装情况 . . ."
    if ! command -v docker &>/dev/null; then
        echo "Docker 未安装，请安装 Docker 并将当前用户加入 docker 组。"
        read -p "按回车返回菜单..." ; menu
    fi
    if ! docker info &>/dev/null; then
        echo "当前用户无权访问 Docker 或 Docker 未运行，请检查。"
        read -p "按回车返回菜单..." ; menu
    fi
    echo "Docker 已安装并可访问。"
}

# 构建 Docker 容器
build_docker() {
    docker rm -f "$container_name" &>/dev/null || true
    docker pull koipy/koipy:latest
}

# 配置 bot
configure_bot() {
    echo "开始配置参数 . . ."

    read -p "请输入 License(激活码): " license
    read -p "请输入 Bot Token(机器人密钥): " bot_token
    read -p "请输入 API (回车默认): " api_id
    read -p "请输入 API Hash(回车默认): " api_hash
    read -p "请输入代理地址(回车默认不使用): " proxy
    read -p "请输入 HTTP 代理地址(回车默认不使用): " http_proxy
    read -p "请输入 SOCKS5 代理地址(回车默认不使用): " socks5_proxy
    read -p "请输入 Slave ID(后端id): " slave_id
    read -p "请输入 Slave Token(后端密码): " slave_token
    read -p "请输入 Slave Address(回车默认127.0.0.1:8765): " slave_address
    slave_address=${slave_address:-"127.0.0.1:8765"}
    read -p "请输入 Slave Path(回车默认/): " slave_path
    slave_path=${slave_path:-"/"}
    read -p "请输入 Slave Comment(后端备注): " slave_comment
    read -p "是否启用 Sub-Store (回车默认false): " substore_enable
    substore_enable=${substore_enable:-"false"}
    read -p "是否自动部署 Sub-Store (回车默认false): " substore_autoDeploy
    substore_autoDeploy=${substore_autoDeploy:-"false"}

    # 更新 config.yaml
    sed -i.bak \
        -e "s|^license: .*|license: $license|" \
        -e "s|^\(  bot-token: \).*|\1$bot_token|" \
        -e "s|^\(  api-id: \).*|\1\"$api_id\"|" \
        -e "s|^\(  api-hash: \).*|\1$api_hash|" \
        -e "s|^\(  proxy: \).*|\1$proxy|" \
        -e "s|^\(  httpProxy: \).*|\1$http_proxy|" \
        -e "s|^\(  socks5Proxy: \).*|\1$socks5_proxy|" \
        -e "s|^\(      id: \).*|\1\"$slave_id\"|" \
        -e "s|^\(      token: \).*|\1'$slave_token'|" \
        -e "s|^\(      address: \).*|\1\"$slave_address\"|" \
        -e "s|^\(      path: \).*|\1$slave_path|" \
        -e "s|^\(      comment: \).*|\1\"$slave_comment\"|" \
        "$CONFIG_FILE"

    # 处理 substore
    if grep -q "substore:" "$CONFIG_FILE"; then
        sed -i.bak "/substore:/,/^ *[^ ]/ {
            /^ *enable:/ s|: .*|: $substore_enable|
            /^ *autoDeploy:/ s|: .*|: $substore_autoDeploy|
        }" "$CONFIG_FILE"
    else
        cat <<EOF >> "$CONFIG_FILE"

substore:
  enable: $substore_enable
  autoDeploy: $substore_autoDeploy
EOF
    fi

    echo "config.yaml 已更新。"
}

# 启动容器
start_docker() {
    docker run -dit --restart=no --name="$container_name" --hostname="$container_name" \
        -v "$CONFIG_FILE:/app/config.yaml" \
        --network host koipy/koipy:latest
    echo -e "${GREEN}✅ Docker 容器 $container_name 已启动${RESET}"
    read -p "按回车返回菜单..."
}

# 卸载容器并删除文件
cleanup() {
    docker rm -f "$container_name" &>/dev/null || echo "容器 $container_name 不存在"

    if [ -d "$APP_DIR" ]; then
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ 已卸载容器 $container_name${RESET}"
    fi
    read -p "按回车返回菜单..."
}

# 停止容器
stop_koipy() {
    docker stop "$container_name" &>/dev/null || echo "容器 $container_name 不存在"
    echo -e "${GREEN}✅ 已停止容器 $container_name${RESET}"
    read -p "按回车返回菜单..."
}

# 启动容器
start_koipy() {
    docker start "$container_name" &>/dev/null || echo "容器 $container_name 不存在"
    echo -e "${GREEN}✅ 已启动容器 $container_name${RESET}"
    read -p "按回车返回菜单..."
}

# 重启容器
restart_koipy() {
    docker restart "$container_name" &>/dev/null || echo "容器 $container_name 不存在"
    echo -e "${GREEN}✅ 已重启容器 $container_name${RESET}"
    read -p "按回车返回菜单..."
}

# 查看日志
view_logs() {
    echo -e "${GREEN}按 Ctrl+C 停止日志查看${RESET}"
    docker logs -f "$container_name"
    read -p "按回车返回菜单..."
}

# 安装流程
start_installation() {
    setup_environment
    docker_check
    build_docker
    configure_bot
    start_docker
}

# =========================
# 主菜单
# =========================
function menu() {
    clear
    echo -e "${GREEN}=== Koipy 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装${RESET}"
    echo -e "${GREEN}2) 卸载${RESET}"
    echo -e "${GREEN}3) 停止${RESET}"
    echo -e "${GREEN}4) 启动${RESET}"
    echo -e "${GREEN}5) 重启${RESET}"
    echo -e "${GREEN}6) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) start_installation ;;
        2) cleanup ;;
        3) stop_koipy ;;
        4) start_koipy ;;
        5) restart_koipy ;;
        6) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

# 启动菜单
menu
