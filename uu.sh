#!/bin/bash
# ========================================
# GS-Main 一键管理脚本 (x86 / ARM 自适应)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="gs-main"
APP_DIR="/opt/$APP_NAME"
DATA_DIR="$APP_DIR/data"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

# ==============================
# 架构检测
# ==============================

detect_arch() {
    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64)
            IMAGE_NAME="docker-rep.gmssh.com/gmssh/gs-main-x86:latest"
            ;;
        aarch64|arm64)
            IMAGE_NAME="docker-rep.gmssh.com/gmssh/gs-main-arm:latest"
            ;;
        *)
            echo -e "${RED}❌ 不支持的架构: $ARCH${RESET}"
            exit 1
            ;;
    esac
}

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
        echo -e "${GREEN}=== GS-Main 管理菜单 ===${RESET}"
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
                ;;
        esac
    done
}

# ==============================
# 功能函数
# ==============================

install_app() {
    check_docker
    detect_arch

    mkdir -p "$DATA_DIR/logs"
    mkdir -p "$DATA_DIR/config"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:8090]: " input_port
    PORT=${input_port:-8090}
    check_port "$PORT" || return

    cat > "$COMPOSE_FILE" <<EOF
services:
  gs-main:
    container_name: gm-service
    image: ${IMAGE_NAME}
    restart: always
    ports:
      - "127.0.0.1:${PORT}:80"
    volumes:
      - ${DATA_DIR}/logs:/gs_logs
      - ${DATA_DIR}/config:/app/config
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ GS-Main 已启动${RESET}"
    echo -e "${YELLOW}📦 使用镜像: ${IMAGE_NAME}${RESET}"
    echo -e "${YELLOW}🌐 Web 地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 日志目录: ${DATA_DIR}/logs${RESET}"
    echo -e "${GREEN}📂 配置目录: ${DATA_DIR}/config${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ GS-Main 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose restart
    echo -e "${GREEN}✅ GS-Main 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f gm-service
}

check_status() {
    docker ps | grep gm-service
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ GS-Main 已彻底卸载（含数据）${RESET}"
    read -p "按回车返回菜单..."
}

menu
