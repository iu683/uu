#!/bin/bash
# QMediaSync 一键管理脚本（自定义端口+记忆端口+绑定127.0.0.1）

GREEN="\033[32m"
RESET="\033[0m"

APP_NAME="qmediasync"
BASE_DIR="/root/qmediasync"
CONFIG_DIR="$BASE_DIR/config"
MEDIA_DIR="$BASE_DIR/media"
YML_FILE="$BASE_DIR/qmediasync-compose.yml"
PORT_FILE="$BASE_DIR/port.conf"
DEFAULT_PORT=12333  # 默认宿主机端口

# ---------- 获取公网IP ----------
get_ip() {
    curl -s ipv4.icanhazip.com || curl -s ifconfig.me
}

# ---------- 获取上次端口 ----------
get_last_port() {
    if [ -f "$PORT_FILE" ]; then
        LAST_PORT=$(cat "$PORT_FILE")
    else
        LAST_PORT=$DEFAULT_PORT
    fi
}

# ---------- 保存端口 ----------
save_port() {
    echo "$HOST_PORT" > "$PORT_FILE"
}

# ---------- 创建 docker-compose.yml ----------
create_compose() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$MEDIA_DIR"
    mkdir -p "$BASE_DIR"

    cat > $YML_FILE <<EOF
services:
  qmediasync:
    image: qicfan/qmediasync:latest
    container_name: qmediasync
    restart: unless-stopped
    ports:
      - "127.0.0.1:$HOST_PORT:12333"  # 自定义端口绑定到本机
      - "8095:8095"
      - "8094:8094"
    volumes:
      - $CONFIG_DIR:/app/config
      - $MEDIA_DIR:/media
    environment:
      - TZ=Asia/Shanghai

networks:
  default:
    name: qmediasync
EOF
}

# ---------- 菜单 ----------
show_menu() {
    echo -e "${GREEN}=== QMediaSync 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装并启动 QMediaSync${RESET}"
    echo -e "${GREEN}2) 停止 QMediaSync${RESET}"
    echo -e "${GREEN}3) 启动 QMediaSync${RESET}"
    echo -e "${GREEN}4) 重启 QMediaSync${RESET}"
    echo -e "${GREEN}5) 更新 QMediaSync${RESET}"
    echo -e "${GREEN}6) 查看日志${RESET}"
    echo -e "${GREEN}7) 卸载 QMediaSync（含数据）${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}==========================${RESET}"
    read -p "请选择: " choice
}

# ---------- 打印访问信息 ----------
print_access_info() {
    local ip=$(get_ip)
    echo -e "🌐 访问地址: ${GREEN}http://127.0.0.1:$HOST_PORT${RESET}"
    echo -e "👤 默认用户: ${GREEN}admin${RESET}"
    echo -e "🔑 默认密码: ${GREEN}admin123${RESET}"
}

# ---------- 输入端口 ----------
input_port() {
    get_last_port
    read -p "请输入宿主机端口（默认 $LAST_PORT）: " port
    HOST_PORT=${port:-$LAST_PORT}
    save_port
}

# ---------- 安装 ----------
install_app() {
    input_port
    create_compose
    docker compose -f $YML_FILE up -d
    echo -e "✅ ${GREEN}QMediaSync 已安装并启动${RESET}"
    print_access_info
}

# ---------- 启动 ----------
start_app() {
    input_port
    create_compose
    docker compose -f $YML_FILE up -d
    echo -e "🚀 ${GREEN}QMediaSync 已启动${RESET}"
    print_access_info
}

# ---------- 停止 ----------
stop_app() {
    docker compose -f $YML_FILE down
    echo -e "🛑 ${GREEN}QMediaSync 已停止${RESET}"
}

# ---------- 重启 ----------
restart_app() {
    input_port
    create_compose
    docker compose -f $YML_FILE down
    docker compose -f $YML_FILE up -d
    echo -e "🔄 ${GREEN}QMediaSync 已重启${RESET}"
    print_access_info
}

# ---------- 更新 ----------
update_app() {
    docker compose -f $YML_FILE pull
    docker compose -f $YML_FILE up -d
    echo -e "⬆️ ${GREEN}QMediaSync 已更新到最新版本${RESET}"
    print_access_info
}

# ---------- 查看日志 ----------
logs_app() {
    docker logs -f $APP_NAME
}

# ---------- 卸载 ----------
uninstall_app() {
    docker compose -f $YML_FILE down
    rm -f $YML_FILE "$PORT_FILE"
    rm -rf "$CONFIG_DIR" "$MEDIA_DIR"
    echo -e "🗑️ ${GREEN}QMediaSync 已卸载，数据目录也已删除${RESET}"
}

# ---------- 循环菜单 ----------
while true; do
    show_menu
    case $choice in
        1) install_app ;;
        2) stop_app ;;
        3) start_app ;;
        4) restart_app ;;
        5) update_app ;;
        6) logs_app ;;
        7) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "❌ ${GREEN}无效选择${RESET}" ;;
    esac
done
