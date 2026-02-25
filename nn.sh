#!/bin/bash
# ========================================
# CLIProxyAPI 一键管理脚本
# 支持自定义端口 + API Key
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

APP_NAME="cliproxyapi"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.yaml"

REPO_URL="https://github.com/luispater/CLIProxyAPI.git"

# ==============================
# 基础检测
# ==============================

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
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

generate_key() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 32
}


# 获取服务器IP
SERVER_IP=$(hostname -I | awk '{print $1}')


# ==============================
# 菜单
# ==============================

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== CLIProxyAPI 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

# ==============================
# 功能函数
# ==============================

install_app() {

    check_docker

    if ! command -v git &>/dev/null; then
        echo -e "${YELLOW}未检测到 git，正在安装...${RESET}"
        apt install -y git 2>/dev/null || yum install -y git
    fi

    if [ -d "$APP_DIR" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
        rm -rf "$APP_DIR"
    fi

    mkdir -p "$APP_DIR"
    cd /opt || exit

    echo -e "${BLUE}正在克隆项目...${RESET}"
    git clone "$REPO_URL" "$APP_NAME"

    cd "$APP_DIR" || exit

    read -p "$(echo -e ${GREEN}请输入监听端口 [默认:8317]: ${RESET})" input_port
    PORT=${input_port:-8317}
    check_port "$PORT" || return

    read -p "$(echo -e ${GREEN}请输入 API Key [留空自动生成]: ${RESET})" input_key
    if [ -z "$input_key" ]; then
        API_KEY=$(generate_key)
        echo -e "${BLUE}自动生成 API Key: ${API_KEY}${RESET}"
    else
        API_KEY="$input_key"
    fi

    read -p "$(echo -e ${GREEN}请输入 WebUI 管理密钥 [留空自动生成]: ${RESET})" input_mgt
    if [ -z "$input_mgt" ]; then
        MGT_KEY=$(generate_key)
        echo -e "${BLUE}自动生成 WebUI 管理密钥: ${MGT_KEY}${RESET}"
    else
        MGT_KEY="$input_mgt"
    fi

    # 写入 config.yaml（含 WebUI）
    cat > "$CONFIG_FILE" <<EOF
port: ${PORT}

auth-dir: "~/.cli-proxy-api"

request-retry: 3

quota-exceeded:
  switch-project: true
  switch-preview-model: true

api-keys:
  - "${API_KEY}"

remote-management:
  allow-remote: true
  secret-key: "${MGT_KEY}"
  disable-control-panel: false
EOF

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  cliproxyapi:
    image: ghcr.io/luispater/cliproxyapi:latest
    container_name: cliproxyapi
    restart: unless-stopped
    ports:
      - "${PORT}:${PORT}"
    volumes:
      - ./config.yaml:/app/config.yaml
EOF

    echo -e "${BLUE}正在启动容器...${RESET}"
    docker compose up -d

    echo
    echo -e "${GREEN}✅ CLIProxyAPI 启动成功！${RESET}"
    show_info
    read -p "按回车继续..."
}

update_app() {
    cd "$APP_DIR" || { echo "未安装"; sleep 1; return; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ CLIProxyAPI 更新完成${RESET}"
    sleep 1
}

restart_app() {
    cd "$APP_DIR" || { echo "未安装"; sleep 1; return; }
    docker compose restart
    echo -e "${GREEN}✅ CLIProxyAPI 已重启${RESET}"
    sleep 1
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker compose logs -f
}

check_status() {
    docker ps | grep cliproxyapi
    read -p "按回车返回..."
}

show_info() {
    if [ -f "$CONFIG_FILE" ]; then
        PORT=$(grep "^port:" "$CONFIG_FILE" | awk '{print $2}')
        API_KEY=$(grep -A1 "api-keys:" "$CONFIG_FILE" | tail -n1 | sed 's/- //' | tr -d '"')
        MGT_KEY=$(grep "secret-key:" "$CONFIG_FILE" | awk '{print $2}' | tr -d '"')

        echo
        echo -e "${GREEN}📌 访问信息:${RESET}"
        echo -e "${BLUE}WebUI地址: http://${SERVER_IP}:${PORT}/management.html${RESET}"
        echo -e "${BLUE}API Key: ${API_KEY}${RESET}"
        echo -e "${BLUE}WebUI 管理密钥: ${MGT_KEY}${RESET}"
        echo -e "${GREEN}安装目录: $APP_DIR${RESET}"
        echo
    else
        echo -e "${RED}未安装${RESET}"
    fi
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未安装"; sleep 1; return; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ CLIProxyAPI 已彻底卸载（含数据）${RESET}"
    sleep 1
}

menu
