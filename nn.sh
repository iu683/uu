#!/bin/bash
# ========================================
# Chain-Subconverter 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="chain-subconverter"
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

        echo -e "${GREEN}=== Chain-Subconverter 管理菜单 ===${RESET}"
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
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
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

    read -p "请输入 Web 端口 [默认:11200]: " input_port
    PORT=${input_port:-11200}

    check_port "$PORT" || return

    echo
    read -p "请输入模板 URL [默认 OpenClash 模板]: " input_template
    TEMPLATE_URL=${input_template:-https://raw.githubusercontent.com/Aethersailor/Custom_OpenClash_Rules/refs/heads/main/cfg/Custom_Clash.ini}

    cat > "$COMPOSE_FILE" <<EOF
services:
  subconverter:
    image: ghcr.io/slackworker/subconverter:integration-chain-subconverter

    networks:
      - subconverter-backend

    restart: unless-stopped

    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:25500/version || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  app:
    image: ghcr.io/slackworker/chain-subconverter:latest

    depends_on:
      subconverter:
        condition: service_healthy

    environment:
      CHAIN_SUBCONVERTER_HTTP_ADDRESS: :11200
      CHAIN_SUBCONVERTER_TRUSTED_PROXY_CIDRS: "172.16.0.0/12"
      CHAIN_SUBCONVERTER_SUBCONVERTER_FACING_BASE_URL: http://app:11200
      CHAIN_SUBCONVERTER_DEFAULT_TEMPLATE_URL: ${TEMPLATE_URL}
      CHAIN_SUBCONVERTER_DEFAULT_TEMPLATE_FETCH_CACHE_TTL: 5m
      CHAIN_SUBCONVERTER_SUBCONVERTER_UPSTREAM_BASE_URL: http://subconverter:25500/sub?
      CHAIN_SUBCONVERTER_SHORT_LINK_DB_PATH: /data/short-links.sqlite3
      CHAIN_SUBCONVERTER_SHORT_LINK_CAPACITY: 1000

    networks:
      - subconverter-backend

    ports:
      - "127.0.0.1:${PORT}:11200"

    volumes:
      - short-link-data:/data

    restart: unless-stopped

    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:11200/healthz || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 5s

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  short-link-data:

networks:
  subconverter-backend:
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ Chain-Subconverter 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}📂 数据目录: $APP_DIR${RESET}"

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

    cd "$APP_DIR" || return

    docker compose down -v
    rm -rf "$APP_DIR"

    echo -e "${RED}✅ 已彻底卸载${RESET}"

    read -p "按回车返回菜单..."
}

menu
