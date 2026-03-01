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

    # 当前值
    CURRENT_PORT=$(jq '.inbounds[0].port' "$CONFIG_FILE")
    CURRENT_DOMAIN=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$CONFIG_FILE" | cut -d: -f1)
    CURRENT_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_FILE")
    CURRENT_PRIVATE=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$CONFIG_FILE")
    CURRENT_SHORTID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$CONFIG_FILE")
    CURRENT_DNS=$(jq -r '.dns.servers | join(",")' "$CONFIG_FILE")

    # 用户输入
    read -p "监听端口 [$CURRENT_PORT]: " NEW_PORT
    NEW_PORT=${NEW_PORT:-$CURRENT_PORT}

    read -p "伪装域名 [$CURRENT_DOMAIN]: " NEW_DOMAIN
    NEW_DOMAIN=${NEW_DOMAIN:-$CURRENT_DOMAIN}

    read -p "是否重新生成 UUID？[y/N]: " regen_uuid
    if [[ "$regen_uuid" =~ ^[Yy]$ ]]; then
        NEW_UUID=$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)
    else
        NEW_UUID="$CURRENT_UUID"
    fi

    read -p "是否重新生成 Reality 密钥？[y/N]: " regen_key
    if [[ "$regen_key" =~ ^[Yy]$ ]]; then
        X25519=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519)
        NEW_PRIVATE_KEY=$(echo "$X25519" | grep "PrivateKey" | awk -F': ' '{print $2}')
        NEW_PUBLIC_KEY=$(echo "$X25519" | grep "PublicKey"  | awk -F': ' '{print $2}')
        NEW_SHORT_ID=$(openssl rand -hex 8)
    else
        NEW_PRIVATE_KEY="$CURRENT_PRIVATE"
        NEW_SHORT_ID="$CURRENT_SHORTID"
        # 用私钥反推公钥
        NEW_PUBLIC_KEY=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519 -i "$NEW_PRIVATE_KEY" 2>/dev/null | grep "PublicKey" | awk -F': ' '{print $2}')
    fi

    read -p "DNS（逗号分隔，留空不变） [$CURRENT_DNS]: " DNS_INPUT
    DNS_INPUT=${DNS_INPUT:-$CURRENT_DNS}
    IFS=',' read -ra DNS_ARRAY <<< "$DNS_INPUT"

    # 更新 JSON
    TMP_FILE=$(mktemp)
    jq \
        --arg port "$NEW_PORT" \
        --arg domain "$NEW_DOMAIN" \
        --arg uuid "$NEW_UUID" \
        --arg priv "$NEW_PRIVATE_KEY" \
        --arg sid "$NEW_SHORT_ID" \
        --argjson dns "$(printf '%s\n' "${DNS_ARRAY[@]}" | jq -R . | jq -s .)" \
        '
        .inbounds[0].port = ($port|tonumber) |
        .inbounds[0].settings.clients[0].id = $uuid |
        .inbounds[0].streamSettings.realitySettings.dest = "\($domain):443" |
        .inbounds[0].streamSettings.realitySettings.serverNames = [$domain] |
        .inbounds[0].streamSettings.realitySettings.privateKey = $priv |
        .inbounds[0].streamSettings.realitySettings.shortIds = [$sid] |
        .dns.servers = $dns
        ' "$CONFIG_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$CONFIG_FILE"

    # 修复权限，避免 permission denied
    chmod 644 "$CONFIG_FILE"
    chmod 755 "$APP_DIR"

    # 更新 compose 端口
    sed -i "s/^[[:space:]]*-[[:space:]]*[0-9]\+:[0-9]\+\/tcp/      - \"$NEW_PORT:$NEW_PORT\/tcp\"/" "$COMPOSE_FILE"

    cd "$APP_DIR" || return
    docker compose up -d --force-recreate

    # 获取公网 IP
    IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
    TAG=$(hostname -s)

    VLESS_LINK="vless://${NEW_UUID}@${IP}:${NEW_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${NEW_DOMAIN}&fp=chrome&pbk=${NEW_PUBLIC_KEY}&sid=${NEW_SHORT_ID}&type=tcp#${TAG}"

    echo
    echo -e "${GREEN}✅ 配置修改完成${RESET}"
    echo -e "${YELLOW}新连接如下：${RESET}"
    echo -e "${YELLOW}${VLESS_LINK}${RESET}"
    echo
    read -p "按回车返回菜单..."
}
menu
