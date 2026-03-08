#!/bin/bash
# ========================================
# Nezha Dashboard 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="nezha-dashboard"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

function menu() {
    clear
    echo -e "${GREEN}===哪吒V1管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) view_logs ;;
        5) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

function install_app() {
    mkdir -p "$APP_DIR/data"

    read -p "请输入 Web 端口 [默认:8008]: " input_port
    PORT=${input_port:-8008}

    # 写 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  dashboard:
    image: ghcr.io/nezhahq/nezha
    container_name: nezha-dashboard
    restart: always
    ports:
      - "127.0.0.1:$PORT:8008"
    volumes:
      - $APP_DIR/data:/dashboard/data
EOF

    cd "$APP_DIR"
    docker compose up -d

    CONFIG_FILE="$APP_DIR/data/config.yaml"

    # 在文件末尾追加 TSDB 配置
    cat >> "$CONFIG_FILE" <<EOF
tsdb:
  data_path: data/tsdb
EOF
    # 重启容器生效
    docker compose restart

    echo -e "${GREEN}✅ Nezha Dashboard 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${YELLOW}🌐 账号/密码: admin/admin${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    read -p "按回车返回菜单..."
    menu
}


function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Nezha Dashboard 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ Nezha Dashboard 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f nezha-dashboard
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Nezha Dashboard 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
