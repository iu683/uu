#!/bin/bash
# ========================================
# Subs-Check 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="subs-check"
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
        echo -e "${GREEN}=== Subs-Check 管理菜单 ===${RESET}"
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

    mkdir -p "$APP_DIR/config"
    mkdir -p "$APP_DIR/output"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入 API 端口 [默认:8299]: " input_port1
    PORT1=${input_port1:-8299}
    check_port "$PORT1" || return

    read -p "请输入 Web 端口 [默认:8199]: " input_port2
    PORT2=${input_port2:-8199}
    check_port "$PORT2" || return

    read -p "请输入 API_KEY [回车自动生成]: " input_key

    if [ -z "$input_key" ]; then
        API_KEY=$(openssl rand -hex 16)
        echo "已自动生成 API_KEY: $API_KEY"
    else
        API_KEY="$input_key"
    fi

    read -p "请输入时区 [默认:Asia/Shanghai]: " input_tz
    TZ_VALUE=${input_tz:-Asia/Shanghai}

    cat > "$COMPOSE_FILE" <<EOF
services:
  subs-check:
    image: ghcr.io/beck-8/subs-check:latest
    container_name: subs-check
    volumes:
      - ./config:/app/config
      - ./output:/app/output
    ports:
      - "127.0.0.1:${PORT1}:8299"
      - "127.0.0.1:${PORT2}:8199"
    environment:
      - TZ=${TZ_VALUE}
      - API_KEY=${API_KEY}
    restart: always
    network_mode: bridge
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ Subs-Check 已启动${RESET}"
    echo -e "${YELLOW}🌐 API 地址: http://127.0.0.1:${PORT1}${RESET}"
    echo -e "${YELLOW}🔐 Web 地址: http://127.0.0.1:${PORT2}${RESET}"
    echo -e "${YELLOW}🔐 API_KEY: $API_KEY${RESET}"
    echo -e "${GREEN}📂 配置目录: $APP_DIR/config${RESET}"
    echo -e "${GREEN}📂 输出目录: $APP_DIR/output${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Subs-Check 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose restart
    echo -e "${GREEN}✅ Subs-Check 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f subs-check
}

check_status() {
    docker ps | grep subs-check
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Subs-Check 已彻底卸载（含数据）${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 启动菜单
# ==============================
menu
