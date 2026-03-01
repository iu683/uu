#!/bin/bash
# ========================================
# Xray Reality 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="xray-reality"
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

generate_keys() {
    UUID=$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)
    read -p "是否自动生成 Reality 密钥对？[Y/n]: " keygen
    keygen=${keygen:-Y}
    if [[ "$keygen" =~ ^[Yy]$ ]]; then
        X25519=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519)
        PRIVATE_KEY=$(echo "$X25519" | awk 'NR==1{print $1}')
        PUBLIC_KEY=$(echo "$X25519" | awk 'NR==2{print $1}')
    else
        read -p "请输入 PrivateKey: " PRIVATE_KEY
        read -p "请输入 PublicKey: " PUBLIC_KEY
    fi
    SHORT_ID=$(openssl rand -hex 8)
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Xray Reality 管理菜单 ===${RESET}"
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

    # 端口设置
    read -p "请输入监听端口 [443 默认]: " PORT
    PORT=${PORT:-443}

    # 域名设置，默认 itunes.apple.com
    read -p "请输入域名 (用于 Reality serverNames, 默认 itunes.apple.com): " DOMAIN
    DOMAIN=${DOMAIN:-itunes.apple.com}

    # 自动生成 UUID、Reality 密钥和 shortId
    UUID=$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)
    
    # -------------------------------
# 生成 X25519 密钥对（修复 pbk 问题）
X25519=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519)
PRIVATE_KEY=$(echo "$X25519" | grep "Private key" | awk '{print $3}')
PUBLIC_KEY=$(echo "$X25519" | grep "Public key"  | awk '{print $3}')

# shortId
SHORT_ID=$(openssl rand -hex 8)

# DNS 默认 8.8.8.8,1.1.1.1
read -p "请输入 DNS（默认 8.8.8.8,1.1.1.1）: " DNS
DNS=${DNS:-8.8.8.8,1.1.1.1}

# 生成 config.json
cat > "$CONFIG_FILE" <<EOF
{
  "log": { "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log", "loglevel": "warning" },
  "dns": {
    "servers": ["$DNS"]
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "level": 0,
            "email": "user@example.com",
            "realitySettings": {
              "privateKey": "$PRIVATE_KEY",
              "shortIds": ["$SHORT_ID"]
            }
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DOMAIN:$PORT",
          "xver": 0,
          "serverNames": ["$DOMAIN"],
          "privateKey": "$PRIVATE_KEY",
          "publicKey": "$PUBLIC_KEY"
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom","settings":{}}]
}
EOF

    # 生成 Docker Compose
    cat > "$COMPOSE_FILE" <<EOF
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray
    restart: unless-stopped
    command: ["run", "-c", "/usr/local/etc/xray/config.json"]
    volumes:
      - ./config.json:/usr/local/etc/xray/config.json:ro
    ports:
      - "$PORT:$PORT/tcp"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    # 生成可用 VLESS Reality 链接
    IP=$(hostname -I | awk '{print $1}')
    TAG=HOSTNAME=$(hostname -s | sed 's/ /_/g')
    VLESS_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${TAG}"

    echo
    echo -e "${GREEN}✅ Xray Reality 已启动${RESET}"
    echo -e "${YELLOW}VLESS Reality 链接:${RESET}"
    echo -e "${YELLOW}${VLESS_LINK}${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Xray Reality 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart xray
    echo -e "${GREEN}✅ Xray Reality 已重启${RESET}"
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
    echo -e "${RED}✅ Xray Reality 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
