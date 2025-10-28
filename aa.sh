#!/bin/bash
# ========================================
# WeChat-Selkies 一键管理脚本 (Docker Compose)
# ========================================

APP_NAME="wechat-selkies"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

menu() {
  clear
  echo -e "${GREEN}=== WeChat-Selkies 管理菜单 ===${RESET}"
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
  mkdir -p "$APP_DIR"/config

  read -p "请输入 Web HTTP 端口 [默认:3000]: " input_http
  HTTP_PORT=${input_http:-3000}

  read -p "请输入 Web HTTPS 端口 [默认:3001]: " input_https
  HTTPS_PORT=${input_https:-3001}

  read -p "请输入 Selkies 用户名 [默认:admin]: " input_user
  CUSTOM_USER=${input_user:-admin}

  read -p "请输入 Selkies 密码 [默认:随机生成]: " input_pass
  PASSWORD=${input_pass:-$(head -c 12 /dev/urandom | base64 | tr -dc A-Za-z0-9 | cut -c1-12)}

  [ ! -d /dev/dri ] && echo -e "${YELLOW}⚠️ /dev/dri 不存在，GPU 加速不可用${RESET}"

  cat > "$COMPOSE_FILE" <<EOF

services:
  wechat-selkies:
    image: ghcr.io/nickrunning/wechat-selkies:latest
    container_name: wechat-selkies
    restart: unless-stopped
    ports:
      - "127.0.0.1:${HTTP_PORT}:3000"
      - "127.0.0.1:${HTTPS_PORT}:3001"
    volumes:
      - ./config:/config
    devices:
      - /dev/dri:/dev/dri
    environment:
      - PUID=1000
      - PGID=100
      - TZ=Asia/Shanghai
      - LC_ALL=zh_CN.UTF-8
      - AUTO_START_WECHAT=true
      - AUTO_START_QQ=false
      - CUSTOM_USER=${CUSTOM_USER}
      - PASSWORD=${PASSWORD}
EOF

  cd "$APP_DIR"
  docker compose up -d

  echo -e "${GREEN}✅ WeChat-Selkies 已启动${RESET}"
  echo -e "${YELLOW}🌐 Web UI 地址: http://127.0.0.1:${HTTP_PORT}${RESET}"
  echo -e "${GREEN}📂 配置目录: $APP_DIR/config${RESET}"
  echo -e "${GREEN}👤 用户名: ${CUSTOM_USER}, 密码: ${PASSWORD}${RESET}"
  read -p "按回车返回菜单..."
  menu
}


update_app() {
  cd "$APP_DIR" || { echo "❌ 未检测到安装目录"; sleep 1; menu; }
  docker compose pull
  docker compose up -d
  echo -e "${GREEN}✅ WeChat-Selkies 已更新并重启${RESET}"
  read -p "按回车返回菜单..."
  menu
}

restart_app() {
  cd "$APP_DIR" || { echo "❌ 未检测到安装目录"; sleep 1; menu; }
  docker compose restart
  echo -e "${GREEN}✅ WeChat-Selkies 已重启${RESET}"
  read -p "按回车返回菜单..."
  menu
}

view_logs() {
  docker logs -f wechat-selkies
  read -p "按回车返回菜单..."
  menu
}

uninstall_app() {
  cd "$APP_DIR" || { echo "❌ 未检测到安装目录"; sleep 1; menu; }
  docker compose down -v
  rm -rf "$APP_DIR"
  echo -e "${RED}✅ WeChat-Selkies 已卸载并删除所有数据${RESET}"
  read -p "按回车返回菜单..."
  menu
}

menu
