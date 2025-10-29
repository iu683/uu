#!/bin/bash
# ============================================
# Misaka 弹幕服务器 一键部署脚本 (Docker Compose)
# ============================================

APP_NAME="misaka-danmu-server"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

menu() {
  clear
  echo -e "${GREEN}=== Misaka 弹幕服务器 管理菜单 ===${RESET}"
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
  mkdir -p "$APP_DIR/config"

  echo -e "${YELLOW}请输入远程 MySQL 连接信息:${RESET}"
  read -rp "数据库主机/IP: " DB_HOST
  read -rp "数据库端口 [默认:3306]: " DB_PORT
  DB_PORT=${DB_PORT:-3306}
  read -rp "数据库名 [默认:danmuapi]: " DB_NAME
  DB_NAME=${DB_NAME:-danmuapi}
  read -rp "数据库用户名 [默认:danmuapi]: " DB_USER
  DB_USER=${DB_USER:-danmuapi}
  read -rp "数据库密码: " DB_PASS
  [ -z "$DB_PASS" ] && { echo -e "${RED}数据库密码不能为空！${RESET}"; exit 1; }

  echo -e "${YELLOW}请输入管理员登录信息:${RESET}"
  read -rp "管理员用户名 [默认:admin]: " ADMIN_USER
  ADMIN_USER=${ADMIN_USER:-admin}

  read -rp "HTTP 端口 [默认:7768]: " APP_PORT
  APP_PORT=${APP_PORT:-7768}

  cat > "$COMPOSE_FILE" <<EOF
services:
  danmu-app:
    image: l429609201/misaka_danmu_server:latest
    container_name: $APP_NAME
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - UMASK=0022
      - TZ=Asia/Shanghai

      - DANMUAPI_DATABASE__TYPE=mysql
      - DANMUAPI_DATABASE__HOST=$DB_HOST
      - DANMUAPI_DATABASE__PORT=$DB_PORT
      - DANMUAPI_DATABASE__NAME=$DB_NAME
      - DANMUAPI_DATABASE__USER=$DB_USER
      - DANMUAPI_DATABASE__PASSWORD=$DB_PASS

      - DANMUAPI_ADMIN__INITIAL_USER=$ADMIN_USER

    volumes:
      - ./config:/app/config
    ports:
      - "127.0.0.1:${APP_PORT}:7768"

    networks:
      - misaka-net

networks:
  misaka-net:
    driver: bridge
EOF

  cd "$APP_DIR" || exit
  docker compose up -d

  echo -e "${GREEN}✅ Misaka 弹幕服务器 已启动${RESET}"
  echo -e "${YELLOW}🌐 Web 地址: http://127.0.0.1:${APP_PORT}${RESET}"
  echo -e "${GREEN}📂 配置目录: $APP_DIR/config${RESET}"
  echo -e "${GREEN}👤 管理员: ${ADMIN_USER}${RESET}"
  echo -e "${GREEN}🔑 密码: 查看日志${RESET}"
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
