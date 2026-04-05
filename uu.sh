#!/bin/bash
# ========================================
# NodeTerminal 一键管理脚本
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
RED="\033[31m"

APP_NAME="nodeterminal"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

function menu() {
    clear
    echo -e "${GREEN}=== NodeTerminal 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 配置 OIDC${RESET}"
    echo -e "${GREEN}5) 查看日志${RESET}"
    echo -e "${GREEN}6) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) config_oidc ;;
        5) view_logs ;;
        6) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

function install_app() {

    read -p "请输入 Web 端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}

    mkdir -p "$APP_DIR/users"

    cat > "$ENV_FILE" <<EOF
OIDC_ENABLED=false
OIDC_ISSUER=
OIDC_CLIENT_ID=
OIDC_CLIENT_SECRET=
OIDC_REDIRECT_URI=http://localhost:$PORT/api/oidc/callback
OIDC_SCOPES=openid profile email
OIDC_BUTTON_LABEL=OpenID 登录
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  nodeterminal:
    image: wmz1024/nodeterminal:latest
    container_name: nodeterminal
    restart: unless-stopped
    ports:
      - "127.0.0.1:$PORT:3000"
    volumes:
      - $APP_DIR/users:/app/users
      - $ENV_FILE:/app/.env:ro
    environment:
      - NODE_ENV=production
EOF

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ NodeTerminal 已启动${RESET}"
    echo -e "${GREEN}🌐 Web 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/users${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {

    cd "$APP_DIR" || { echo "未安装"; sleep 1; menu; }

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}更新完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function restart_app() {

    cd "$APP_DIR" || { echo "未安装"; sleep 1; menu; }

    docker compose restart

    echo -e "${GREEN}重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function config_oidc() {

    cd "$APP_DIR" || { echo "未安装"; sleep 1; menu; }

    read -p "是否启用 OIDC (true/false) [默认:false]: " OIDC_ENABLED
    OIDC_ENABLED=${OIDC_ENABLED:-false}

    read -p "OIDC Provider (issuer): " OIDC_ISSUER
    read -p "OIDC Client ID: " OIDC_CLIENT_ID
    read -p "OIDC Client Secret: " OIDC_CLIENT_SECRET
    read -p "OIDC Redirect URI: " OIDC_REDIRECT_URI
    read -p "OIDC Scopes [默认:openid profile email]: " OIDC_SCOPES
    OIDC_SCOPES=${OIDC_SCOPES:-"openid profile email"}

    read -p "登录按钮文字 [默认:OpenID 登录]: " OIDC_BUTTON_LABEL
    OIDC_BUTTON_LABEL=${OIDC_BUTTON_LABEL:-"OpenID 登录"}

    sed -i "s|OIDC_ENABLED=.*|OIDC_ENABLED=$OIDC_ENABLED|" "$ENV_FILE"
    sed -i "s|OIDC_ISSUER=.*|OIDC_ISSUER=$OIDC_ISSUER|" "$ENV_FILE"
    sed -i "s|OIDC_CLIENT_ID=.*|OIDC_CLIENT_ID=$OIDC_CLIENT_ID|" "$ENV_FILE"
    sed -i "s|OIDC_CLIENT_SECRET=.*|OIDC_CLIENT_SECRET=$OIDC_CLIENT_SECRET|" "$ENV_FILE"
    sed -i "s|OIDC_REDIRECT_URI=.*|OIDC_REDIRECT_URI=$OIDC_REDIRECT_URI|" "$ENV_FILE"
    sed -i "s|OIDC_SCOPES=.*|OIDC_SCOPES=$OIDC_SCOPES|" "$ENV_FILE"
    sed -i "s|OIDC_BUTTON_LABEL=.*|OIDC_BUTTON_LABEL=$OIDC_BUTTON_LABEL|" "$ENV_FILE"

    docker compose restart

    echo -e "${GREEN}OIDC 配置已更新${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {

    cd "$APP_DIR" || { echo "未安装"; sleep 1; menu; }

    docker compose down -v
    rm -rf "$APP_DIR"

    echo -e "${GREEN}卸载完成${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function view_logs() {

    docker logs -f nodeterminal

    read -p "按回车返回菜单..."
    menu
}

menu
