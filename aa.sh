#!/bin/bash
# ========================================
# Xray VLESS HTTPUpgrade 一键管理脚本（无TLS + 自定义Host）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

CONTAINER_NAME="xray-vless"
APP_NAME="xray-vless-httpupgrade"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.json"
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
        echo -e "${GREEN}=== Xray VLESS + HTTPUpgrade 管理菜单 ===${RESET}"
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

    read -p "请输入端口 [默认随机]: " input_port
    if [[ -z "$input_port" ]]; then
        PORT=$(shuf -i 1025-65535 -n1)
    else
        PORT=$input_port
    fi

    check_port "$PORT" || return

    read -p "请输入服务器IP或域名: " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}不能为空${RESET}"
        return
    fi

    read -p "请输入 HTTP Host (可留空): " HTTP_HOST

    read -p "请输入 HTTPUpgrade Path [默认 /]: " HTTP_PATH
    HTTP_PATH=${HTTP_PATH:-/}

    UUID=$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)

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
            "id": "$UUID"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "httpupgrade",
        "security": "none",
        "httpupgradeSettings": {
          "path": "$HTTP_PATH",
          "host": "$HTTP_HOST"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

cat > "$COMPOSE_FILE" <<EOF
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    command: ["run","-c","/etc/xray/config.json"]
    volumes:
      - ./config.json:/etc/xray/config.json:ro
    ports:
      - "$PORT:$PORT/tcp"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    VLESS_LINK="vless://${UUID}@${DOMAIN}:${PORT}?encryption=none&security=none&type=httpupgrade&host=${HTTP_HOST}&path=${HTTP_PATH}#${HOSTNAME}"

    echo
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    echo -e "${GREEN}✅ VLESS + HTTPUpgrade 节点已启动${RESET}"
    echo -e "${YELLOW}🌐 地址: ${DOMAIN}${RESET}"
    echo -e "${YELLOW}🔌 端口: ${PORT}${RESET}"
    echo -e "${YELLOW}🆔 UUID: ${UUID}${RESET}"
    echo -e "${YELLOW}🌐 Host: ${HTTP_HOST}${RESET}"
    echo -e "${YELLOW}📂 Path: ${HTTP_PATH}${RESET}"
    echo

    echo -e "${YELLOW}📄 VLESS链接:${RESET}"
    echo -e "${YELLOW}${VLESS_LINK}${RESET}"
    echo

    echo -e "${YELLOW}📄 Surge配置:${RESET}"
    echo -e "${YELLOW}${HOSTNAME} = vless, ${DOMAIN}, ${PORT}, username=${UUID}, http-upgrade=true, http-upgrade-path=${HTTP_PATH}, http-upgrade-headers=Host:\"${HTTP_HOST}\", tls=false${RESET}"

cat > "$NODE_INFO_FILE" <<EOF
VLESS链接
${VLESS_LINK}

Surge配置
${HOSTNAME} = vless, ${DOMAIN}, ${PORT}, username=${UUID}, http-upgrade=true, http-upgrade-path=${HTTP_PATH}, http-upgrade-headers=Host:"${HTTP_HOST}", tls=false
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
    docker restart ${CONTAINER_NAME}
    echo -e "${GREEN}✅ ${CONTAINER_NAME} 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f ${CONTAINER_NAME}
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

menu
