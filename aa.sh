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
        echo -e "${GREEN}6) 修改配置${RESET}"
        echo -e "${GREEN}7) 卸载${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) modify_config ;;
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

    read -p "请输入 DNS（逗号分隔，默认 8.8.8.8,1.1.1.1）: " DNS_INPUT
    DNS_INPUT=${DNS_INPUT:-8.8.8.8,1.1.1.1}

    # 转换为 JSON 数组格式
    IFS=',' read -ra DNS_ARRAY <<< "$DNS_INPUT"

    DNS_SERVERS="["
    for dns in "${DNS_ARRAY[@]}"; do
        DNS_SERVERS+="\"${dns}\","
    done
    DNS_SERVERS="${DNS_SERVERS%,}]"

    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "dns": {
    "servers": $DNS_SERVERS
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

    cat > "$COMPOSE_FILE" <<EOF
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray
    restart: unless-stopped
    command: ["run","-c","/etc/xray/config.json"]
    volumes:
      - ./config.json:/etc/xray/config.json:ro
    ports:
      - "$PORT:$PORT/tcp"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    IP=$(hostname -I | awk '{print $1}')
    TAG=$(hostname -s)

    VLESS_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${TAG}"

    echo
    echo -e "${GREEN}✅ 安装完成${RESET}"
    echo -e "${YELLOW}${VLESS_LINK}${RESET}"
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

modify_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}未检测到配置文件，请先安装${RESET}"
        sleep 2
        return
    fi

    echo -e "${YELLOW}=== 修改配置 ===${RESET}"

    # 读取当前配置
    CURRENT_PORT=$(grep '"port"' "$CONFIG_FILE" | head -1 | awk -F': ' '{print $2}' | tr -d ',')
    CURRENT_DOMAIN=$(grep '"dest"' "$CONFIG_FILE" | awk -F'"' '{print $4}' | cut -d':' -f1)

    read -p "监听端口 [$CURRENT_PORT]: " NEW_PORT
    NEW_PORT=${NEW_PORT:-$CURRENT_PORT}

    read -p "伪装域名 [$CURRENT_DOMAIN]: " NEW_DOMAIN
    NEW_DOMAIN=${NEW_DOMAIN:-$CURRENT_DOMAIN}

    read -p "是否重新生成 UUID？[y/N]: " regen_uuid
    if [[ "$regen_uuid" =~ ^[Yy]$ ]]; then
        NEW_UUID=$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)
    else
        NEW_UUID=$(grep '"id"' "$CONFIG_FILE" | awk -F'"' '{print $4}')
    fi

    read -p "是否重新生成 Reality 密钥？[y/N]: " regen_key
    if [[ "$regen_key" =~ ^[Yy]$ ]]; then
        X25519=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519)
        NEW_PRIVATE_KEY=$(echo "$X25519" | grep "PrivateKey" | awk -F': ' '{print $2}')
        NEW_PUBLIC_KEY=$(echo "$X25519"  | grep "Password"   | awk -F': ' '{print $2}')
        NEW_SHORT_ID=$(openssl rand -hex 8)
    else
        NEW_PRIVATE_KEY=$(grep '"privateKey"' "$CONFIG_FILE" | awk -F'"' '{print $4}')
        NEW_PUBLIC_KEY="保持原值"
        NEW_SHORT_ID=$(grep '"shortIds"' -A1 "$CONFIG_FILE" | tail -1 | awk -F'"' '{print $2}')
    fi

    read -p "DNS（逗号分隔，留空不变）: " DNS_INPUT
    if [[ -n "$DNS_INPUT" ]]; then
        IFS=',' read -ra DNS_ARRAY <<< "$DNS_INPUT"
        DNS_SERVERS="["
        for dns in "${DNS_ARRAY[@]}"; do
            DNS_SERVERS+="\"${dns}\","
        done
        DNS_SERVERS="${DNS_SERVERS%,}]"
    else
        DNS_SERVERS=$(grep '"servers"' -A1 "$CONFIG_FILE" | tail -1)
    fi

    # 重新写配置
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "dns": {
    "servers": $DNS_SERVERS
  },
  "inbounds": [
    {
      "port": $NEW_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$NEW_UUID",
            "flow": "xtls-rprx-vision",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$NEW_DOMAIN:443",
          "xver": 0,
          "serverNames": ["$NEW_DOMAIN"],
          "privateKey": "$NEW_PRIVATE_KEY",
          "shortIds": ["$NEW_SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
EOF

    # 更新 compose 端口映射
    sed -i "s/[0-9]\+:[0-9]\+\/tcp/$NEW_PORT:$NEW_PORT\/tcp/g" "$COMPOSE_FILE"

    cd "$APP_DIR" || return
    docker compose up -d --force-recreate

    IP=$(hostname -I | awk '{print $1}')
    TAG=$(hostname -s)

    if [[ "$NEW_PUBLIC_KEY" != "保持原值" ]]; then
        PBK="$NEW_PUBLIC_KEY"
    else
        PBK=$(grep "pbk=" <<< "$(docker logs xray 2>/dev/null)")
    fi

    echo
    echo -e "${GREEN}✅ 配置修改完成${RESET}"
    echo -e "${YELLOW}新端口: $NEW_PORT${RESET}"
    echo -e "${YELLOW}新域名: $NEW_DOMAIN${RESET}"

    read -p "按回车返回菜单..."
}

menu
