#!/bin/bash
# ========================================
# Sing-box AnyReality 管理
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
安装目录: ${APP_DIR}
V6VPS替换IP地址为V6
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

  # 读取信息
  SERVER_IP=$(grep "服务器 IP" $NODE_INFO_FILE | awk '{print $3}')
  PORT=$(grep "端口" $NODE_INFO_FILE | awk '{print $2}')
  PASSWORD=$(grep "密码" $NODE_INFO_FILE | awk '{print $2}')
  SERVER_NAME=$(grep "SNI" $NODE_INFO_FILE | awk '{print $2}')
  PUBLIC_KEY=$(grep "PublicKey" $NODE_INFO_FILE | awk '{print $2}')
  SHORT_ID=$(grep "ShortID" $NODE_INFO_FILE | awk '{print $2}')
  REMARK=$(grep "备注" $NODE_INFO_FILE | awk '{print $2}')

  cat "$NODE_INFO_FILE"
  echo

  echo 'v2rayN配置：'
  echo "anytls://${PASSWORD}@${SERVER_IP}:${PORT}?security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${REMARK}"
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
