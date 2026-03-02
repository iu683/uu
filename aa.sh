#!/bin/bash
# ========================================
# Xray VMess WS TLS 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

CONTAINER_NAME="xray-server"
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

check_port() {
    if ss -lnt | awk '{print $4}' | grep -q ":$1$"; then
        echo -e "${RED}端口 $1 已被占用${RESET}"
        return 1
    fi
    return 0
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

    CONFIG_FILE="$APP_DIR/config.json"
    COMPOSE_FILE="$APP_DIR/docker-compose.yml"

    # ===== 端口 =====
    read -p "请输入监听端口 [默认随机]: " input_port
    if [[ -z "$input_port" ]]; then
        PORT=$(shuf -i 1025-65535 -n1)
    else
        PORT=$input_port
    fi

    check_port "$PORT" || return

    # ===== 域名 =====
    read -p "请输入真实域名（必须已解析到本机IP）: " DOMAIN
    [[ -z "$DOMAIN" ]] && echo "域名不能为空" && return

    # ===== WS Path =====
    read -p "请输入 WebSocket Path [默认 /ws]: " WS_PATH
    WS_PATH=${WS_PATH:-/ws}

    # ===== SNI =====
    read -p "请输入 TLS SNI / 伪装域名 [默认 $DOMAIN]: " SNI_HOST
    SNI_HOST=${SNI_HOST:-$DOMAIN}

    # ===== UUID =====
    UUID=$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)

    # ===== TLS 证书 =====
    read -p "请输入 TLS 证书目录（留空自动生成自签证书）: " CERT_DIR

    if [[ -z "$CERT_DIR" ]]; then
        CERT_DIR="$APP_DIR/cert"
        mkdir -p "$CERT_DIR"
        echo "正在生成自签 TLS 证书..."

        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout "$CERT_DIR/private.key" \
            -out "$CERT_DIR/cert.crt" \
            -subj "/CN=$DOMAIN" -days 3650

        chmod 644 "$CERT_DIR/private.key" "$CERT_DIR/cert.crt"

        CERT_FILE="cert.crt"
        KEY_FILE="private.key"
        SELF_SIGNED="yes"

    else

        if [[ -f "$CERT_DIR/fullchain.pem" && -f "$CERT_DIR/privkey.pem" ]]; then
            echo "检测到 Let's Encrypt 证书"
            CERT_FILE="fullchain.pem"
            KEY_FILE="privkey.pem"
            SELF_SIGNED="no"

        elif [[ -f "$CERT_DIR/cert.crt" && -f "$CERT_DIR/private.key" ]]; then
            echo "检测到 cert.crt 证书"
            CERT_FILE="cert.crt"
            KEY_FILE="private.key"
            SELF_SIGNED="no"

        else
            echo "未找到有效证书文件"
            echo "需要以下任意一组："
            echo "  - fullchain.pem + privkey.pem"
            echo "  - cert.crt + private.key"
            return
        fi

        chmod 644 "$CERT_DIR/$KEY_FILE" "$CERT_DIR/$CERT_FILE"
    fi

    # ===== 生成 Xray 配置 =====
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
          "serverName": "$SNI_HOST",
          "certificates": [
            {
              "certificateFile": "/etc/xray/cert/${CERT_FILE}",
              "keyFile": "/etc/xray/cert/${KEY_FILE}"
            }
          ],
          "alpn": ["h2","http/1.1"],
          "fingerprint": "chrome"
        },
        "wsSettings": {
          "path": "$WS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

    # ===== 生成 docker-compose.yml =====
    cat > "$COMPOSE_FILE" <<EOF
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray-server
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

    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    # ===== 生成 VMess 链接 =====
    VMESS_JSON=$(jq -n \
        --arg v "2" \
        --arg ps "$HOSTNAME" \
        --arg add "$DOMAIN" \
        --arg port "$PORT" \
        --arg id "$UUID" \
        --arg aid "0" \
        --arg net "ws" \
        --arg type "none" \
        --arg host "$SNI_HOST" \
        --arg path "$WS_PATH" \
        --arg tls "tls" \
        --arg sni "$SNI_HOST" \
        --arg fp "chrome" \
        '{
            v: $v,
            ps: $ps,
            add: $add,
            port: $port,
            id: $id,
            aid: $aid,
            net: $net,
            type: $type,
            host: $host,
            path: $path,
            tls: $tls,
            sni: $sni,
            alpn: ["h2","http/1.1"],
            fp: $fp,
        }' | base64 -w 0)

    echo
    echo "✅ VMess-WS-TLS 节点已启动"
    echo "🌐 域名: $DOMAIN"
    echo "🔌 端口: $PORT"
    echo "🆔 UUID: $UUID"

    if [[ "$SELF_SIGNED" == "yes" ]]; then
        echo "⚠ 当前使用自签证书，客户端需要开启“跳过证书验证”"
    else
        echo "🔒 使用正规证书，无需跳过证书验证"
    fi

    echo
    echo "📄 VMess 链接:"
    echo -e "${YELLOW}vmess://${VMESS_JSON}${RESET}"
    echo "📄 Surge 链接:"
    echo -e "${YELLOW}$HOSTNAME = vmess, ${DOMAIN}, ${PORT}, username=${UUID}, ws=true, ws-path=$WS_PATH, ws-headers=Host:"${DOMAIN}", vmess-aead=true, tls=true, sni=${DOMAIN}${RESET}"
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
    docker restart ${CONTAINER_NAME}
    echo -e "${GREEN}✅ ${CONTAINER_NAME} 已重启${RESET}"
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
    cd "$APP_DIR" || return
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

# 启动菜单
menu
