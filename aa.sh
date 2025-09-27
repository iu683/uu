#!/bin/bash
# ========================================
# Sub-Store 一键管理脚本
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="sub-store"
APP_DIR="$HOME/$APP_NAME"
DATA_DIR="$APP_DIR/data"
CONFIG_FILE="$APP_DIR/config.env"
DEFAULT_PORT=3001

mkdir -p "$DATA_DIR"

function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "your-ip"
}

function menu() {
    clear
    echo -e "${GREEN}=== Sub-Store 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 显示访问信息${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}=======================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        5) show_info ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    read -p "请输入端口 [默认:$DEFAULT_PORT]: " input_port
    PORT=${input_port:-$DEFAULT_PORT}

    # 随机生成路径（16 位）
    RANDOM_PATH=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)

    mkdir -p "$APP_DIR"

    cat > "$CONFIG_FILE" <<EOF
PORT=$PORT
RANDOM_PATH=$RANDOM_PATH
EOF

    docker rm -f $APP_NAME >/dev/null 2>&1

    docker run -it -d --restart=always \
      -e "SUB_STORE_CRON=0 0 * * *" \
      -e "SUB_STORE_FRONTEND_BACKEND_PATH=/$RANDOM_PATH" \
      -p 127.0.0.1:${PORT}:3001 \
      -v ${DATA_DIR}:/opt/app/data \
      --name ${APP_NAME} \
      xream/sub-store

    echo -e "${GREEN}✅ Sub-Store 已启动${RESET}"
    show_info
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    source "$CONFIG_FILE" 2>/dev/null || { echo "未检测到配置文件，请先安装"; sleep 1; menu; }
    docker rm -f $APP_NAME >/dev/null 2>&1
    docker run -it -d --restart=always \
      -e "SUB_STORE_CRON=0 0 * * *" \
      -e "SUB_STORE_FRONTEND_BACKEND_PATH=/$RANDOM_PATH" \
      -p 127.0.0.1:${PORT}:3001 \
      -v ${DATA_DIR}:/opt/app/data \
      --name ${APP_NAME} \
      xream/sub-store
    echo -e "${GREEN}✅ Sub-Store 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    docker rm -f $APP_NAME >/dev/null 2>&1
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Sub-Store 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f $APP_NAME
    read -p "按回车返回菜单..."
    menu
}

function show_info() {
    source "$CONFIG_FILE" 2>/dev/null || { echo "未检测到配置文件"; return; }
    echo -e "${GREEN}🌐 访问地址: http://127.0.0.1:${PORT}?api=http://127.0.0.1:${PORT}/$RANDOM_PATH${RESET}"
    echo -e "${GREEN}📂 数据目录: $DATA_DIR${RESET}"
    echo -e "${GREEN}🔑 后端路径: /$RANDOM_PATH${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
