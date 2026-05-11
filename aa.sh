#!/bin/bash
# ========================================
# NodeGet StatusShow 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="nodeget-statusshow"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.json"

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

        echo -e "${GREEN}=== NodeGet StatusShow 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 编辑配置${RESET}"
        echo -e "${GREEN}7) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"

        read -p "请选择: " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) edit_config ;;
            7) uninstall_app ;;
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

    read -p "请输入访问端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}
    check_port "$PORT" || return

    read -p "请输入站点名称 [默认:我的探针页]: " input_name
    SITE_NAME=${input_name:-我的探针页}

    read -p "请输入页脚内容 [默认:Powered by NodeGet]: " input_footer
    FOOTER=${input_footer:-Powered by NodeGet}

    read -p "请输入节点名称 [默认:主节点]: " input_node_name
    NODE_NAME=${input_node_name:-主节点}

    read -p "请输入 NodeGet WS 地址: " BACKEND_URL

    if [ -z "$BACKEND_URL" ]; then
        echo -e "${RED}❌ WS 地址不能为空${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    read -p "请输入 NodeGet Token: " TOKEN

    if [ -z "$TOKEN" ]; then
        echo -e "${RED}❌ Token 不能为空${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    cat > "$CONFIG_FILE" <<EOF
{
  "site_name": "${SITE_NAME}",
  "site_logo": "",
  "footer": "${FOOTER}",
  "site_tokens": [
    {
      "name": "${NODE_NAME}",
      "backend_url": "${BACKEND_URL}",
      "token": "${TOKEN}"
    }
  ]
}
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  nodeget-statusshow:
    image: coldsword/nodeget-statusshow:latest
    container_name: nodeget-statusshow
    restart: unless-stopped

    ports:
      - "127.0.0.1:${PORT}:3000"

    volumes:
      - ./config.json:/app/config.json:ro
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ NodeGet StatusShow 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址:${RESET} http://127.0.0.1:${PORT}"
    echo -e "${GREEN}📄 配置文件:${RESET} $CONFIG_FILE"

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

    docker restart nodeget-statusshow

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f nodeget-statusshow
}

check_status() {

    docker ps | grep nodeget-statusshow

    read -p "按回车返回菜单..."
}

edit_config() {

    nano "$CONFIG_FILE"

    echo -e "${GREEN}✅ 配置已编辑${RESET}"
    echo -e "${YELLOW}♻️ 正在重启容器...${RESET}"

    docker restart nodeget-statusshow

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
