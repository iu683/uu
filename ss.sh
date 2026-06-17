#!/bin/bash
# ========================================
# AriaNg 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="ariang"
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
        
        # 1. 动态获取 AriaNg 容器状态
        local container_status="🔴 未运行 (未检测到容器)"
        if command -v docker &>/dev/null; then
            if docker ps -a --format '{{.Names}}' | grep -q "^ariang$"; then
                local is_running=$(docker ps --format '{{.Names}}' | grep -q "^ariang$" && echo "yes" || echo "no")
                if [ "$is_running" = "yes" ]; then
                    container_status="🟢 运行中"
                else
                    container_status="🟡 已停止"
                fi
            fi
        else
            container_status="❌ 未安装 Docker"
        fi

        # 2. 动态获取当前配置的端口
        local current_port="6880"
        if [ -f "$COMPOSE_FILE" ]; then
            # 从 docker-compose.yml 中提取 127.0.0.1:xxxx:6880 中的端口号
            local yaml_port=$(grep -oP '127\.0\.0\.1:\K[0-9]+(?=:6880)' "$COMPOSE_FILE" 2>/dev/null)
            if [ -n "$yaml_port" ]; then
                current_port="$yaml_port"
            fi
        fi

        # 3. 渲染菜单头部、状态与端口信息
        echo -e "${GREEN}========================${RESET}"
        echo -e "${GREEN}  ◈ AriaNg 管理菜单 ◈  ${RESET}"
        echo -e "${GREEN}========================${RESET}"
        echo -e "${GREEN}状态:${RESET} ${YELLOW}$container_status${RESET}"
        echo -e "${GREEN}端口:${RESET} ${YELLOW}$current_port${RESET}"
        echo -e "${GREEN}========================${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        echo -e "${GREEN}========================${RESET}"
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
    read -p "请输入访问端口 [默认:6880]: " input_port
    PORT=${input_port:-6880}
    check_port "$PORT" || return

cat > "$COMPOSE_FILE" <<EOF
services:
  ariang:
    container_name: ariang
    image: p3terx/ariang
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:6880"
    logging:
      options:
        max-size: "1m"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置${RESET}"
        return
    fi

    echo
    echo -e "${GREEN}✅ AriaNg 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ AriaNg 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart ariang
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f ariang
}

check_status() {
    docker ps | grep ariang
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
