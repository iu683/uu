#!/bin/bash
# ========================================
# baidupcs-rust 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="baidupcs-rust"
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
        echo -e "${GREEN}=== BaiduPCS-Rust 管理菜单 ===${RESET}"
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
# 安装
# ==============================

install_app() {

    check_docker

    mkdir -p "$APP_DIR"/{config,downloads,data,logs,wal}

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:18888]: " input_port
    PORT=${input_port:-18888}

    check_port "$PORT" || return

    cat > "$COMPOSE_FILE" <<EOF
services:
  baidupcs:
    image: komorebicarry/baidupcs-rust:latest
    container_name: baidupcs-rust
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:18888"

    volumes:
      - ./config:/app/config
      - ./downloads:/app/downloads
      - ./data:/app/data
      - ./logs:/app/logs
      - ./wal:/app/wal

    environment:
      - RUST_LOG=info
      - RUST_BACKTRACE=1

    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:18888/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ BaiduPCS-Rust 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR${RESET}"
    echo -e "${GREEN}📂 下载文件保存目录: $APP_DIR/downloads{RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 更新
# ==============================

update_app() {

    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ BaiduPCS-Rust 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 重启
# ==============================

restart_app() {

    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }

    docker compose restart

    echo -e "${GREEN}✅ BaiduPCS-Rust 已重启${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 日志
# ==============================

view_logs() {

    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"

    docker logs -f baidupcs-rust
}

# ==============================
# 状态
# ==============================

check_status() {

    docker ps | grep baidupcs-rust

    read -p "按回车返回菜单..."
}

# ==============================
# 卸载
# ==============================

uninstall_app() {

    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }

    docker compose down -v

    rm -rf "$APP_DIR"

    echo -e "${RED}✅ BaiduPCS-Rust 已彻底卸载（含数据）${RESET}"

    read -p "按回车返回菜单..."
}

# ==============================
# 启动菜单
# ==============================

menu
