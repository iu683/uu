#!/bin/bash
# ========================================
# Pika (SQLite) 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="pika-sqlite"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.sqlite.yml"
CONFIG_FILE="$APP_DIR/config.yaml"

# 检查 Docker & Docker Compose
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

# 检查端口占用
check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

# 下载配置文件并修改 JWT Secret
generate_config() {
    # 下载官方配置
    curl -o "$CONFIG_FILE" https://raw.githubusercontent.com/dushixiang/pika/main/config.sqlite.yaml

    # 提示用户输入 JWT Secret
    read -p "请输入 JWT Secret [默认自动生成 UUID]: " input_jwt
    JWT_SECRET=${input_jwt:-$(uuidgen)}

    # 替换配置文件中 App.JWT.Secret
    sed -i "s#^\s*Secret:.*#    Secret: \"$JWT_SECRET\"#" "$CONFIG_FILE"

    echo -e "${GREEN}✅ config.yaml 已下载并修改 JWT Secret${RESET}"
}

# 菜单
menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Pika (SQLite) 管理菜单 ===${RESET}"
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

# 安装/启动
install_app() {
    check_docker
    mkdir -p "$APP_DIR"
    mkdir -p "$APP_DIR/data"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}
    check_port "$PORT" || return

    # 下载 docker-compose 文件
    curl -o "$COMPOSE_FILE" https://raw.githubusercontent.com/dushixiang/pika/main/docker-compose.sqlite.yml

    # 修改 docker-compose 文件端口映射
    sed -i "s/8080:8080/${PORT}:8080/" "$COMPOSE_FILE"

    # 下载并修改配置文件
    generate_config

    cd "$APP_DIR" || exit
    docker compose -f docker-compose.sqlite.yml up -d

    echo -e "${GREEN}✅ Pika 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    read -p "按回车返回菜单..."
}

# 更新
update_app() {
    cd "$APP_DIR" || return
    docker compose -f docker-compose.sqlite.yml pull
    docker compose -f docker-compose.sqlite.yml up -d
    echo -e "${GREEN}✅ Pika 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

# 重启
restart_app() {
    cd "$APP_DIR" || return
    docker compose -f docker-compose.sqlite.yml restart
    echo -e "${GREEN}✅ Pika 已重启${RESET}"
    read -p "按回车返回菜单..."
}

# 查看日志
view_logs() {
    cd "$APP_DIR" || return
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker compose -f docker-compose.sqlite.yml logs -f
}

# 查看状态
check_status() {
    cd "$APP_DIR" || return
    docker compose -f docker-compose.sqlite.yml ps
    read -p "按回车返回菜单..."
}

# 卸载
uninstall_app() {
    cd "$APP_DIR" || return
    docker compose -f docker-compose.sqlite.yml down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Pika 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
