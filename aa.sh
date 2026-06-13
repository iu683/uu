#!/bin/bash
# ========================================
# GHProxy + Smart-Git 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="ghproxy-smartgit"
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
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== GHProxy + Smart-Git 管理菜单 ===${RESET}"
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

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    echo
    read -p "请输入 GHProxy 端口 [默认:7210]: " input_ghport
    GHPROXY_PORT=${input_ghport:-7210}
    check_port "$GHPROXY_PORT" || return

    echo
    read -p "请输入 GHProxy 日志目录 [默认:$APP_DIR/ghproxy/log]: " input_ghlog
    GHPROXY_LOG=${input_ghlog:-$APP_DIR/ghproxy/log}

    echo
    read -p "请输入 GHProxy 配置目录 [默认:$APP_DIR/ghproxy/config]: " input_ghconf
    GHPROXY_CONF=${input_ghconf:-$APP_DIR/ghproxy/config}

    echo
    read -p "请输入 Smart-Git 日志目录 [默认:$APP_DIR/smart-git/log]: " input_gitlog
    GIT_LOG=${input_gitlog:-$APP_DIR/smart-git/log}

    echo
    read -p "请输入 Smart-Git 配置目录 [默认:$APP_DIR/smart-git/config]: " input_gitconf
    GIT_CONF=${input_gitconf:-$APP_DIR/smart-git/config}

    echo
    read -p "请输入 Smart-Git 仓库目录 [默认:$APP_DIR/smart-git/repos]: " input_repos
    GIT_REPOS=${input_repos:-$APP_DIR/smart-git/repos}

    echo
    read -p "请输入 Smart-Git 数据库目录 [默认:$APP_DIR/smart-git/db]: " input_db
    GIT_DB=${input_db:-$APP_DIR/smart-git/db}

    mkdir -p "$GHPROXY_LOG" "$GHPROXY_CONF"
    mkdir -p "$GIT_LOG" "$GIT_CONF" "$GIT_REPOS" "$GIT_DB"

cat > "$COMPOSE_FILE" <<EOF
services:

  ghproxy:
    image: wjqserver/ghproxy:latest
    container_name: ghproxy
    restart: always
    ports:
      - "127.0.0.1:${GHPROXY_PORT}:8080"
    volumes:
      - ${GHPROXY_LOG}:/data/ghproxy/log
      - ${GHPROXY_CONF}:/data/ghproxy/config

  smart-git:
    image: wjqserver/smart-git:latest
    container_name: smart-git
    restart: always
    volumes:
      - ${GIT_LOG}:/data/smart-git/log
      - ${GIT_CONF}:/data/smart-git/config
      - ${GIT_REPOS}:/data/smart-git/repos
      - ${GIT_DB}:/data/smart-git/db
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置${RESET}"
        return
    fi

    echo
    echo -e "${GREEN}✅ GHProxy + Smart-Git 已启动${RESET}"
    echo -e "${YELLOW}🌐 GHProxy: http://127.0.0.1:${GHPROXY_PORT}${RESET}"
    echo -e "${GREEN}📂 所有数据已持久化到自定义目录${RESET}"

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
    docker restart ghproxy smart-git
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo "1) ghproxy"
    echo "2) smart-git"
    read -p "选择查看日志: " opt
    case $opt in
        1) docker logs -f ghproxy ;;
        2) docker logs -f smart-git ;;
        *) echo "无效选择" ;;
    esac
}

check_status() {
    docker ps | grep -E "ghproxy|smart-git"
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已卸载全部服务${RESET}"
    read -p "按回车返回菜单..."
}

menu
