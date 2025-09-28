```bash
#!/bin/bash
# ============================================
# Kuma-Mieru 管理脚本（支持公网访问 + 自定义端口）
# ============================================

set -e

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

APP_DIR="$HOME/kuma-mieru"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/kuma-mieru.env"
CONTAINER_NAME="kuma-mieru"

menu() {
    clear
    echo -e "${GREEN}=== Kuma-Mieru 管理菜单 ===${RESET}"
    echo -e "${YELLOW}1) 安装/部署 Kuma-Mieru${RESET}"
    echo -e "${YELLOW}2) 更新 Kuma-Mieru${RESET}"
    echo -e "${YELLOW}3) 卸载 Kuma-Mieru${RESET}"
    echo -e "${YELLOW}4) 查看日志${RESET}"
    echo -e "${YELLOW}5) 查看访问信息${RESET}"
    echo -e "${YELLOW}0) 退出${RESET}"
    echo
    read -p "请选择操作: " choice

    case $choice in
        1) install ;;
        2) update ;;
        3) uninstall ;;
        4) logs ;;
        5) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择！${RESET}" && sleep 1 && menu ;;
    esac
}

load_env() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi
}

install() {
    echo -e "${GREEN}=== 开始安装 Kuma-Mieru ===${RESET}"

    mkdir -p "$APP_DIR"

    read -p "请输入映射端口 (默认: 3883): " KUMA_PORT
    KUMA_PORT=${KUMA_PORT:-3883}

    read -p "请输入 Uptime Kuma 基础 URL (公网访问必填): " UPTIME_KUMA_BASE_URL
    [ -z "$UPTIME_KUMA_BASE_URL" ] && echo -e "${RED}必须填写 Uptime Kuma 基础 URL！${RESET}" && exit 1

    read -p "请输入 Uptime Kuma 状态页面 ID (必填): " PAGE_ID
    [ -z "$PAGE_ID" ] && echo -e "${RED}必须填写状态页面 ID！${RESET}" && exit 1

    read -p "是否展示 'Edit This Page' 按钮? (true/false, 默认: false): " FEATURE_EDIT_THIS_PAGE
    FEATURE_EDIT_THIS_PAGE=${FEATURE_EDIT_THIS_PAGE:-false}

    read -p "是否展示 'Star on Github' 按钮? (true/false, 默认: true): " FEATURE_SHOW_STAR_BUTTON
    FEATURE_SHOW_STAR_BUTTON=${FEATURE_SHOW_STAR_BUTTON:-true}

    read -p "请输入页面标题 (默认: Kuma Mieru): " FEATURE_TITLE
    FEATURE_TITLE=${FEATURE_TITLE:-Kuma Mieru}

    read -p "请输入页面描述 (默认: A beautiful and modern uptime monitoring dashboard): " FEATURE_DESCRIPTION
    FEATURE_DESCRIPTION=${FEATURE_DESCRIPTION:-"A beautiful and modern uptime monitoring dashboard"}

    read -p "请输入页面图标 URL (默认: /icon.svg): " FEATURE_ICON
    FEATURE_ICON=${FEATURE_ICON:-/icon.svg}

    # 写入 .env
    cat > "$ENV_FILE" <<EOF
KUMA_PORT=$KUMA_PORT
UPTIME_KUMA_BASE_URL=$UPTIME_KUMA_BASE_URL
PAGE_ID=$PAGE_ID
FEATURE_EDIT_THIS_PAGE=$FEATURE_EDIT_THIS_PAGE
FEATURE_SHOW_STAR_BUTTON=$FEATURE_SHOW_STAR_BUTTON
FEATURE_TITLE="$FEATURE_TITLE"
FEATURE_DESCRIPTION="$FEATURE_DESCRIPTION"
FEATURE_ICON=$FEATURE_ICON
EOF

    # 写入 docker-compose.yml（绑定公网）
    cat > "$COMPOSE_FILE" <<EOF
services:
  kuma-mieru:
    image: ghcr.io/alice39s/kuma-mieru:latest
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    ports:
      - "0.0.0.0:\${KUMA_PORT}:3000"
    env_file:
      - ./kuma-mieru.env
    environment:
      NODE_ENV: production
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/api/health"]
      interval: 30s
      timeout: 3s
      retries: 3
    tmpfs:
      - /tmp
EOF

    (cd "$APP_DIR" && docker compose up -d)

    show_info
    read -p "按回车返回菜单..." && menu
}

update() {
    echo -e "${GREEN}=== 更新 Kuma-Mieru ===${RESET}"
    (cd "$APP_DIR" && docker compose pull && docker compose up -d)
    echo -e "${GREEN}✅ 更新完成！${RESET}"
    read -p "按回车返回菜单..." && menu
}

uninstall() {
    echo -e "${RED}⚠️  即将卸载 Kuma-Mieru，并删除相关数据！${RESET}"
    read -p "确认卸载? (y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        (cd "$APP_DIR" && docker compose down -v)
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ 卸载完成${RESET}"
    else
        echo -e "${YELLOW}已取消${RESET}"
    fi
    read -p "按回车返回菜单..." && menu
}

logs() {
    echo -e "${GREEN}=== 查看 Kuma-Mieru 日志 ===${RESET}"
    docker logs -f $CONTAINER_NAME
    read -p "按回车返回菜单..." && menu
}

show_info() {
    load_env
    PUBLIC_IP=$(curl -s ifconfig.me || echo "your-server-ip")
    echo -e "${GREEN}=== 当前 Kuma-Mieru 配置信息 ===${RESET}"
    echo -e "访问地址: ${YELLOW}http://${PUBLIC_IP}:${KUMA_PORT}${RESET}"
    echo -e "UPTIME_KUMA_BASE_URL: ${UPTIME_KUMA_BASE_URL}"
    echo -e "PAGE_ID: ${PAGE_ID}"
    echo -e "FEATURE_EDIT_THIS_PAGE: ${FEATURE_EDIT_THIS_PAGE}"
    echo -e "FEATURE_SHOW_STAR_BUTTON: ${FEATURE_SHOW_STAR_BUTTON}"
    echo -e "FEATURE_TITLE: ${FEATURE_TITLE}"
    echo -e "FEATURE_DESCRIPTION: ${FEATURE_DESCRIPTION}"
    echo -e "FEATURE_ICON: ${FEATURE_ICON}"
}

menu
```
