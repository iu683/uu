#!/bin/bash
# ========================================
# Argo Nezha Dashboard 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="nezha-dashboard"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

# 自动检测 compose 命令
if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    COMPOSE_CMD="docker compose"
fi

function menu() {
    clear
    echo -e "${GREEN}=== 哪吒面板V1(Argo版本)管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装并启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) view_logs ;;
        5) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

function install_app() {
    mkdir -p "$APP_DIR/data"

    echo -e "${YELLOW}请输入 GitHub 配置:${RESET}"
    read -p "GitHub 用户名: " GH_USER
    read -p "GitHub 邮箱: " GH_EMAIL
    read -p "GitHub Token: " GH_PAT
    read -p "GitHub 仓库 (格式: 用户名/仓库名): " GH_REPO
    read -p "GitHub OAuth ClientID: " GH_CLIENTID
    read -p "GitHub OAuth ClientSecret: " GH_CLIENTSECRET
    echo -e "${YELLOW}请输入 Cloudflare Argo 配置:${RESET}"
    read -p "Argo Auth (JSON 或 token): " ARGO_AUTH
    read -p "Argo 隧道域名: " ARGO_DOMAIN
    read -p "是否关闭自动同步备份脚本 (y/n，默认 n): " disable_auto
    if [[ "$disable_auto" == "y" ]]; then
        NO_AUTO_RENEW="1"
    else
        NO_AUTO_RENEW=""
    fi

    # 写 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  nezha:
    image: mikehand888/argo-nezha:latest
    container_name: nezha_dashboard
    restart: always
    environment:
      - TZ=Asia/Shanghai
      - GH_USER=$GH_USER
      - GH_EMAIL=$GH_EMAIL
      - GH_PAT=$GH_PAT
      - GH_REPO=$GH_REPO
      - GH_CLIENTID=$GH_CLIENTID
      - GH_CLIENTSECRET=$GH_CLIENTSECRET
      - ARGO_AUTH=$ARGO_AUTH
      - ARGO_DOMAIN=$ARGO_DOMAIN
EOF

    if [[ -n "$NO_AUTO_RENEW" ]]; then
        echo "      - NO_AUTO_RENEW=$NO_AUTO_RENEW" >> "$COMPOSE_FILE"
    fi

    cat >> "$COMPOSE_FILE" <<EOF
    volumes:
      - $APP_DIR/data:/data
EOF

    cd "$APP_DIR"
    $COMPOSE_CMD up -d

    echo -e "${GREEN}✅ Nezha Dashboard (Argo 版本) 已启动${RESET}"
    echo -e "${YELLOW}🌐 通过 Argo 隧道访问: https://$ARGO_DOMAIN${RESET}"
    echo -e "${GREEN}✅ 账号/密码: admin/admin${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}✅ 提示: 隧道生成需要时间,请等待30秒${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录，请先安装${RESET}"; sleep 1; menu; }
    $COMPOSE_CMD pull
    $COMPOSE_CMD up -d
    echo -e "${GREEN}✅ Nezha Dashboard 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function restart_app() {
    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录，请先安装${RESET}"; sleep 1; menu; }
    $COMPOSE_CMD restart
    echo -e "${GREEN}✅ Nezha Dashboard 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f nezha_dashboard
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录${RESET}"; sleep 1; menu; }
    $COMPOSE_CMD down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Nezha Dashboard 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
