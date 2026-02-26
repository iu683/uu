#!/bin/bash
# ========================================
# gcli2api 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="gcli2api"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

# ==============================
# 基础检测
# ==============================

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2，请升级 Docker${RESET}"
        exit 1
    fi
}

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

# ==============================
# 菜单
# ==============================

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== gcli2api 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            0) exit 0 ;;
            *)
                echo -e "${RED}无效选择${RESET}"
                sleep 1
                continue
                ;;
        esac
    done
}

# ==============================
# 功能函数
# ==============================

install_app() {
    check_docker

    mkdir -p "$APP_DIR/data/creds"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:7861]: " input_port
    PORT=${input_port:-7861}
    check_port "$PORT" || return

    read -p "请输入 API 密码: " API_PASSWORD
    read -p "请输入 面板 密码: " PANEL_PASSWORD

    cat > "$COMPOSE_FILE" <<EOF
services:
  gcli2api:
    image: ghcr.io/su-kaka/gcli2api:latest
    container_name: gcli2api
    restart: unless-stopped
    network_mode: host
    environment:
      - PORT=${PORT}
      - API_PASSWORD=${API_PASSWORD}
      - PANEL_PASSWORD=${PANEL_PASSWORD}
    volumes:
      - ./data/creds:/app/creds
    healthcheck:
      test: ["CMD-SHELL", "python -c \\"import sys, urllib.request, os; port=os.environ.get('PORT', '${PORT}'); req=urllib.request.Request(f'http://localhost:{port}/v1/models', headers={'Authorization': 'Bearer '+os.environ.get('API_PASSWORD','pwd')}); sys.exit(0 if urllib.request.urlopen(req, timeout=5).getcode()==200 else 1)\\""]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ gcli2api 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web 地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ gcli2api 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose restart
    echo -e "${GREEN}✅ gcli2api 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f gcli2api
}

check_status() {
    docker ps | grep gcli2api
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ gcli2api 已彻底卸载（含数据）${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 启动菜单
# ==============================
menu
