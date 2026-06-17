#!/bin/bash
# ========================================
# Lucky v2 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="lucky"
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

get_public_ip() {
    local mode=${1:-"v4"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        # 强制获取 IPv4
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        # 强制获取 IPv6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        # auto 模式：双栈环境优先获取 IPv4 (更适合大众网络)，纯 v6 环境自动fallback到 v6
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        # 如果获取 v4 失败，说明可能是纯 v6 机器，尝试获取 v6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    # 兜底处理：所有接口都失败时，直接输出 127.0.0.1，不报错
    echo "127.0.0.1" && return 0
}

menu() {
    # 在这里加上 while true; do 开启循环
    while true; do
        clear
        # 1. 动态获取 Lucky 容器的状态 (先安全检测 docker 命令是否存在，防止菜单本身报错)
        local container_status="🔴 未运行(未检测到容器)"
        if command -v docker &>/dev/null; then
            if docker ps -a --format '{{.Names}}' | grep -q "^lucky$"; then
                local is_running=$(docker ps --format '{{.Names}}' | grep -q "^lucky$" && echo "yes" || echo "no")
                if [ "$is_running" = "yes" ]; then
                    container_status="🟢 运行中"
                else
                    container_status="🟡 已停止"
                fi
            fi
        else
            container_status="❌ 未安装 Docker"
        fi
        # 2. 渲染菜单头部、状态与端口信息
        echo -e "${GREEN}========================${RESET}"
        echo -e "${GREEN}  ◈  Lucky 管理菜单  ◈ ${RESET}"
        echo -e "${GREEN}========================${RESET}"
        echo -e "${GREEN}状态:${RESET} ${YELLOW}$container_status${RESET}"
        echo -e "${GREEN}端口:${RESET} ${YELLOW}16601${RESET}${YELLOW} (Host模式)${RESET}"
        echo -e "${GREEN}========================${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
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
    done # 这里的 done 就能闭合上方的 while 了
}

install_app() {
    check_docker
    mkdir -p "$APP_DIR/conf"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    cat > "$COMPOSE_FILE" <<EOF
services:
  lucky:
    image: gdy666/lucky:v2
    container_name: lucky
    volumes:
      - ./conf:/app/conf
      - /var/run/docker.sock:/var/run/docker.sock
    network_mode: host
    restart: always
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ Lucky 已启动${RESET}"
    echo -e "${YELLOW}✅ 访问地址: http://${SERVER_IP}:16601${RESET}"
    echo -e "${YELLOW}✅ 账号密码: 666/666${RESET}"
    echo -e "${YELLOW}📂 安装目录: $APP_DIR${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Lucky 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart lucky
    echo -e "${GREEN}✅ Lucky 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f lucky
}

check_status() {
    docker ps | grep lucky
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Lucky 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
