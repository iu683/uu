#!/bin/bash
# ========================================
# Tunescout 管理
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="tunescout"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

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
        echo -e "${RED}端口 $1 已被占用！${RESET}"
        return 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Tunescout 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR"

    cd "$APP_DIR" || exit

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:8503]: " input_port
    PORT=${input_port:-8503}
    check_port "$PORT" || return

    read -p "请输入Web用户名 [默认:admin]: " input_user
    WEB_USERNAME=${input_user:-admin}

    read -p "请输入Web密码 [默认:admin123]: " input_pass
    WEB_PASSWORD=${input_pass:-admin123}

    read -p "请输入音乐目录 [必填，例如:/data/music]: " MUSIC_DIR
    [ -z "$MUSIC_DIR" ] && echo -e "${RED}音乐目录不能为空${RESET}" && return

    read -p "请输入下载目录 [默认:/data/download]: " input_dl
    DOWNLOAD_DIR=${input_dl:-/data/download}

    read -p "请输入Navidrome数据目录 [必填，例如:/data/navidrome]: " NAVI_DIR
    [ -z "$NAVI_DIR" ] && echo -e "${RED}Navidrome目录不能为空${RESET}" && return

    echo -e "${YELLOW}👉 自动创建配置文件...${RESET}"
    [ -f config.json ] || echo '{}' > config.json
    [ -f library_cache.db ] || touch library_cache.db

    cat > "$COMPOSE_FILE" <<EOF
services:
  tunescout:
    image: yuwancumian2009/tunescout-v2:latest
    container_name: tunescout
    restart: unless-stopped

    ports:
      - "127.0.0.1:${PORT}:8503"

    environment:
      TZ: Asia/Shanghai
      WEB_USERNAME: ${WEB_USERNAME}
      WEB_PASSWORD: ${WEB_PASSWORD}
      PUID: 1000
      PGID: 1000
      ND_DB_PATH: /navidrome_data/navidrome.db
      ND_MUSIC_PREFIX: /music

    volumes:
      - ./config.json:/app/config.json
      - ./library_cache.db:/app/library_cache.db
      - ${MUSIC_DIR}:/music
      - ${DOWNLOAD_DIR}:/download
      - ${NAVI_DIR}:/navidrome_data
EOF

    docker compose up -d

    echo
    echo -e "${GREEN}✅ Tunescout 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🌐 账号: $WEB_USERNAME${RESET}"
    echo -e "${YELLOW}🌐 密码: $WEB_PASSWORD${RESET}"
    echo -e "${GREEN}📂 目录: $APP_DIR${RESET}"

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
    docker restart tunescout
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f tunescout
}

check_status() {
    docker ps | grep tunescout
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
