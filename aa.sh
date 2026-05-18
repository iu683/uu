#!/bin/bash
# ========================================
# Let Bot 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="let-bot"
APP_DIR="/opt/$APP_NAME"

COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

check_docker() {

    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2${RESET}"
        exit 1
    fi
}

check_port() {

    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用${RESET}"
        return 1
    fi
}

menu() {

    while true; do

        clear
        echo -e "${GREEN}=====Let Bot 管理菜单=====${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
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

    mkdir -p "$APP_DIR/data"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入后台访问端口 [默认:2918]: " input_port
    ADMIN_PORT=${input_port:-2918}

    check_port "$ADMIN_PORT" || return

    read -p "请输入后台用户名 [默认:admin]: " input_user
    ADMIN_USERNAME=${input_user:-admin}

    read -p "请输入后台密码 [默认:admin123]: " input_pass
    ADMIN_PASSWORD=${input_pass:-admin123}

    read -p "请输入 AI_BASE_URL [默认:https://api.siliconflow.cn/v1]: " input_ai_url
    AI_BASE_URL=${input_ai_url:-https://api.siliconflow.cn/v1}

    read -p "请输入 AI_MODEL [默认:Qwen/Qwen2.5-7B-Instruct]: " input_ai_model
    AI_MODEL=${input_ai_model:-Qwen/Qwen2.5-7B-Instruct}

    cat > "$ENV_FILE" <<EOF
TZ=Asia/Shanghai

AI_BASE_URL=${AI_BASE_URL}

AI_MODEL=${AI_MODEL}

AI_MODEL_FALLBACKS=Qwen/Qwen3-8B

AI_TIMEOUT=45

AI_MAX_RETRIES=0

AI_CONTENT_LIMIT=8000

SCAN_INTERVAL_MIN=90

SCAN_INTERVAL_MAX=180

BLOCKED_SLEEP_SECONDS=1800

TG_PARSE_MODE=MarkdownV2

TG_DISABLE_WEB_PREVIEW=true

ADMIN_USERNAME=${ADMIN_USERNAME}

ADMIN_PASSWORD=${ADMIN_PASSWORD}

ADMIN_HOST=127.0.0.1

ADMIN_PORT=${ADMIN_PORT}
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  let_bot:
    image: tyer199/let_bot:v3.16
    container_name: let_bot_engine

    restart: always

    environment:
      TZ: \${TZ:-UTC}

      AI_BASE_URL: \${AI_BASE_URL:-https://api.siliconflow.cn/v1}

      AI_MODEL: \${AI_MODEL:-Qwen/Qwen2.5-7B-Instruct}

      AI_MODEL_FALLBACKS: \${AI_MODEL_FALLBACKS:-Qwen/Qwen3-8B}

      AI_TIMEOUT: \${AI_TIMEOUT:-45}

      AI_MAX_RETRIES: \${AI_MAX_RETRIES:-0}

      AI_CONTENT_LIMIT: \${AI_CONTENT_LIMIT:-8000}

      SCAN_INTERVAL_MIN: \${SCAN_INTERVAL_MIN:-90}

      SCAN_INTERVAL_MAX: \${SCAN_INTERVAL_MAX:-180}

      BLOCKED_SLEEP_SECONDS: \${BLOCKED_SLEEP_SECONDS:-1800}

      TG_PARSE_MODE: \${TG_PARSE_MODE:-MarkdownV2}

      TG_DISABLE_WEB_PREVIEW: \${TG_DISABLE_WEB_PREVIEW:-true}

    volumes:
      - ./data:/app/data

    logging:
      driver: json-file

      options:
        max-size: "10m"
        max-file: "3"

  let_admin:
    image: tyer199/let_bot:v3.16
    container_name: let_bot_admin

    restart: always

    command:
      ["python", "-m", "uvicorn", "admin_app:app", "--host", "0.0.0.0", "--port", "2918"]

    environment:
      TZ: \${TZ:-UTC}

      ADMIN_USERNAME: \${ADMIN_USERNAME:-}

      ADMIN_PASSWORD: \${ADMIN_PASSWORD:-}

    volumes:
      - ./data:/app/data

    ports:
      - "\${ADMIN_HOST:-127.0.0.1}:\${ADMIN_PORT:-2918}:2918"
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ Let Bot 安装完成${RESET}"

    echo -e "${YELLOW}🌐 后台地址: http://127.0.0.1:${ADMIN_PORT}${RESET}"

    echo -e "${YELLOW}👤 后台用户名: ${ADMIN_USERNAME}${RESET}"

    echo -e "${YELLOW}🔐 后台密码: ${ADMIN_PASSWORD}${RESET}"

    echo -e "${YELLOW}🤖 AI_MODEL: ${AI_MODEL}${RESET}"

    echo -e "${YELLOW}📂 数据目录: $APP_DIR/data${RESET}"


    read -p "按回车返回菜单..."
}

update_app() {

    cd "$APP_DIR" || return

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ Let Bot 更新完成${RESET}"

    read -p "按回车返回菜单..."
}

restart_app() {

    docker restart let_bot_engine
    docker restart let_bot_admin

    echo -e "${GREEN}✅ Let Bot 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f let_bot_engine
}

check_status() {

    docker ps --filter "name=let_bot"

    read -p "按回车返回菜单..."
}

uninstall_app() {


    cd "$APP_DIR" || return

    docker compose down -v

    rm -rf "$APP_DIR"

    echo -e "${RED}✅ Let Bot 已彻底卸载${RESET}"

    read -p "按回车返回菜单..."
}

menu
