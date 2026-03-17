#!/bin/bash
# ========================================
# go-wdd 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="go-wdd"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

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

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== go-wdd 管理菜单 ===${RESET}"
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
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    # 端口输入
    read -p "请输入 Web 端口 [默认:5574]: " input_port1
    PORT1=${input_port1:-5574}
    check_port "$PORT1" || return

    read -p "请输入 API 端口 [默认:5575]: " input_port2
    PORT2=${input_port2:-5575}
    check_port "$PORT2" || return

    # 目录输入
    read -p "请输入数据目录 [默认:/opt/go-wdd/data]: " input_data
    DATA_DIR=${input_data:-/opt/go-wdd/data}

    read -p "请输入静态文件目录 [默认:/opt/go-wdd/static]: " input_static
    STATIC_DIR=${input_static:-/opt/go-wdd/static}

    # 创建目录（关键）
    mkdir -p "$APP_DIR"
    mkdir -p "$DATA_DIR"
    mkdir -p "$STATIC_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  go-wdd:
    image: wbyanzu/go-wdd:latest
    container_name: go-wdd
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT1}:5574"
      - "127.0.0.1:${PORT2}:5575"
    volumes:
      - ${STATIC_DIR}:/app/static
      - ${DATA_DIR}:/app/data
    environment:
      TZ: Asia/Shanghai
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置${RESET}"
        return
    fi

    echo
    echo -e "${GREEN}✅ go-wdd 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web: http://127.0.0.1:${PORT1}${RESET}"
    echo -e "${YELLOW}🔗 API: http://127.0.0.1:${PORT2}${RESET}"
    echo -e "${YELLOW}🔗 账号/密码: admin/123456${RESET}"
    echo -e "${GREEN}📂 数据目录: ${DATA_DIR}${RESET}"
    echo -e "${GREEN}📂 静态目录: ${STATIC_DIR}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ go-wdd 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart go-wdd
    echo -e "${GREEN}✅ go-wdd 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f go-wdd
}

check_status() {
    docker ps | grep go-wdd
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ go-wdd 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
