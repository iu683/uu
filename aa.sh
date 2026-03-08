#!/bin/bash
# ========================================
# Xray Reality 一键管理脚本 (Host 模式 + Xray-Reality 容器名)
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
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。" && return
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Xray-Reality 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
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
    if [[ -z "$PORT" ]]; then
        PORT=$(random_port)
        echo -e "已自动生成未占用端口: ${PORT}"
    fi

    read -p "请输入伪装域名 [默认 itunes.apple.com]: " DOMAIN
    DOMAIN=${DOMAIN:-itunes.apple.com}

    UUID=$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)
    X25519=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519)
    PRIVATE_KEY=$(echo "$X25519" | grep "PrivateKey" | awk -F': ' '{print $2}')
    PUBLIC_KEY=$(echo "$X25519"  | grep "Password"   | awk -F': ' '{print $2}')

    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        echo -e "${RED}密钥生成失败${RESET}"
        return
    fi

    SHORT_ID=$(openssl rand -hex 8)

    # 生成配置文件（去掉 DNS）
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
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
            "flow": "xtls-rprx-vision",
            "level": 0,
            "email": "user@example.com"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DOMAIN:443",
          "xver": 0,
          "serverNames": ["$DOMAIN"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
EOF

    # 生成 compose 文件 (host 模式)
    cat > "$COMPOSE_FILE" <<EOF
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: Xray-Reality
    restart: unless-stopped
    network_mode: host
    command: ["run","-c","/etc/xray/config.json"]
    volumes:
      - ./config.json:/etc/xray/config.json:ro
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    IP=$(get_public_ip)
    TAG=$(hostname -s)

    VLESS_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${TAG}"
  
    echo
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    echo -e "${GREEN}---Xray VLESS-Reality 订阅信息---${RESET}"
    echo -e "${YELLOW}名称: ${TAG}${RESET}"
    echo -e "${YELLOW}地址: ${IP}${RESET}"
    echo -e "${YELLOW}端口: ${PORT}${RESET}"
    echo -e "${YELLOW}UUID: ${UUID}${RESET}"
    echo -e "${YELLOW}流控: xtls-rprx-vision${RESET}"
    echo -e "${YELLOW}指纹: chrome${RESET}"
    echo -e "${YELLOW}SNI: ${DOMAIN}${RESET}"
    echo -e "${YELLOW}公钥: ${PUBLIC_KEY}${RESET}"
    echo -e "${YELLOW}ShortId: ${SHORT_ID}${RESET}"
    echo
    echo -e "${YELLOW}📄 V6VPS替换IP地址为V6 ★${RESET}"
    echo -e "${YELLOW}✅ 订阅链接${RESET}"
    echo -e "${YELLOW}${VLESS_LINK}${RESET}"
    cat > "$NODE_INFO_FILE" <<EOF
Xray VLESS-Reality 订阅信息
名称 ${TAG}
地址 ${IP}
端口 ${PORT}
UUID ${UUID}
流控 xtls-rprx-vision
指纹 chrome
SNI ${DOMAIN}
公钥 ${PUBLIC_KEY}
ShortId ${SHORT_ID}
订阅链接
${VLESS_LINK}
EOF
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Xray-Reality 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart Xray-Reality
    echo -e "${GREEN}✅ Xray-Reality 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f Xray-Reality
}

view_node_info() {

    if [ ! -f "$NODE_INFO_FILE" ]; then
        echo -e "${RED}未找到节点信息${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    echo
    echo -e "${GREEN}=== 节点信息 ===${RESET}"
    echo
    cat "$NODE_INFO_FILE"
    echo
    read -p "按回车返回菜单..."
}

check_status() {
    docker ps | grep Xray-Reality
    read -p "按回车返回菜单..."
}

uninstall_app() {
    docker stop Xray-Reality
    docker rm Xray-Reality
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Xray-Reality 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
