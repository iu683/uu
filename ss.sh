#!/bin/bash
# ========================================
# Kaloscope 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="kaloscope"
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
        echo -e "${GREEN}=== Kaloscope 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载${RESET}"
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
    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已存在配置文件，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    echo
    echo -e "${GREEN}--- 配置基础参数 ---${RESET}"
    
    read -p "请输入服务主端口 [默认:8000]: " input_port
    PORT=${input_port:-8000}
    check_port "$PORT" || return

    read -p "请输入 Aria2 端口 [默认:6888]: " input_aria_port
    ARIA_PORT=${input_aria_port:-6888}
    check_port "$ARIA_PORT" || return

    read -p "请输入 TLS 域名或IP [默认:127.0.0.1]: " input_hostname
    TLS_HOSTNAME=${input_hostname:-127.0.0.1}

    echo -e "${YELLOW}正在创建本地映射目录并修复权限...${RESET}"
    # 自动创建宿主机上的三个挂载目录，并确保 UID 1026 能够正常读写
    mkdir -p /volume1/kaloscope/workspace
    mkdir -p /volume1/kaloscope/downloads
    mkdir -p /volume1/kaloscope/animes
    chown -R 1026:100 /volume1/kaloscope

    echo -e "${YELLOW}正在生成 docker-compose.yml...${RESET}"
    
cat > "$COMPOSE_FILE" <<EOF
services:
  kaloscope:
    image: kaloscope/kaloscope:latest
    container_name: kaloscope
    extra_hosts:
      - host.docker.internal:host-gateway
    environment:
      - PUID=1026
      - PGID=100
      - UMASK=022
      - TZ=Asia/Shanghai
      - AUTO_TLS=true
      - TLS_HOSTNAME=${TLS_HOSTNAME}
      - ENABLE_ARIA2=true
    volumes:
      - /volume1/kaloscope/workspace:/workspace
      - /volume1/kaloscope/downloads:/downloads
      - /volume1/kaloscope/animes:/animes
    ports:
      - 127.0.0.1:${PORT}:8000
      - ${ARIA_PORT}:6888
      - ${ARIA_PORT}:6888/udp
    restart: unless-stopped
EOF

    cd "$APP_DIR" || exit
    echo -e "${YELLOW}正在启动 Docker 容器...${RESET}"
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置或日志${RESET}"
        read -p "按回车返回..."
        return
    fi

    echo
    echo -e "${GREEN}✅ Kaloscope 已成功启动！${RESET}"
    echo -e "${YELLOW}🌐 Web 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}📥 Aria2 下载端口: ${ARIA_PORT}${RESET}"
    echo -e "${GREEN}📂 数据目录: ${APP_DIR}${RESET}"
    echo
    read -p "按回车返回菜单..."
}

update_app() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${RED}❌ 未检测到配置文件，无法更新！${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    cd "$APP_DIR" || return
    echo -e "${YELLOW}正在后台拉取最新镜像（服务保持运行中）...${RESET}"
    
    docker compose pull

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 镜像拉取失败，请检查网络状况。${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    echo -e "${YELLOW}正在热更新服务（秒级无缝切换）...${RESET}"
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 更新启动失败，请查看日志！${RESET}"
    else
        echo -e "${GREEN}✅ Kaloscope 已完成平滑更新！${RESET}"
    fi
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart kaloscope
    echo -e "${GREEN}✅ Kaloscope 服务已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f kaloscope
}

check_status() {
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$APP_DIR" && docker compose ps
    else
        echo -e "${RED}❌ 未检测到运行中的服务${RESET}"
    fi
    read -p "按回车返回菜单..."
}

uninstall_app() {
    if [ -f "$COMPOSE_FILE" ]; then

        cd "$APP_DIR" && docker compose down
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ Kaloscope 容器已清理完成（本地存储的数据没有被删除）${RESET}"
    else
        echo -e "${RED}❌ 未检测到安装，无需卸载${RESET}"
    fi
    read -p "按回车返回菜单..."
}

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 sudo 或 root 权限运行此脚本！${RESET}"
    exit 1
fi

menu
