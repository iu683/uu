#!/bin/bash
# ========================================
# Xray VMess WS TLS 多节点管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="xray-vmess-ws-tls"
APP_DIR="/opt/$APP_NAME"

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

random_port() {
    while :; do
        PORT=$(shuf -i 2000-65000 -n1)
        ss -lntu | grep -q ":$PORT " || break
    done
    echo "$PORT"
}

list_nodes() {
    mkdir -p "$APP_DIR"
    echo -e "${GREEN}=== 已有 VMess 节点 ===${RESET}"
    local count=0
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        count=$((count+1))
        echo -e "${YELLOW}[$count] $(basename "$node")${RESET}"
    done
    [ $count -eq 0 ] && echo -e "${YELLOW}无节点${RESET}"
}

select_node() {
    list_nodes
    read -r -p $'\033[32m请输入节点名称或编号: \033[0m' input
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        NODE_NAME=$(ls -d "$APP_DIR"/* | sed -n "${input}p" | xargs basename)
    else
        NODE_NAME="$input"
    fi
    NODE_DIR="$APP_DIR/$NODE_NAME"
    if [ ! -d "$NODE_DIR" ]; then
        echo -e "${RED}节点不存在！${RESET}"
        return 1
    fi
}

install_node() {
    check_docker

    read -p "请输入节点名称 [node$(date +%s)]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-node$(date +%s)}
    NODE_DIR="$APP_DIR/$NODE_NAME"
    mkdir -p "$NODE_DIR"

    # 端口
    read -p "请输入监听端口 [默认随机]: " input_port
    if [[ -z "$input_port" ]]; then
        PORT=$(shuf -i 1025-65535 -n1)
    else
        PORT=$input_port
    fi

    check_port "$PORT" || return

    # 域名
    read -p "请输入真实域名（必须已解析到本机IP）: " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}域名不能为空${RESET}"
        return
    fi

    # WebSocket Path
    read -p "请输入 WebSocket Path [默认 /ws]: " WS_PATH
    WS_PATH=${WS_PATH:-/ws}

    # TLS SNI / 伪装域名
    read -p "请输入 TLS SNI / 伪装域名 [默认 $DOMAIN]: " SNI_HOST
    SNI_HOST=${SNI_HOST:-$DOMAIN}

    # UUID
    UUID=$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)

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
        chmod 644 "$CERT_DIR/private.key" "$CERT_DIR/cert.crt"
    else
        if [[ ! -f "$CERT_DIR/cert.crt" || ! -f "$CERT_DIR/private.key" ]]; then
            echo -e "${RED}目录下未找到 cert.crt 或 private.key${RESET}"
            return
        fi
        chmod 644 "$CERT_DIR/private.key" "$CERT_DIR/cert.crt"
    fi

    # 生成 config.json
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
              "certificateFile": "/etc/xray/cert/cert.crt",
              "keyFile": "/etc/xray/cert/private.key"
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

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
 $NODE_NAME:
    image: ghcr.io/xtls/xray-core:latest
    container_name: $NODE_NAME
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
    # 输出 Base64 VMess 链接（使用 jq 构造 JSON）
    VMESS_JSON=$(jq -n \
        --arg v "2" \
        --arg ps "$NODE_NAME" \
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
        --arg alpn "h2,http/1.1" \
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
            alpn: $alpn,
            fp: $fp,
        }' | base64 -w 0)

    echo
    echo -e "${GREEN}✅ VMess-WS-TLS 节点已启动${RESET}"
    echo -e "${YELLOW}🌐 公网域名: ${DOMAIN}${RESET}"
    echo -e "${YELLOW}🔌 端口: ${PORT}${RESET}"
    echo -e "${YELLOW}🆔 UUID: ${UUID}${RESET}"
    echo -e "${YELLOW}自签证书需要客户端设置跳过证书${RESET}"
    echo
    echo "📄 V2rayN链接:"
    echo -e "${YELLOW}vmess://${VMESS_JSON}${RESET}"
    echo "📄  Surge 链接:"
    echo -e "${YELLOW}$HOSTNAME = vmess, ${DOMAIN}, ${PORT}, username=${UUID}, ws=true, ws-path=$WS_PATH, ws-headers=Host:"${DOMAIN}", vmess-aead=true, tls=true, sni=${DOMAIN}${RESET}"
    read -p "按回车返回菜单..."
}


node_action_menu() {
    select_node || return
    while true; do
        echo -e "${GREEN}=== 节点 [$NODE_NAME] 管理 ===${RESET}"
        echo -e "${GREEN}1) 暂停${RESET}"
        echo -e "${GREEN}2) 重启${RESET}"
        echo -e "${GREEN}3) 更新${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 卸载${RESET}"
        echo -e "${GREEN}0) 返回主菜单${RESET}"
        read -r -p $'\033[32m请选择操作: \033[0m' choice
        case $choice in
            1) docker pause "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose -f "$NODE_DIR/compose.yml" pull && docker compose -f "$NODE_DIR/compose.yml" up -d ;;
            4) docker logs -f "$NODE_NAME" ;;
            5) docker compose -f "$NODE_DIR/compose.yml" down && rm -rf "$NODE_DIR" && return ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" ;;
        esac
    done
}

show_all_status() {
    list_nodes
    echo -e "${GREEN}=== 节点状态 ===${RESET}"
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        NODE_NAME=$(basename "$node")
        PORT=$(grep '"port"' "$node/config.json" | head -n1 | awk -F': ' '{print $2}' | tr -d ',')
        STATUS=$(docker inspect -f '{{.State.Status}}' "$NODE_NAME" 2>/dev/null)
        case "$STATUS" in
            running) STATUS_COLOR="${GREEN}运行中${RESET}" ;;
            paused)  STATUS_COLOR="${YELLOW}已暂停${RESET}" ;;
            *)       STATUS_COLOR="${RED}未启动${RESET}" ;;
        esac
        echo -e "${GREEN}$NODE_NAME${RESET} | 端口: ${YELLOW}$PORT${RESET} | 状态: $STATUS_COLOR"
    done
    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

batch_action() {
    echo -e "${GREEN}=== 批量操作 ===${RESET}"
    echo -e "${GREEN}1) 暂停节点${RESET}"
    echo -e "${GREEN}2) 重启节点${RESET}"
    echo -e "${GREEN}3) 更新节点${RESET}"
    echo -e "${GREEN}4) 卸载节点${RESET}"
    echo -e "${GREEN}0) 返回主菜单${RESET}"
    read -r -p $'\033[32m请选择操作: \033[0m' choice

    mkdir -p "$APP_DIR"
    declare -A NODE_MAP
    local count=0
    for node in "$APP_DIR"/*; do
        [ -d "$node" ] || continue
        count=$((count+1))
        NODE_NAME=$(basename "$node")
        NODE_MAP[$count]="$NODE_NAME"
        echo -e "${YELLOW}[$count] $NODE_NAME${RESET}"
    done

    [ $count -eq 0 ] && { echo -e "${YELLOW}无节点${RESET}"; read -r -p $'\033[32m按回车返回菜单...\033[0m'; return; }

    read -r -p $'\033[32m请输入节点序号（空格分隔，或输入 all）: \033[0m' input_nodes

    if [[ "$input_nodes" == "all" ]]; then
        SELECTED_NODES=("${NODE_MAP[@]}")
    else
        SELECTED_NODES=()
        for i in $input_nodes; do
            NODE=${NODE_MAP[$i]}
            [ -n "$NODE" ] && SELECTED_NODES+=("$NODE")
        done
    fi

    for NODE_NAME in "${SELECTED_NODES[@]}"; do
        NODE_DIR="$APP_DIR/$NODE_NAME"
        cd "$NODE_DIR" || continue
        case $choice in
            1) docker pause "$NODE_NAME" ;;
            2) docker restart "$NODE_NAME" ;;
            3) docker compose pull && docker compose up -d ;;
            4) docker compose down && rm -rf "$NODE_DIR" ;;
            0) return ;;
        esac
        echo -e "${GREEN}✅ 节点 $NODE_NAME 操作完成${RESET}"
    done

    read -r -p $'\033[32m按回车返回菜单...\033[0m'
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Xray VMess WS TLS 多节点管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动新节点${RESET}"
        echo -e "${GREEN}2) 管理已有节点${RESET}"
        echo -e "${GREEN}3) 查看所有节点状态${RESET}"
        echo -e "${GREEN}4) 批量操作节点${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -r -p $'\033[32m请选择操作: \033[0m' choice
        case $choice in
            1) install_node ;;
            2) node_action_menu ;;
            3) show_all_status ;;
            4) batch_action ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

menu
