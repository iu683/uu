#!/bin/bash
# ========================================
# Xray Socks5 企业版管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="xray-socks5"
APP_DIR="/root/$APP_NAME"
COMPOSE_FILE="$APP_DIR/compose.yml"
CONFIG_FILE="$APP_DIR/config.json"

# ========================================
# Docker 检测
# ========================================
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

# ========================================
# 随机端口
# ========================================
random_port() {
    while :; do
        PORT=$(shuf -i 2000-65000 -n 1)
        ss -lnt | awk '{print $4}' | grep -q ":$PORT$" || break
    done
    echo "$PORT"
}

# ========================================
# 主菜单
# ========================================
menu() {
    while true; do
        clear
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}      Xray Socks5 管理面板      ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        echo
        read -p "$(echo -e ${GREEN}请选择操作:${RESET}) " choice

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

# ========================================
# 安装
# ========================================
install_app() {
    check_docker
    mkdir -p "$APP_DIR"

    read -p "请输入监听端口 [默认随机]: " PORT
    if [[ -z "$PORT" ]]; then
        PORT=$(random_port)
        echo -e "${YELLOW}已自动生成端口: $PORT${RESET}"
    fi

    # 生成随机用户名函数
    random_username() {
        tr -dc a-z0-9 </dev/urandom | head -c6
    }

    # 提示用户输入，默认随机用户名
    read -p "请输入用户名 [默认随机生成]: " USERNAME
    USERNAME=${USERNAME:-$(random_username)}

    echo "使用的用户名: $USERNAME"

    read -p "请输入 Socks5 密码 [默认随机]: " PASSWORD
    if [[ -z "$PASSWORD" ]]; then
        PASSWORD=$(openssl rand -base64 8)
        echo -e "${YELLOW}已自动生成密码: $PASSWORD${RESET}"
    fi

    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          { "user": "$USERNAME", "pass": "$PASSWORD" }
        ],
        "udp": true
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray-socks5
    restart: unless-stopped
    command: ["run","-c","/etc/xray/config.json"]
    volumes:
      - ./config.json:/etc/xray/config.json:ro
    ports:
      - "$PORT:$PORT/tcp"
      - "$PORT:$PORT/udp"
EOF

    cd "$APP_DIR" || return
    docker compose up -d

    IP=$(hostname -I | awk '{print $1}')

    SOCKS_LINK="socks://${USERNAME}:${PASSWORD}@${IP}:${PORT}"
    TG_LINK="https://t.me/socks?server=${IP}&port=${PORT}&user=${USERNAME}&pass=${PASSWORD}"

    echo
    echo -e "${GREEN}✅ Socks5 安装完成${RESET}"
    echo
    echo -e "${YELLOW}Socks 地址:${RESET}"
    echo -e "${GREEN}${SOCKS_LINK}${RESET}"
    echo
    echo -e "${YELLOW}Telegram 快链:${RESET}"
    echo -e "${GREEN}${TG_LINK}${RESET}"
    echo

    read -p "按回车返回菜单..."
}

# ========================================
# 更新
# ========================================
update_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}未安装 Socks5${RESET}"
        sleep 1
        return
    fi

    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Socks5 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

# ========================================
# 重启
# ========================================
restart_app() {
    if docker ps -a | grep -q xray-socks5; then
        docker restart xray-socks5
        echo -e "${GREEN}✅ Socks5 已重启${RESET}"
    else
        echo -e "${RED}容器不存在${RESET}"
    fi
    read -p "按回车返回菜单..."
}

# ========================================
# 查看日志
# ========================================
view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f xray-socks5
}

# ========================================
# 查看状态
# ========================================
check_status() {
    docker ps -a | grep xray-socks5 || echo -e "${RED}未运行${RESET}"
    read -p "按回车返回菜单..."
}

# ========================================
# 卸载
# ========================================
uninstall_app() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" || return
        docker compose down
        rm -rf "$APP_DIR"
        echo -e "${RED}✅ Socks5 已卸载${RESET}"
    else
        echo -e "${RED}未安装${RESET}"
    fi
    read -p "按回车返回菜单..."
}

menu
