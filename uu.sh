#!/bin/bash
# ========================================
# TUIC v5 一键管理脚本（Host模式 + 自签Bing证书）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="singbox-TUICv5"
APP_DIR="/root/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.json"
CONTAINER_NAME="singbox-TUICv5"

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
    if ss -tulnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

SERVER_IP=$(hostname -I | awk '{print $1}')

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== singbox-TUICv5 管理菜单 ===${RESET}"
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
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    # 端口
    read -p "请输入监听端口 [默认随机]: " input_port
    if [[ -z "$input_port" ]]; then
        PORT=$(shuf -i 1025-65535 -n1)
    else
        PORT=$input_port
    fi

    check_port "$PORT" || return

    # 生成 UUID 和 密码
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c8)

    echo -e "${YELLOW}正在生成自签证书用于 TUIC v5 ...${RESET}"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$APP_DIR/server.key" \
        -out "$APP_DIR/server.crt" \
        -days 36500 \
        -subj "/CN=www.bing.com" \
        -addext "subjectAltName=DNS:www.bing.com" >/dev/null 2>&1

    # 生成 TUIC v5 配置（正确字段 uuid）
    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "tuic",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "password": "${PASSWORD}"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "server_name": "www.bing.com",
        "certificate_path": "/etc/tuic/server.crt",
        "key_path": "/etc/tuic/server.key"
      }
    }
  ],
  "outbounds": [
    { "type": "direct" }
  ]
}
EOF

    # Docker Compose
    cat > "$COMPOSE_FILE" <<EOF
services:
  tuic-server:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: ${CONTAINER_NAME}
    restart: always
    network_mode: host
    volumes:
      - ./config.json:/etc/tuic/config.json
      - ./server.crt:/etc/tuic/server.crt
      - ./server.key:/etc/tuic/server.key
    command: run -c /etc/tuic/config.json
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    echo
    echo -e "${GREEN}📂 安装目录: $APP_DIR⭐${RESET}"
    echo -e "${GREEN}✅ singbox-TUICv5 节点已启动⭐${RESET}"
    echo -e "${YELLOW}🌐 公网 IP: ${SERVER_IP}${RESET}"
    echo -e "${YELLOW}🔌 端口: ${PORT}${RESET}"
    echo -e "${YELLOW}🆔 UUID: ${UUID}${RESET}"
    echo -e "${YELLOW}🔑 密码: ${PASSWORD}${RESET}"
    echo -e "${YELLOW}📄 V6VPS替换IP地址为V6⭐${RESET}"
    echo
    echo -e "${GREEN}📄 客户端链接:${RESET}"
    echo -e "${YELLOW}tuic://${UUID}:${PASSWORD}@${SERVER_IP}:${PORT}?congestion_control=bbr&alpn=h3&sni=www.bing.com&udp_relay_mode=native&allow_insecure=1#${HOSTNAME}${RESET}"
    echo
    read -p "按回车返回菜单..."
}
update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ singbox-TUICv5 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart ${CONTAINER_NAME}
    echo -e "${GREEN}✅ singbox-TUICv5 已重启${RESET}"
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
    docker stop ${CONTAINER_NAME}
    docker rm ${CONTAINER_NAME}
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ singbox-TUICv5 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
