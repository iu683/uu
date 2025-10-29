#!/bin/bash
# ============================================
# EmbyKeeper 一键部署与管理脚本 (Docker Compose)
# ============================================

APP_NAME="embykeeper"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

menu() {
  clear
  echo -e "${GREEN}=== EmbyKeeper 管理菜单 ===${RESET}"
  echo -e "${GREEN}1) 安装启动${RESET}"
  echo -e "${GREEN}2) 更新${RESET}"
  echo -e "${GREEN}3) 重启${RESET}"
  echo -e "${GREEN}4) 查看日志${RESET}"
  echo -e "${GREEN}5) 卸载(含数据)${RESET}"
  echo -e "${GREEN}0) 退出${RESET}"
  read -rp "$(echo -e ${GREEN}请选择: ${RESET})" choice
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

install_app() {
  mkdir -p "$APP_DIR/embykeeper"

  echo -e "${YELLOW}是否使用 host 网络模式？(推荐 Y) [Y/n]: ${RESET}"
  read -r USE_HOST
  if [[ "$USE_HOST" =~ ^[Nn]$ ]]; then
    NET_MODE="bridge"
  else
    NET_MODE="host"
  fi

  cat > "$COMPOSE_FILE" <<EOF
services:
  embykeeper:
    image: embykeeper/embykeeper:latest
    container_name: $APP_NAME
    restart: unless-stopped
    network_mode: $NET_MODE
    volumes:
      - ./embykeeper:/app
EOF

  cd "$APP_DIR" || exit
  docker compose up -d

  echo -e "${GREEN}✅ EmbyKeeper 已启动${RESET}"
  echo -e "${GREEN}📂 配置目录: $APP_DIR/embykeeper${RESET}"
  echo -e "${YELLOW}💡 初次运行请编辑配置后重启容器${RESET}"
  read -rp "按回车返回菜单..."
  menu
}

update_app() {
  cd "$APP_DIR" || { echo "❌ 未检测到安装目录"; sleep 1; menu; }
  docker compose pull
  docker compose up -d
  echo -e "${GREEN}✅ 已更新并重启${RESET}"
  read -rp "按回车返回菜单..."
  menu
}

restart_app() {
  cd "$APP_DIR" || { echo "❌ 未检测到安装目录"; sleep 1; menu; }
  docker compose restart
  echo -e "${GREEN}✅ 已重启${RESET}"
  read -rp "按回车返回菜单..."
  menu
}

view_logs() {
  docker logs -f $APP_NAME
  read -rp "按回车返回菜单..."
  menu
}

uninstall_app() {
  cd "$APP_DIR" || { echo "❌ 未检测到安装目录"; sleep 1; menu; }
  docker compose down -v
  rm -rf "$APP_DIR"
  echo -e "${RED}✅ 已卸载并删除所有数据${RESET}"
  read -rp "按回车返回菜单..."
  menu
}

menu
