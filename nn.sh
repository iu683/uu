#!/bin/bash
# ========================================
# Kuma Mieru 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="kuma-mieru"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/.env"

function menu() {
    clear
    echo -e "${GREEN}=== Kuma Mieru 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) view_logs ;;
        5) uninstall_app ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    mkdir -p "$APP_DIR"/{data,logs}

    # 输入参数
    read -p "请输入 Web 端口 [默认:3883]: " input_port
    PORT=${input_port:-3883}

    read -p "请输入 UPTIME_KUMA_BASE_URL [默认:http://127.0.0.1:3883]: " input_base_url
    UPTIME_KUMA_BASE_URL=${input_base_url:-http://127.0.0.1:3883}

    read -p "请输入 PAGE_ID [默认:test1]: " input_page_id
    PAGE_ID=${input_page_id:-test1}

    read -p "允许编辑页面? (true/false, 默认:true): " input_edit
    FEATURE_EDIT_THIS_PAGE=${input_edit:-true}

    read -p "显示星标按钮? (true/false, 默认:true): " input_star
    FEATURE_SHOW_STAR_BUTTON=${input_star:-true}

    read -p "仪表盘标题 [默认:Kuma Mieru]: " input_title
    FEATURE_TITLE=${input_title:-Kuma Mieru}

    read -p "仪表盘描述 [默认:My Uptime Dashboard]: " input_desc
    FEATURE_DESCRIPTION=${input_desc:-My Uptime Dashboard}

    read -p "图标 URL [默认:https://example.com/favicon.ico]: " input_icon
    FEATURE_ICON=${input_icon:-https://example.com/favicon.ico}

    # 克隆仓库
    git clone https://github.com/Alice39s/kuma-mieru.git "$APP_DIR"
    cd "$APP_DIR" || exit

    # 复制并配置环境变量
    cp .env.example .env
    sed -i "s|^UPTIME_KUMA_BASE_URL=.*|UPTIME_KUMA_BASE_URL=$UPTIME_KUMA_BASE_URL|" .env
    sed -i "s|^PAGE_ID=.*|PAGE_ID=$PAGE_ID|" .env
    sed -i "s|^FEATURE_EDIT_THIS_PAGE=.*|FEATURE_EDIT_THIS_PAGE=$FEATURE_EDIT_THIS_PAGE|" .env
    sed -i "s|^FEATURE_SHOW_STAR_BUTTON=.*|FEATURE_SHOW_STAR_BUTTON=$FEATURE_SHOW_STAR_BUTTON|" .env
    sed -i "s|^FEATURE_TITLE=.*|FEATURE_TITLE=$FEATURE_TITLE|" .env
    sed -i "s|^FEATURE_DESCRIPTION=.*|FEATURE_DESCRIPTION=$FEATURE_DESCRIPTION|" .env
    sed -i "s|^FEATURE_ICON=.*|FEATURE_ICON=$FEATURE_ICON|" .env

    # 配置 Docker Compose
    cat > "$COMPOSE_FILE" <<EOF
version: '3.8'

services:
  kuma-mieru:
    build: .
    container_name: kuma-mieru
    restart: unless-stopped
    ports:
      - "$PORT:3000"
    env_file:
      - .env
    environment:
      - NODE_ENV=production
      - UPTIME_KUMA_BASE_URL=\${UPTIME_KUMA_BASE_URL}
      - PAGE_ID=\${PAGE_ID}
      - FEATURE_EDIT_THIS_PAGE=\${FEATURE_EDIT_THIS_PAGE}
      - FEATURE_SHOW_STAR_BUTTON=\${FEATURE_SHOW_STAR_BUTTON}
      - FEATURE_TITLE=\${FEATURE_TITLE}
      - FEATURE_DESCRIPTION=\${FEATURE_DESCRIPTION}
      - FEATURE_ICON=\${FEATURE_ICON}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/api/health"]
      interval: 30s
      timeout: 3s
      retries: 3
    tmpfs:
      - /tmp
EOF

    # 启动服务
    docker compose up -d

    echo -e "${GREEN}✅ Kuma Mieru 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}📂 日志目录: $APP_DIR/logs${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Kuma Mieru 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ Kuma Mieru 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f kuma-mieru
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Kuma Mieru 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
