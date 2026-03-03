#!/bin/bash
# ========================================
# Snell + ShadowTLS  一键管理脚本（Host 模式 + 去掉 DNS）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="Snell + ShadowTLS "
APP_DIR="/root/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONTAINER_NAME="snell-server"

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
        echo -e "${GREEN}=== Snell + ShadowTLS  管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR/data"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi
    
    # ===== IPv6 选择 =====
    read -p "是否启用 IPv6 [true/false, 默认 false]: " ipv6
    IPv6=${ipv6:-false}

    if [[ "$IPv6" == "true" ]]; then
        SNELL_IPV6="true"
        TLS_LISTEN="[::]:${TLS_PORT}"
        TLS_SERVER="[::1]:${PORT}"
    else
        SNELL_IPV6="false"
        TLS_LISTEN="0.0.0.0:${TLS_PORT}"
        TLS_SERVER="127.0.0.1:${PORT}"
    fi
    # ===== Snell 内部端口（仅本地监听）=====
    read -p "请输入 Snell 内部端口 [20000-40000, 默认随机]: " input_port

    if [[ -z "$input_port" ]]; then
        PORT=$(shuf -i 20000-40000 -n1)
    else
        PORT=$input_port
    fi

    check_port "$PORT" || return

    # ===== ShadowTLS 对外端口 =====
    read -p "请输入 ShadowTLS 对外端口 [默认 443]: " tls_input
    TLS_PORT=${tls_input:-443}
    check_port "$TLS_PORT" || return

    # ===== 随机生成密钥 =====
    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c32)
    TLS_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c16)

    # ===== 伪装域名 =====
    read -p "请输入 TLS 伪装域名 [默认 captive.apple.com]: " tls_host
    TLS_HOST=${tls_host:-captive.apple.com}

    # ===== 生成 docker-compose =====
    cat > "$COMPOSE_FILE" <<EOF
services:

  snell:
    image: 1byte/snell-server:latest
    container_name: snell
    restart: always
    network_mode: host
    environment:
      PORT: "${PORT}"
      PSK: "${PSK}"
      IPv6: "${SNELL_IPV6}"
      OBFS: "off"
      TFO: "true"
      ECN: "true"

  shadow-tls:
    image: ghcr.io/ihciah/shadow-tls:latest
    container_name: shadow-tls
    restart: unless-stopped
    network_mode: host
    environment:
      MODE: server
      V3: 1
      LISTEN: "${TLS_LISTEN}"
      SERVER: "${TLS_SERVER}"
      TLS: "${TLS_HOST}:443"
      PASSWORD: "${TLS_PASSWORD}"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    # ===== 获取公网IP =====
    IP=$(hostname -I | awk '{print $1}')
    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    echo
    echo -e "${GREEN}✅ Snell + ShadowTLS 已启动${RESET}"
    echo -e "${YELLOW}🌐 公网IP: ${IP}${RESET}"
    echo -e "${YELLOW}🌐 TLS端口: ${TLS_PORT}${RESET}"
    echo -e "${YELLOW}🔑 Snell PSK: ${PSK}${RESET}"
    echo -e "${YELLOW}🔑 ShadowTLS 密码: ${TLS_PASSWORD}${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    echo -e "${GREEN}📄 V6VPS替换IP地址为V6⭐${RESET}"

    echo -e "${GREEN}====== 客户端配置示例 ======${RESET}"
    echo -e "${YELLOW}ShadowTLS:${RESET}"
    echo -e " 地址: ${IP}"
    echo -e " 端口: ${TLS_PORT}"
    echo -e " 密码: ${TLS_PASSWORD}"
    echo -e " SNI: ${TLS_HOST}"
    echo -e "${YELLOW}Snell:${RESET}"
    echo -e "${YELLOW}$HOSTNAME = snell, ${IP}, ${TLS_PORT}, psk = ${PSK}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${TLS_PASSWORD}, shadow-tls-sni = ${TLS_HOST}, shadow-tls-version = 3${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Snell + ShadowTLS 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    cd "$APP_DIR" || return
    docker compose restart
    echo -e "${GREEN}✅ Snell + ShadowTLS 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    cd "$APP_DIR" || return
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker compose logs -f
}

check_status() {
    cd "$APP_DIR" || return
    docker compose ps
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Snell + ShadowTLS  已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
