#!/bin/bash
# ========================================
# 喵喵屋 (MiaoMiaoWu) 一键管理脚本
# ========================================

APP_NAME="miaomiaowu"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

menu() {
  clear
  echo -e "${GREEN}=== 喵喵屋管理菜单 ===${RESET}"
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
  mkdir -p "$APP_DIR"/{data,subscribes,rule_templates}

  read -p "请输入 Web 端口 [默认:8080]: " input_port
  PORT=${input_port:-8080}

  read -p "请输入 JWT 密钥 (留空自动生成): " input_secret
  JWT_SECRET=${input_secret:-$(uuidgen)}

  cat > "$COMPOSE_FILE" <<EOF

services:
  miaomiaowu:
    image: ghcr.io/jimleerx/miaomiaowu:latest
    container_name: miaomiaowu
    restart: unless-stopped
    user: root
    environment:
      - PORT=${PORT}
      - DATABASE_PATH=/app/data/traffic.db
      - LOG_LEVEL=info
      - JWT_SECRET=${JWT_SECRET} # 配置 token 密钥，建议改成随机字符串
    ports:
      - "127.0.0.1:\${PORT}:8080"
    volumes:
      - ./data:/app/data
      - ./subscribes:/app/subscribes
      - ./rule_templates:/app/rule_templates
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8080/"]
      interval: 30s
      timeout: 3s
      start_period: 5s
      retries: 3
EOF

  cd "$APP_DIR"
  docker compose up -d

  echo -e "${GREEN}✅ 喵喵屋已安装并启动${RESET}"
  echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
  echo -e "${GREEN}🔑 JWT 密钥: ${JWT_SECRET}${RESET}"
  echo -e "${GREEN}📂 数据目录: ${APP_DIR}/data${RESET}"
  read -p "按回车返回菜单..."
  menu
}

update_app() {
  cd "$APP_DIR" || { echo "❌ 未检测到安装目录"; sleep 1; menu; }
  docker compose pull
  docker compose up -d
  echo -e "${GREEN}✅ 喵喵屋已更新并重启${RESET}"
  read -p "按回车返回菜单..."
  menu
}

restart_app() {
  cd "$APP_DIR" || { echo "❌ 未检测到安装目录"; sleep 1; menu; }
  docker compose restart
  echo -e "${GREEN}✅ 喵喵屋已重启${RESET}"
  read -p "按回车返回菜单..."
  menu
}

view_logs() {
  docker logs -f miaomiaowu
  read -p "按回车返回菜单..."
  menu
}

uninstall_app() {
  cd "$APP_DIR" || { echo "❌ 未检测到安装目录"; sleep 1; menu; }
  docker compose down -v
  rm -rf "$APP_DIR"
  echo -e "${RED}✅ 喵喵屋已卸载并删除所有数据${RESET}"
  read -p "按回车返回菜单..."
  menu
}

menu
