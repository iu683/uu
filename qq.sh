#!/bin/bash
# ========================================
# YT-DLP-WebUI 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="yt-dlp-webui"
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
        echo -e "${GREEN}=== YT-DLP-WebUI 管理菜单 ===${RESET}"
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

# ==============================
# 功能函数：安装启动
# ==============================
install_app() {
    check_docker

    mkdir -p "$APP_DIR/data"
    mkdir -p "$APP_DIR/config"

    # 如果已有安装，提示是否覆盖
    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    # 输入端口
    read -p "请输入访问端口 [默认:3035]: " input_port
    PORT=${input_port:-3035}
    check_port "$PORT" || return

    # 输入用户名密码（生成 config.yml）
    read -p "请输入登录用户名: " input_user
    read -sp "请输入登录密码: " input_pass
    echo

    cat > "$APP_DIR/config/config.yml" <<EOF
require_auth: true
username: $input_user
password: $input_pass
EOF
    echo -e "${GREEN}✅ config.yml 已生成并启用认证${RESET}"

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  yt-dlp-webui:
    image: marcobaobao/yt-dlp-webui:latest
    container_name: yt-dlp-webui
    ports:
      - "127.0.0.1:${PORT}:3033"
    volumes:
      - ./data:/downloads
      - ./config:/config
    healthcheck:
      test: curl -f http://localhost:3033 || exit 1
      interval: 30s
      timeout: 10s
      retries: 3
    restart: unless-stopped
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ YT-DLP-WebUI 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web 地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    read -p "按回车返回菜单..."
}
update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ YT-DLP-WebUI 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose restart
    echo -e "${GREEN}✅ YT-DLP-WebUI 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f yt-dlp-webui
}

check_status() {
    docker ps | grep yt-dlp-webui
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ YT-DLP-WebUI 已彻底卸载（含数据）${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 启动菜单
# ==============================
menu
