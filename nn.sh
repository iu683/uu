#!/bin/bash
# ========================================
# VaultFleet 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="vaultfleet"
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

        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}  ◈  VaultFleet 管理菜单  ◈${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}7)${RESET} ${YELLOW}卸载 Agent${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        echo -e "${GREEN}==============================${RESET}"

        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            7) run_node ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
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

    read -p "请输入访问端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}

    check_port "$PORT" || return

    cat > "$COMPOSE_FILE" <<EOF
services:
  vaultfleet:
    image: ghcr.io/momo-z/vaultfleet:latest

    container_name: vaultfleet

    restart: unless-stopped

    ports:
      - "127.0.0.1:${PORT}:8080"

    volumes:
      - ./data:/data

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ VaultFleet 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}📂 数据目录: $APP_DIR/data${RESET}"

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

    docker restart vaultfleet

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f vaultfleet
}

check_status() {

    docker ps | grep vaultfleet

    read -p "按回车返回菜单..."
}

uninstall_app() {

    cd "$APP_DIR" || return

    docker compose down -v
    rm -rf "$APP_DIR"

    echo -e "${RED}✅ 已彻底卸载${RESET}"

    read -p "按回车返回菜单..."
}


# ============================================================
# 新增：GitHub 代理下载核心函数
# ============================================================
run_node() {
    clear
    # 用户提供的代理前缀列表
    local GITHUB_PROXY=(
        ''
        'https://v6.gh-proxy.org/'
        'https://gh-proxy.com/'
        'https://hub.glowp.xyz/'
        'https://proxy.vvvv.ee/'
        'https://ghproxy.lvedong.eu.org/'
    )
    
    local RAW_URL="https://raw.githubusercontent.com/momo-z/VaultFleet/main/build/uninstall.sh"
    local TEMP_SCRIPT="/tmp/nginx_backup_restore_temp.sh"
    local success=false


    # 循环轮询代理列表
    for proxy in "${GITHUB_PROXY[@]}"; do
        local target_url="${proxy}${RAW_URL}"
        if [ -n "$proxy" ]; then
            echo
        else
            echo
        fi

        # 使用 curl 下载，设置 8 秒超时
        if curl -fsSL --connect-timeout 8 "$target_url" -o "$TEMP_SCRIPT"; then
            success=true
            break
        fi
        echo -e "${RED}❌ 当前连接失败，正在切换下一个节点...${RESET}"
    done

    # 判断是否下载成功并执行
    if [ "$success" = true ] && [ -f "$TEMP_SCRIPT" ]; then
        echo
        chmod +x "$TEMP_SCRIPT"
        
        # 真正执行备份恢复脚本
        bash "$TEMP_SCRIPT"
        
        # 执行完毕后清理临时文件
        rm -f "$TEMP_SCRIPT"
    else
        echo -e "${RED}❌ 致命错误：所有 GitHub 代理节点均无法连接，请检查您的 VPS 网络！${RESET}"
    fi
}

menu
