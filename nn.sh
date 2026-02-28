#!/bin/bash
# ========================================
# DUFS 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="dufs"
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
        echo -e "${GREEN}=== DUFS 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR/data"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:5000]: " input_port
    PORT=${input_port:-5000}
    check_port "$PORT" || return

    read -p "请输入本地数据目录路径 [默认:/vol1/1000/docker/dufs/dufs/data]: " data_dir
    DATA_DIR=${data_dir:-/vol1/1000/docker/dufs/dufs/data}
    mkdir -p "$DATA_DIR"

    # 新增：输入账号密码
    read -p "请输入 DUFS 用户名 [默认:admin]: " username
    USERNAME=${username:-admin}
    read -p "请输入 DUFS 密码 [默认:123456]: " password
    PASSWORD=${password:-123456}

    cat > "$COMPOSE_FILE" <<EOF
services:
  dufs:
    image: sigoden/dufs:latest
    container_name: dufs
    command: /data -a ${USERNAME}:${PASSWORD}@/:rw
    ports:
      - "127.0.0.1:${PORT}:5000"
    volumes:
      - ${DATA_DIR}:/data
    restart: always
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ DUFS 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🔑 用户名: ${USERNAME}  密码: ${PASSWORD}${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ DUFS 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart dufs
    echo -e "${GREEN}✅ DUFS 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f dufs
}

check_status() {
    docker ps | grep dufs
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ DUFS 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu 
