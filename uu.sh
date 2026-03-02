#!/bin/bash
# ========================================
# Xray VMess WS TLS 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="xray-vmess-ws-tls"
APP_DIR="/root/$APP_NAME"
COMPOSE_FILE="$APP_DIR/compose.yml"
CONFIG_FILE="$APP_DIR/config.json"

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

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Xray VMess WS TLS 管理菜单 ===${RESET}"
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

    read -p "请输入监听端口 [默认 443]: " PORT
    PORT=${PORT:-443}

    read -p "请输入域名（必须已解析到本机IP）: " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}域名不能为空${RESET}"
        return
    fi

    UUID=$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)
    WSPATH="/$(openssl rand -hex 6)"

    # TLS 证书
    read -p "请输入 TLS 证书目录（留空自动生成自签证书）: " CERT_DIR
    if [[ -z "$CERT_DIR" ]]; then
        CERT_DIR="$APP_DIR/cert"
        mkdir -p "$CERT_DIR"
        echo -e "${YELLOW}正在生成自签 TLS 证书...${RESET}"
        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout "$CERT_DIR/private.key" \
            -out "$CERT_DIR/cert.crt" \
            -subj "/CN=$DOMAIN" -days 3650
    else
        if [[ ! -f "$CERT_DIR/cert.crt" || ! -f "$CERT_DIR/private.key" ]]; then
            echo -e "${RED}目录下未找到 cert.crt 或 private.key${RESET}"
            return
        fi
    fi

    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vmess",
      "settings": {
        "clients": [
          { "id": "$UUID", "alterId": 0 }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/etc/xray/cert/cert.crt",
              "keyFile": "/etc/xray/cert/private.key"
            }
          ]
        },
        "wsSettings": {
          "path": "$WSPATH"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray
    restart: unless-stopped
    command: ["run","-c","/etc/xray/config.json"]
    volumes:
      - ./config.json:/etc/xray/config.json:ro
      - $CERT_DIR:/etc/xray/cert:ro
    ports:
      - "$PORT:$PORT/tcp"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    VMESS_JSON=$(cat <<EOL
{
  "v": "2",
  "ps": "vmess-ws-tls",
  "add": "$DOMAIN",
  "port": "$PORT",
  "id": "$UUID",
  "aid": "0",
  "net": "ws",
  "type": "none",
  "host": "",
  "path": "$WSPATH",
  "tls": "tls"
}
EOL
)

    VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"

    echo
    echo -e "${GREEN}✅ 安装完成${RESET}"
    echo -e "${YELLOW}UUID: $UUID${RESET}"
    echo -e "${YELLOW}WS Path: $WSPATH${RESET}"
    echo -e "${YELLOW}${VMESS_LINK}${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart xray
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f xray
}

check_status() {
    docker ps | grep xray
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
