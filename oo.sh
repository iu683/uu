#!/bin/bash
# ========================================
# Cloudflare Preferred Panel 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="cloudflare-panel"
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
        echo -e "${GREEN}=== Cloudflare Panel 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 查看 Initial setup token${RESET}"
        echo -e "${GREEN}7) 卸载${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) view_token ;;
            7) uninstall_app ;;
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
    read -p "请输入访问端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}
    check_port "$PORT" || return

    # 自动创建外部数据卷，防止 compose 报错
    docker volume inspect cloudflare-panel-data &>/dev/null || docker volume create cloudflare-panel-data

cat > "$COMPOSE_FILE" <<EOF
services:
  network:
    container_name: cloudflare-preferred-panel
    image: baize233/network:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:3000"
    volumes:
      - cloudflare-panel-data:/data

volumes:
  cloudflare-panel-data:
    external: true
    name: cloudflare-panel-data
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置${RESET}"
        return
    fi

    echo
    echo -e "${GREEN}✅ Cloudflare Panel 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    
    # 异步等容器初始化一会儿再尝试读取 Token 提示
    echo -e "${YELLOW}⏳ 正在等待容器初始化并获取安全口令...${RESET}"
    sleep 3
    echo "----------------------------------------"
    view_token_logic
    echo "----------------------------------------"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Cloudflare Panel 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart cloudflare-preferred-panel
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f cloudflare-preferred-panel
}

check_status() {
    docker ps | grep cloudflare-preferred-panel
    echo "----------------------------------------"
    view_token_logic
    echo "----------------------------------------"
    read -p "按回车返回菜单..."
}

# 内部复用的 Token 读取逻辑
view_token_logic() {
    if [ "$(docker ps -q -f name=cloudflare-preferred-panel)" ]; then
        echo -e "${GREEN}🔑 正在从容器内部读取 Setup Token...${RESET}"
        TOKEN=$(docker exec cloudflare-preferred-panel cat /data/setup-token.txt 2>/dev/null)
        if [ -n "$TOKEN" ]; then
            echo -e "${YELLOW}Initial setup token: ${GREEN}${TOKEN}${RESET}"
        else
            echo -e "${RED}❌ 未能读取到 Token，可能容器刚启动尚未生成，或者您已经完成了解锁。${RESET}"
            echo -e "${YELLOW}💡 你也可以尝试直接查看日志: docker logs cloudflare-preferred-panel${RESET}"
        fi
    else
        echo -e "${RED}❌ 容器未在运行，无法读取 Token。${RESET}"
    fi
}

# 菜单调用的 Token 查看函数
view_token() {
    clear
    view_token_logic
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    # 顺便清理外部数据卷
    docker volume rm cloudflare-panel-data &>/dev/null
    echo -e "${RED}✅ 已卸载（包括本地数据卷）${RESET}"
    read -p "按回车返回菜单..."
}

menu
