#!/bin/bash
# ========================================
# Wallos 一键管理脚本
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="wallos"
APP_DIR="$HOME/$APP_NAME"
DB_DIR="$APP_DIR/db"
LOGO_DIR="$APP_DIR/logos"
CONFIG_FILE="$APP_DIR/config.env"
DEFAULT_PORT=8282

mkdir -p "$DB_DIR" "$LOGO_DIR"

function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "your-ip"
}

function menu() {
    clear
    echo -e "${GREEN}=== Wallos 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载 (含数据)${RESET}"
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
    read -p "请输入 Web 端口 [默认:$DEFAULT_PORT]: " input_port
    PORT=${input_port:-$DEFAULT_PORT}

    mkdir -p "$APP_DIR"

    cat > "$CONFIG_FILE" <<EOF
PORT=$PORT
EOF

    docker rm -f $APP_NAME >/dev/null 2>&1

    docker run -d \
      --name $APP_NAME \
      --restart unless-stopped \
      -p 127.0.0.1:$PORT:80 \
      -e TZ=Asia/Shanghai \
      -v $DB_DIR:/var/www/html/db \
      -v $LOGO_DIR:/var/www/html/images/uploads/logos \
      bellamy/wallos:latest

    echo -e "${GREEN}✅ Wallos 已启动${RESET}"
    show_info
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    source "$CONFIG_FILE" 2>/dev/null || { echo "未检测到配置文件，请先安装"; sleep 1; menu; }
    docker rm -f $APP_NAME >/dev/null 2>&1
    docker run -d \
      --name $APP_NAME \
      --restart unless-stopped \
      -p 127.0.0.1:$PORT:80 \
      -e TZ=Asia/Shanghai \
      -v $DB_DIR:/var/www/html/db \
      -v $LOGO_DIR:/var/www/html/images/uploads/logos \
      bellamy/wallos:latest
    echo -e "${GREEN}✅ Wallos 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    docker rm -f $APP_NAME >/dev/null 2>&1
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Wallos 已卸载，数据已删除${RESET}"
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
    echo -e "${GREEN}🌐 Web 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 数据库目录: $DB_DIR${RESET}"
    echo -e "${GREEN}📂 Logo 目录: $LOGO_DIR${RESET}"
}

menu
