#!/bin/bash
# ========================================
# Huobao Drama API 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="huobao-drama"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_DIR="$APP_DIR/configs"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
DATA_DIR="$APP_DIR/data"

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
        echo -e "${GREEN}=== Huobao Drama 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR" "$CONFIG_DIR" "$DATA_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
        rm -rf "$APP_DIR"
        mkdir -p "$APP_DIR" "$CONFIG_DIR" "$DATA_DIR"
    fi

    read -p "设置容器访问端口 [默认:5679]: " input_port
    PORT=${input_port:-5679}
    check_port "$PORT" || return

    read -p "配置 CORS 允许来源（逗号分隔）[默认:http://localhost:3013]: " input_cors
    CORS=${input_cors:-http://localhost:3013}

    read -p "设置应用名称 [默认:Huobao Drama API]: " input_name
    APP_DEFAULT_NAME=${input_name:-Huobao Drama API}

    read -p "设置版本号 [默认:1.0.0]: " input_version
    VERSION=${input_version:-1.0.0}

    read -p "是否开启调试模式 debug [true/false，默认:true]: " input_debug
    DEBUG=${input_debug:-true}

    read -p "选择数据库类型 [sqlite/postgres，默认:sqlite]: " input_db_type
    DB_TYPE=${input_db_type:-sqlite}

    if [ "$DB_TYPE" = "sqlite" ]; then
        read -p "设置 SQLite 文件路径 [默认:./data/huobao_drama.db]: " input_db_path
        DB_PATH=${input_db_path:-./data/huobao_drama.db}
    else
        read -p "请输入数据库连接字符串 (如 postgres://user:pass@host:port/db): " DB_PATH
    fi

    read -p "存储方式 [local/s3，默认:local]: " input_storage
    STORAGE_TYPE=${input_storage:-local}

    if [ "$STORAGE_TYPE" = "local" ]; then
        read -p "本地存储路径 [默认:./data/storage]: " input_storage_path
        STORAGE_PATH=${input_storage_path:-./data/storage}
        read -p "文件 Base URL [默认:http://localhost:${PORT}/static]: " input_base_url
        BASE_URL=${input_base_url:-http://localhost:${PORT}/static}
    else
        STORAGE_PATH=""
        read -p "请填写 S3 / 其他存储配置（暂未自动生成，需手动编辑 configs/config.yaml）"
    fi

    read -p "默认文本 AI 提供商 [默认:openai]: " input_text_ai
    TEXT_AI=${input_text_ai:-openai}
    read -p "默认图像 AI 提供商 [默认:openai]: " input_image_ai
    IMAGE_AI=${input_image_ai:-openai}
    read -p "默认视频 AI 提供商 [默认:doubao]: " input_video_ai
    VIDEO_AI=${input_video_ai:-doubao}

    cat > "$CONFIG_FILE" <<EOF
app:
  name: "${APP_DEFAULT_NAME}"
  version: "${VERSION}"
  debug: ${DEBUG}

server:
  port: ${PORT}
  host: "0.0.0.0"
  cors_origins:
EOF

    IFS=',' read -ra CORS_ARRAY <<< "$CORS"
    for origin in "${CORS_ARRAY[@]}"; do
        echo "    - \"$(echo "$origin" | xargs)\"" >> "$CONFIG_FILE"
    done

    cat >> "$CONFIG_FILE" <<EOF

database:
  type: "${DB_TYPE}"
EOF

    if [ "$DB_TYPE" = "sqlite" ]; then
        echo "  path: \"${DB_PATH}\"" >> "$CONFIG_FILE"
    else
        echo "  url: \"${DB_PATH}\"" >> "$CONFIG_FILE"
    fi

    cat >> "$CONFIG_FILE" <<EOF

storage:
  type: "${STORAGE_TYPE}"
EOF

    if [ "$STORAGE_TYPE" = "local" ]; then
        cat >> "$CONFIG_FILE" <<EOF
  local_path: "${STORAGE_PATH}"
  base_url: "${BASE_URL}"
EOF
    fi

    cat >> "$CONFIG_FILE" <<EOF

ai:
  default_text_provider: "${TEXT_AI}"
  default_image_provider: "${IMAGE_AI}"
  default_video_provider: "${VIDEO_AI}"
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  huobao-drama:
    image: huobao/huobao-drama:latest
    container_name: huobao-drama
    ports:
      - "127.0.0.1:${PORT}:5679"
    volumes:
      - ./data:/app/data
      - ./configs/config.yaml:/app/configs/config.yaml
    environment:
      - NODE_ENV=production
      - PORT=5679
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ Huobao Drama API 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 配置文件: ${CONFIG_FILE}${RESET}"
    echo -e "${GREEN}📂 数据目录: ${DATA_DIR}${RESET}"

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
    cd "$APP_DIR" || return
    docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    cd "$APP_DIR" || return
    docker compose logs -f
}

check_status() {
    cd "$APP_DIR" || return
    docker compose ps
    read -p "按回车返回菜单..."
}

uninstall_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}未检测到安装目录，无需卸载${RESET}"
        read -p "按回车返回菜单..."
        return
    fi
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Huobao Drama API 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
