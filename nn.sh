#!/bin/bash
# ========================================
# VMess-WS-TLS 一键管理脚本（Docker Host 模式，兼容 sing-box 最新版本）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="vmess-ws-tls"
APP_DIR="/root/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.json"
CONTAINER_NAME="vmess-ws-tls"

SERVER_IP=$(hostname -I | awk '{print $1}')

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
    if ss -tulnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

install_app() {
    check_docker
    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    # 端口
    read -p "请输入监听端口 [默认随机]: " input_port
    if [[ -z "$input_port" ]]; then
        PORT=$(shuf -i 1025-65535 -n1)
    else
        PORT=$input_port
    fi

    check_port "$PORT" || return

    # UUID
    UUID=$(cat /proc/sys/kernel/random/uuid)

    # WS Path
    read -p "请输入 WebSocket Path [默认 /ws]: " WS_PATH
    WS_PATH=${WS_PATH:-/ws}

    # SNI / TLS Server Name
    read -p "请输入 TLS SNI / 伪装域名 [例如 www.bing.com]: " SNI_HOST
    SNI_HOST=${SNI_HOST:-www.bing.com}

    # TLS 证书路径
    read -p "请输入 TLS 证书路径 (示例 /root/certs/server.crt): " CERT_PATH
    read -p "请输入 TLS 私钥路径 (示例 /root/certs/server.key): " KEY_PATH

    if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
        echo -e "${RED}证书文件或私钥文件不存在，请检查路径！${RESET}"
        return
    fi

    # 生成 sing-box VMess-WS-TLS 配置（最新版字段）
    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${SNI_HOST}",
          "certificates": [
            {
              "certificateFile": "${CERT_PATH}",
              "keyFile": "${KEY_PATH}"
            }
          ]
        },
        "wsSettings": {
          "path": "${WS_PATH}",
          "headers": {
            "Host": "${SNI_HOST}"
          }
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
EOF

    # 生成 Docker Compose
    cat > "$COMPOSE_FILE" <<EOF
services:
  vmess-ws-tls:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: ${CONTAINER_NAME}
    restart: always
    network_mode: host
    volumes:
      - ./config.json:/etc/vmess/config.json
      - ${CERT_PATH}:/etc/vmess/server.crt
      - ${KEY_PATH}:/etc/vmess/server.key
    command: run -c /etc/vmess/config.json
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    # 输出 Base64 VMess 链接
    VMESS_JSON=$(jq -n \
        --arg v "2" \
        --arg ps "$HOSTNAME" \
        --arg add "$SERVER_IP" \
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
        --arg insecure "1" \
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
            insecure: $insecure
        }' | base64 -w 0)

    echo
    echo -e "${GREEN}✅ VMess-WS-TLS 节点已启动${RESET}"
    echo -e "${YELLOW}🌐 公网 IP: ${SERVER_IP}${RESET}"
    echo -e "${YELLOW}🔌 端口: ${PORT}${RESET}"
    echo -e "${YELLOW}🆔 UUID: ${UUID}${RESET}"
    echo
    echo -e "${GREEN}📄 客户端 Base64 VMess 链接:${RESET}"
    echo -e "${YELLOW}vmess://${VMESS_JSON}${RESET}"
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
    echo -e "${GREEN}✅ 已重启${RESET}"
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
    docker stop ${CONTAINER_NAME}
    docker rm ${CONTAINER_NAME}
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== VMess-WS-TLS 管理菜单 ===${RESET}"
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

menu
