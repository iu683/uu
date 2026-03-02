#!/bin/bash
# ========================================
# Snell 一键管理脚本（Host 模式 + 去掉 DNS）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="snelldocker"
APP_DIR="/root/$APP_NAME"
CONF_DIR="$APP_DIR/snell-conf"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONTAINER_NAME="snell"

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
        echo -e "${GREEN}=== Snell 管理菜单 ===${RESET}"
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
    mkdir -p "$CONF_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    # ===== 选择 Snell 架构和 URL =====
    echo -e "${GREEN}请选择 Snell 架构:${RESET}"
    echo -e "1) amd64 (默认)"
    echo -e "2) armv7l"
    echo -e "3) 自定义 URL"
    read -p "选择 [1/2/3, 默认 1]: " arch_choice

    case $arch_choice in
        2)
            SNELL_URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-armv7l.zip"
            ;;
        3)
            read -p "请输入自定义 SNELL_URL: " custom_url
            SNELL_URL="$custom_url"
            ;;
        *)
            SNELL_URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
            ;;
    esac

    # ===== 端口自定义 / 随机 =====
    read -p "请输入监听端口 [1025-65535, 默认随机]: " input_port
    if [[ -z "$input_port" ]]; then
        PORT=$(shuf -i 1025-65535 -n1)
    else
        PORT=$input_port
    fi
    check_port "$PORT" || return

    # ===== 随机 32 位 PSK =====
    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c32)

    # ===== 可选配置 =====
    read -p "是否启用 IPv6 [true/false, 默认 false]: " ipv6
    IPv6=${ipv6:-false}

    read -p "混淆模式 [off/http, 默认 off]: " obfs
    OBFS=${obfs:-off}
    if [ "$OBFS" = "http" ]; then
        read -p "请输入混淆 Host [默认 example.com]: " obfs_host
        OBFS_HOST=${obfs_host:-example.com}
    else
        OBFS_HOST=""
    fi

    read -p "是否启用 TCP Fast Open [true/false, 默认 true]: " tfo
    TFO=${tfo:-true}
    ECN=true  # 固定开启

    # ===== 生成 Snell 配置文件 =====
    cat > "$CONF_DIR/snell.conf" <<EOF
[snell-server]
listen = $( [[ "$IPv6" == "true" ]] && echo "::0" || echo "0.0.0.0" ):$PORT
psk = $PSK
ipv6 = $IPv6
$( [[ "$OBFS" == "http" ]] && echo "obfs = http" && echo "obfs_host = $OBFS_HOST" )
EOF

    # ===== 生成 Docker Compose 文件 =====
    cat > "$COMPOSE_FILE" <<EOF
version: "3.8"
services:
  snell:
    image: accors/snell:latest
    container_name: $CONTAINER_NAME
    restart: always
    network_mode: host
    environment:
      - SNELL_URL=${SNELL_URL}
    volumes:
      - ./snell-conf/snell.conf:/etc/snell-server.conf
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    # ===== 输出客户端配置模板 =====
    IP=$(hostname -I | awk '{print $1}')
    HOSTNAME=$(hostname -s | sed 's/ /_/g')
    echo
    echo -e "${GREEN}✅ Snell 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问端口: ${PORT}${RESET}"
    echo -e "${YELLOW}🔑 PSK: ${PSK}${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    echo -e "${YELLOW}📄 客户端配置模板:${RESET}"
    echo -e "${YELLOW} $HOSTNAME = snell, ${IP}, ${PORT}, psk=${PSK}, version=5, tfo=${TFO}, ecn=${ECN}${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Snell 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart ${CONTAINER_NAME}
    echo -e "${GREEN}✅ Snell 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f ${CONTAINER_NAME}
}

check_status() {
    docker ps | grep ${CONTAINER_NAME}
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker stop ${CONTAINER_NAME}
    docker rm ${CONTAINER_NAME}
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Snell 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
