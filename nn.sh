#!/bin/bash
# ========================================
# Snell 一键管理脚本（Host 模式 + 去掉 DNS）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="SnellShadowTLS"
APP_DIR="/root/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONTAINER_NAME="SnellShadowTLS"

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

# ===== 检查端口，循环直到可用 =====
check_port_loop() {
    local port=$1
    while true; do
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            echo -e "${RED}端口 $port 已被占用，请重新输入！${RESET}"
            read -p "请输入新的端口: " port
        else
            echo $port
            return
        fi
    done
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
    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read -r confirm
        [[ "$confirm" != "y" ]] && return
    fi

    # ===== Snell 内部端口 =====
    read -p "请输入 Snell 内部端口 [20000-40000, 默认随机]: " input_port
    input_port=${input_port:-$(shuf -i 20000-40000 -n1)}
    PORT=$(check_port_loop "$input_port")

    # ===== ShadowTLS 对外端口 =====
    read -p "请输入 ShadowTLS 对外端口 [默认 8443]: " tls_input
    tls_input=${tls_input:-8443}
    TLS_PORT=$(check_port_loop "$tls_input")

    # ===== IPv6 开关 =====
    read -p "是否启用 IPv6 [true/false, 默认 false]: " ipv6
    IPv6=${ipv6:-false}

    # ===== Snell 密钥 =====
    read -s -p "请输入 Snell PSK（留空自动生成）: " input_psk; echo
    PSK=${input_psk:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c32)}

    # ===== ShadowTLS 密码 =====
    read -s -p "请输入 ShadowTLS 密码（留空自动生成）: " input_tls; echo
    TLS_PASSWORD=${input_tls:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c16)}

    # ===== TLS 伪装域名 =====
    read -p "请输入 TLS 伪装域名 [默认 captive.apple.com]: " tls_host
    TLS_HOST=${tls_host:-captive.apple.com}

    # ===== Snell 配置 =====
    CONF_FILE="$APP_DIR/snell-server.conf"
    cat > "$CONF_FILE" <<EOF
[snell-server]
listen = 0.0.0.0:$PORT
psk = $PSK
tfo = true
ecn = true
EOF

    [[ "$IPv6" == "true" ]] && echo "listen = [::]:$PORT" >> "$CONF_FILE"

    # ===== ShadowTLS SERVER 地址 =====
    if [[ "$IPv6" == "true" ]]; then
        SERVER_ADDR="[::1]:${PORT}"
        TLS_LISTEN="[::]:${TLS_PORT}"
    else
        SERVER_ADDR="127.0.0.1:${PORT}"
        TLS_LISTEN="0.0.0.0:${TLS_PORT}"
    fi

    # ===== 生成 Docker Compose =====
    cat > "$COMPOSE_FILE" <<EOF
services:
  snell:
    image: 1byte/snell-server:latest
    container_name: snell
    restart: always
    network_mode: host
    volumes:
      - ./snell-server.conf:/app/snell-server.conf:ro

  shadow-tls:
    image: ghcr.io/ihciah/shadow-tls:latest
    container_name: shadow-tls
    restart: unless-stopped
    network_mode: host
    environment:
      MODE: "server"
      V3: "1"
      LISTEN: "${TLS_LISTEN}"
      SERVER: "${SERVER_ADDR}"
      TLS: "${TLS_HOST}:443"
      PASSWORD: "${TLS_PASSWORD}"
EOF

    # ===== 启动容器 =====
    cd "$APP_DIR" || return
    docker compose up -d

    # ===== 输出客户端配置 =====
    IP=$(hostname -I | awk '{print $1}')
    HOSTNAME=$(hostname -s | sed 's/ /_/g')
    echo
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    echo -e "${GREEN}✅ Snell + ShadowTLS 已启动${RESET}"
    echo -e "${YELLOW}🌐 Snell 内部端口: $PORT${RESET}"
    echo -e "${YELLOW}🌐 ShadowTLS 对外端口: $TLS_PORT${RESET}"
    echo -e "${YELLOW}🔑 Snell PSK: $PSK${RESET}"
    echo -e "${YELLOW}🔑 ShadowTLS 密码: $TLS_PASSWORD${RESET}"
    echo -e "${YELLOW}🌐 SNI: $TLS_HOST${RESET}"
    echo
    echo -e "${GREEN}📄 V6VPS替换IP地址为V6⭐${RESET}"
    echo -e "${YELLOW}📄 客户端配置模板:${RESET}"
    echo -e "${YELLOW}$HOSTNAME = snell, ${IP}, ${TLS_PORT}, psk = ${PSK}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${TLS_PASSWORD}, shadow-tls-sni = ${TLS_HOST}, shadow-tls-version = 3${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Snell 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

# 重启两个容器
restart_app() {
    docker restart snell shadow-tls
    echo -e "${GREEN}✅ Snell + ShadowTLS 已重启${RESET}"
    read -p "按回车返回菜单..."
}

# 查看日志，先选择容器
view_logs() {
    echo -e "${YELLOW}1) Snell 日志${RESET}"
    echo -e "${YELLOW}2) ShadowTLS 日志${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) docker logs -f snell ;;
        2) docker logs -f shadow-tls ;;
        *) echo "取消" ;;
    esac
}

# 查看状态
check_status() {
    docker ps | grep -E "snell|shadow-tls"
    read -p "按回车返回菜单..."
}

# 卸载
uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down
    docker image prune -f
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Snell + ShadowTLS 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
