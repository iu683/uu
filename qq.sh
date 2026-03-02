#!/bin/bash
# ========================================
# MailAggregator_Pro 一键管理脚本（宿主机目录绑定数据）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="mail-tool"
APP_DIR="/opt/$APP_NAME"
DATA_DIR="$APP_DIR/data"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONTAINER_NAME="mail-tool"
REPO_URL="https://github.com/gblaowang-i/MailAggregator_Pro.git"

random_string() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 32
}

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

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== MailAggregator_Pro 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载（保留数据）${RESET}"
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
    mkdir -p "$DATA_DIR"

    # 克隆或更新仓库
    if [ -d "$APP_DIR/.git" ]; then
        echo -e "${YELLOW}检测到已有仓库，执行 git pull 更新...${RESET}"
        cd "$APP_DIR" || exit
        git reset --hard
        git pull
    else
        echo -e "${GREEN}克隆仓库到 $APP_DIR ...${RESET}"
        git clone "$REPO_URL" "$APP_DIR"
    fi

    read -p "请输入访问端口 [默认:8000]: " input_port
    PORT=${input_port:-8000}
    check_port "$PORT" || return

    read -p "请输入后台用户名 [默认:admin]: " username
    ADMIN_USERNAME=${username:-admin}
    read -s -p "请输入后台密码 [默认:123456]: " password
    ADMIN_PASSWORD=${password:-123456}
    echo

    JWT_SECRET=$(random_string)
    ENCRYPTION_KEY=$(random_string)

    # 写 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  app:
    build: .
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:8000"
    environment:
      - DATABASE_URL=sqlite+aiosqlite:///./data/mail_agg.db
      - TZ=Asia/Shanghai
      - ENCRYPTION_KEY=${ENCRYPTION_KEY}
      - ADMIN_USERNAME=${ADMIN_USERNAME}
      - ADMIN_PASSWORD=${ADMIN_PASSWORD}
      - JWT_SECRET=${JWT_SECRET}
      - API_TOKEN=
      - TELEGRAM_BOT_TOKEN=
      - TELEGRAM_CHAT_ID=
      - WEBHOOK_URL=
    volumes:
      - ${DATA_DIR}:/app/data
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d --build

    echo
    echo -e "${GREEN}✅ MailAggregator_Pro 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🔑 用户名: ${ADMIN_USERNAME}  密码: ${ADMIN_PASSWORD}${RESET}"
    echo -e "${GREEN}📂 数据目录（持久化）: $DATA_DIR${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    git reset --hard
    git pull
    docker compose build
    docker compose up -d
    echo -e "${GREEN}✅ MailAggregator_Pro 更新完成（数据保留）${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart ${CONTAINER_NAME}
    echo -e "${GREEN}✅ MailAggregator_Pro 已重启${RESET}"
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
    rm -rf "$APP_DIR"           # 删除安装目录和数据
    echo -e "${RED}✅ MailAggregator_Pro 已卸载（包含数据）${RESET}"
    read -p "按回车返回菜单..."
}
menu
