#!/bin/bash
# ========================================
# Xray Reality 一键管理脚本 (Host 模式 + xHTTP 协议)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="xray-reality"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.json"
CONTAINER_NAME="Xray-Reality"
NODE_INFO_FILE="$APP_DIR/node.txt"

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

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP"
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Xray-Reality (xHTTP) 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新镜像${RESET}"
        echo -e "${GREEN}3) 重启容器${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 查看节点信息${RESET}"
        echo -e "${GREEN}7) 卸载${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) view_node_info ;;
            7) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {
    check_docker
    mkdir -p "$APP_DIR"

    random_port() {
        while :; do
            PORT=$(shuf -i 2000-65000 -n 1)
            ss -lnt | awk '{print $4}' | grep -q ":$PORT$" || break
        done
        echo "$PORT"
    }

    read -p "请输入监听端口 [默认随机]: " PORT
    [[ -z "$PORT" ]] && PORT=$(random_port)
    echo -e "使用端口: ${PORT}"

    read -p "请输入伪装域名 [默认 learn.microsoft.com]: " DOMAIN
    DOMAIN=${DOMAIN:-learn.microsoft.com}

    # 获取密钥
    X25519=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519)
    PRIVATE_KEY=$(echo "$X25519" | grep "PrivateKey" | awk -F': ' '{print $2}' | tr -d '[:space:]')
    PUBLIC_KEY=$(echo "$X25519" | grep "PublicKey" | awk -F': ' '{print $2}' | tr -d '[:space:]')
    UUID=$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)
    SHORT_ID=$(openssl rand -hex 8)
    XHTTP_PATH="/$(openssl rand -hex 4)"

    # 生成配置文件 (xHTTP 模式)
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DOMAIN:443",
          "xver": 0,
          "serverNames": ["$DOMAIN"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        },
        "xhttpSettings": {
          "path": "$XHTTP_PATH",
          "mode": "auto"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

    # 生成 compose 文件
    cat > "$COMPOSE_FILE" <<EOF
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    network_mode: host
    command: ["run","-c","/etc/xray/config.json"]
    volumes:
      - ./config.json:/etc/xray/config.json:ro
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    IP=$(get_public_ip)
    TAG="$(hostname -s)-xHTTP"
    ENCODED_PATH=$(echo -n "$XHTTP_PATH" | sed 's/\//%2F/g')

    VLESS_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${ENCODED_PATH}&mode=auto#${TAG}"

    echo -e "${GREEN}--- Xray VLESS-Reality-xHTTP 订阅信息 ---${RESET}"
    echo -e "${YELLOW}名称: ${TAG}${RESET}"
    echo -e "${YELLOW}地址: ${IP}${RESET}"
    echo -e "${YELLOW}端口: ${PORT}${RESET}"
    echo -e "${YELLOW}UUID: ${UUID}${RESET}"
    echo -e "${YELLOW}协议: xHTTP (Reality)${RESET}"
    echo -e "${YELLOW}路径: ${XHTTP_PATH}${RESET}"
    echo -e "${YELLOW}SNI:  ${DOMAIN}${RESET}"
    echo -e "${YELLOW}公钥: ${PUBLIC_KEY}${RESET}"
    echo -e "${YELLOW}ShortId: ${SHORT_ID}${RESET}"
    echo "----------------------------------------------------------------"
    echo -e "${GREEN}订阅链接:${RESET}"
    echo -e "${CYAN}${VLESS_LINK}${RESET}"

    cat > "$NODE_INFO_FILE" <<EOF
Xray VLESS-Reality-xHTTP 订阅信息
名称: ${TAG}
地址: ${IP}
端口: ${PORT}
UUID: ${UUID}
传输协议: xHTTP
路径: ${XHTTP_PATH}
SNI: ${DOMAIN}
公钥: ${PUBLIC_KEY}
ShortId: ${SHORT_ID}
订阅链接:
${VLESS_LINK}
EOF
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
    docker restart $CONTAINER_NAME
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f $CONTAINER_NAME
}

view_node_info() {
    if [ ! -f "$NODE_INFO_FILE" ]; then
        echo -e "${RED}未找到节点信息${RESET}"
    else
        cat "$NODE_INFO_FILE"
    fi
    read -p "按回车返回菜单..."
}

check_status() {
    docker ps -a --filter "name=$CONTAINER_NAME"
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" 2>/dev/null && docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已卸载并清除数据${RESET}"
    read -p "按回车返回菜单..."
}

menu
