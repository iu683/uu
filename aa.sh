#!/bin/bash
# ========================================
# nb-panel 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="nb-panel"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 请以 root 用户运行此脚本！${RESET}"
    exit 1
fi

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
        echo -e "${GREEN}=== nb-panel 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启服务${RESET}"
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

    mkdir -p "$APP_DIR/data"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read -p "选择: " confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:4000]: " input_port
    PORT=${input_port:-4000}
    check_port "$PORT" || return

    cat > "$COMPOSE_FILE" <<EOF
services:
  nb-panel:
    image: ghcr.io/lima-droid/nb-panel:latest
    container_name: nbpanel
    restart: always
    ports:
      - "127.0.0.1:${PORT}:4000"
    volumes:
      - ./data:/app/data
    environment:
      - TZ=Asia/Shanghai
    networks:
      - nb-panel-network

networks:
  nb-panel-network:
    driver: bridge
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ nb-panel 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🌐 默认账号: nbpanel${RESET}"
    echo -e "${YELLOW}🌐 默认密码: Np123456${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}错误: 未检测到安装目录 $APP_DIR${RESET}"
        sleep 2
        return
    fi
    cd "$APP_DIR" || return
    echo -e "${YELLOW}正在拉取最新镜像...${RESET}"
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}错误: 未检测到安装目录 $APP_DIR${RESET}"
        sleep 2
        return
    fi
    cd "$APP_DIR" || return
    echo -e "${YELLOW}正在重启服务...${RESET}"
    docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}错误: 未检测到安装目录 $APP_DIR${RESET}"
        sleep 2
        return
    fi
    cd "$APP_DIR" || return
    echo -e "${YELLOW}提示: 按 Ctrl+C 可以退出日志查看并返回菜单${RESET}"
    sleep 1
    docker compose logs -f nb-panel
}

check_status() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}错误: 未检测到安装目录 $APP_DIR${RESET}"
        sleep 2
        return
    fi
    cd "$APP_DIR" || return
    echo -e "${GREEN}=== 容器运行状态 ===${RESET}"
    docker compose ps
    read -p "按回车返回菜单..."
}

uninstall_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}错误: 未检测到安装目录 $APP_DIR${RESET}"
        sleep 2
        return
    fi

    cd "$APP_DIR" || return
    # 停止容器并移除卷
    docker compose down -v
    # 删除整个数据和配置文件目录
    cd /opt && rm -rf "$APP_DIR"
    
    echo -e "${RED}✅ nb-panel 已彻底卸载，数据已清空${RESET}"
    read -p "按回车返回菜单..."
}

menu
