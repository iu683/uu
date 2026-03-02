#!/bin/bash
# ========================================
# Hysteria 一键管理脚本（Host Docker + 自签证书 tls: + 端口跳跃 + 必应伪装）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="hysteria"
APP_DIR="/root/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/hysteria.yaml"
CONTAINER_NAME="hysteria"

# 端口跳跃变量
JUMP_START=""
JUMP_END=""
PORT=""
MASQ_URL="https://bing.com"

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
    if ss -tuln | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

generate_cert() {
    mkdir -p "$APP_DIR/cert"
    CERT_FILE="$APP_DIR/cert/server.crt"
    KEY_FILE="$APP_DIR/cert/server.key"
    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        echo -e "${YELLOW}正在生成自签证书（CN=bing.com）...${RESET}"
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "$KEY_FILE" \
            -out "$CERT_FILE" \
            -subj "/CN=bing.com" \
            -days 36500
    fi
}

add_port_jump_rules() {
    if [[ -n "$JUMP_START" ]] && [[ -n "$JUMP_END" ]]; then
        echo -e "${YELLOW}添加端口跳跃规则: $JUMP_START-$JUMP_END -> $PORT${RESET}"
        for p in $(seq $JUMP_START $JUMP_END); do
            iptables -t nat -A PREROUTING -i eth0 -p udp --dport $p -j REDIRECT --to-ports $PORT
            ip6tables -t nat -A PREROUTING -i eth0 -p udp --dport $p -j REDIRECT --to-ports $PORT
        done
    fi
}

remove_port_jump_rules() {
    if [[ -n "$JUMP_START" ]] && [[ -n "$JUMP_END" ]]; then
        echo -e "${YELLOW}清理端口跳跃规则: $JUMP_START-$JUMP_END -> $PORT${RESET}"
        for p in $(seq $JUMP_START $JUMP_END); do
            iptables -t nat -D PREROUTING -i eth0 -p udp --dport $p -j REDIRECT --to-ports $PORT 2>/dev/null
            ip6tables -t nat -D PREROUTING -i eth0 -p udp --dport $p -j REDIRECT --to-ports $PORT 2>/dev/null
        done
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Hysteria 管理菜单 ===${RESET}"
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

    # 端口自定义 / 随机
    read -p "请输入监听端口 [1025-65535, 默认随机]: " input_port
    if [[ -z "$input_port" ]]; then
        PORT=$(shuf -i 1025-65535 -n1)
    else
        PORT=$input_port
    fi
    check_port "$PORT" || return

    PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c16)

    # 端口跳跃
    read -p "是否启用端口跳跃（客户端可通过多个端口连接）[y/N]: " enable_jump
    if [[ "$enable_jump" =~ ^[Yy]$ ]]; then
        read -p "请输入端口范围（示例 20000-50000）: " jump_range
        JUMP_START=$(echo $jump_range | cut -d- -f1)
        JUMP_END=$(echo $jump_range | cut -d- -f2)
    fi

    generate_cert
    add_port_jump_rules

    # 生成 hysteria.yaml (Hysteria 2 tls: 版本)
    cat > "$CONFIG_FILE" <<EOF
listen: :$PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: $MASQ_URL
    rewriteHost: true
EOF

    # docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  hysteria:
    image: tobyxdd/hysteria
    container_name: $CONTAINER_NAME
    restart: always
    network_mode: host
    volumes:
      - $APP_DIR/hysteria.yaml:/etc/hysteria.yaml
      - $APP_DIR/cert/server.crt:/etc/hysteria/server.crt
      - $APP_DIR/cert/server.key:/etc/hysteria/server.key
    command: ["server", "-c", "/etc/hysteria.yaml"]
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    IP=$(hostname -I | awk '{print $1}')
    echo
    echo -e "${GREEN}✅ Hysteria 已启动${RESET}"
    echo -e "${YELLOW}🌐 服务端监听端口: ${PORT}${RESET}"
    echo -e "${YELLOW}🔑 密码: ${PASSWORD}${RESET}"
    if [[ -n "$JUMP_START" ]]; then
        echo -e "${YELLOW}🟢 端口跳跃: $JUMP_START-$JUMP_END -> $PORT${RESET}"
    else
        echo -e "${YELLOW}🟢 端口跳跃: 未启用${RESET}"
    fi
    echo -e "${YELLOW}🟢 伪装网址: $MASQ_URL${RESET}"
    echo -e "${YELLOW}📄 客户端配置模板:${RESET}"
    echo -e "${YELLOW}hysteria2://$PASSWORD@$IP:$PORT/?sni=bing.com&insecure=1#hy2${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Hysteria 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart $CONTAINER_NAME
    echo -e "${GREEN}✅ Hysteria 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f $CONTAINER_NAME
}

check_status() {
    docker ps | grep $CONTAINER_NAME
    read -p "按回车返回菜单..."
}

uninstall_app() {
    remove_port_jump_rules
    cd "$APP_DIR" || return
    docker stop $CONTAINER_NAME
    docker rm $CONTAINER_NAME
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Hysteria 已卸载并清理端口跳跃规则${RESET}"
    read -p "按回车返回菜单..."
}

menu
