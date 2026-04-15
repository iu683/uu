#!/bin/bash
# ========================================
# Sing-box AnyReality 一键管理脚本
# 默认域名：www.amazon.com
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="Singbox-AnyReality"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.json"
CONTAINER_NAME="Singbox-AnyReality"
NODE_INFO_FILE="$APP_DIR/node.txt"

info() { echo -e "${GREEN}$1${RESET}"; }
warn() { echo -e "${YELLOW}$1${RESET}"; }
error() { echo -e "${RED}$1${RESET}"; }

rand_str() {
    tr -dc a-z0-9 </dev/urandom | head -c ${1:-8}
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        warn "未检测到 Docker，正在安装..."
        curl -fsSL https://get.docker.com | bash
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
        echo -e "${GREEN}==================================${RESET}"
        echo -e "${GREEN}     AnyReality 管理菜单            ${RESET}"
        echo -e "${GREEN}==================================${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看节点信息${RESET}"
        echo -e "${GREEN}6) 卸载${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install ;;
            2) update ;;
            3) restart ;;
            4) logs ;;
            5) show_node_info ;;
            6) uninstall ;;
            0) exit ;;
            *) error "无效选择"; sleep 1 ;;
        esac
    done
}

install() {
    check_docker
    mkdir -p "$APP_DIR"

    read -p "端口(默认随机): " PORT
    PORT=${PORT:-$(shuf -i 20000-60000 -n1)}

    USERNAME=$(rand_str 8)
    PASSWORD=$(rand_str 16)

    
    read -p "伪装域名(默认: www.amazon.com): " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-www.amazon.com}

    REMARK=$(hostname)
    SERVER_IP=$(get_public_ip)

    warn "生成 Reality 密钥..."
    KEY_PAIR=$(docker run --rm ghcr.io/sagernet/sing-box generate reality-keypair)

    PRIVATE_KEY=$(echo "$KEY_PAIR" | grep PrivateKey | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | grep PublicKey | awk '{print $2}')
    SHORT_ID=$(openssl rand -hex 4)

    cat > "$CONFIG_FILE" <<EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {
      "type": "anytls",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "${USERNAME}",
          "password": "${PASSWORD}"
        }
      ],
      "padding_scheme": [
        "stop=8",
        "0=30-30",
        "1=100-400",
        "2=400-500,c,500-1000,c,500-1000,c,500-1000",
        "3=9-9,500-1000",
        "4=500-1000",
        "5=500-1000",
        "6=500-1000",
        "7=500-1000"
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SERVER_NAME}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SERVER_NAME}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": "${SHORT_ID}"
        }
      }
    }
  ],
  "outbounds": [
    {"type": "direct"}
  ]
}
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  singbox:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: ${CONTAINER_NAME}
    network_mode: host
    restart: always
    volumes:
      - ./config.json:/etc/sing-box/config.json
    command: run -c /etc/sing-box/config.json
EOF

    cd "$APP_DIR"
    docker compose up -d

    cat > "$NODE_INFO_FILE" <<EOF
服务器 IP: ${SERVER_IP}
端口: ${PORT}
用户名: ${USERNAME}
密码: ${PASSWORD}
SNI: ${SERVER_NAME}
PublicKey: ${PUBLIC_KEY}
ShortID: ${SHORT_ID}
备注: ${REMARK}
EOF

    info "安装完成"
    show_node_info
}

show_node_info() {
  clear
  info '当前节点信息'

  if [ ! -f "$NODE_INFO_FILE" ]; then
      error "未找到节点信息"
      read
      return
  fi

  cat "$NODE_INFO_FILE"
  echo

  echo 'QuantumultX 配置：'
  echo "anytls=${SERVER_IP}:${PORT}, password=${PASSWORD}, over-tls=true, tls-host=${SERVER_NAME}, tls-verification=false, reality-base64-pubkey=${PUBLIC_KEY}, reality-hex-shortid=${SHORT_ID}, udp-relay=true, tag=${REMARK}"
  echo

  echo 'sing-box 客户端示例配置：'
  cat <<EOF
{
  "type": "anytls",
  "tag": "${REMARK}",
  "server": "${SERVER_IP}",
  "server_port": ${PORT},
  "password": "${PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${SERVER_NAME}",
    "reality": {
      "enabled": true,
      "public_key": "${PUBLIC_KEY}",
      "short_id": "${SHORT_ID}"
    }
  }
}
EOF

  echo
  read -p "按回车返回菜单..."
}

update() {
    cd "$APP_DIR"
    docker compose pull
    docker compose up -d
    info "更新完成"
    read -p "按回车返回菜单..."
}

restart() {
    docker restart ${CONTAINER_NAME}
    info "已重启"
    read -p "按回车返回菜单..."
}

logs() {
    docker logs -f ${CONTAINER_NAME}
}

uninstall() {
    docker rm -f ${CONTAINER_NAME}
    rm -rf "$APP_DIR"
    warn "已卸载"
    read -p "按回车返回菜单..."
}

menu
