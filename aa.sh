#!/bin/bash

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

# ================== 变量 ==================
COMPOSE_FILE="docker-compose.yaml"
SERVICE_NAME="neko"

# ================== 获取公网IP ==================
get_ip() {
  curl -s ifconfig.me || curl -s ipinfo.io/ip
}

# ================== 部署函数 ==================
deploy() {
  read -p "请输入Web访问端口 (默认8080): " WEB_PORT
  WEB_PORT=${WEB_PORT:-8080}

  read -p "请输入普通用户密码 (默认: stronguser): " USER_PASS
  USER_PASS=${USER_PASS:-stronguser}

  read -p "请输入管理员密码 (默认: strongadmin): " ADMIN_PASS
  ADMIN_PASS=${ADMIN_PASS:-strongadmin}

  PUBLIC_IP=$(get_ip)

  cat > $COMPOSE_FILE <<EOF
version: '3.8'

services:
  ${SERVICE_NAME}:
    image: ghcr.io/m1k1o/neko/firefox:latest
    container_name: ${SERVICE_NAME}
    restart: unless-stopped
    ports:
      - "${WEB_PORT}:8080"
      - "56000-56100:56000-56100/udp"
    environment:
      NEKO_WEBRTC_EPR: "56000-56100"
      NEKO_WEBRTC_NAT1TO1: "${PUBLIC_IP}"
      NEKO_MEMBER_MULTIUSER_USER_PASSWORD: "${USER_PASS}"
      NEKO_MEMBER_MULTIUSER_ADMIN_PASSWORD: "${ADMIN_PASS}"
EOF

  echo -e "${GREEN}生成配置完成，开始启动容器...${RESET}"
  docker compose up -d
  echo -e "${GREEN}部署完成！${RESET}"
  echo -e "${GREEN}访问地址: http://${PUBLIC_IP}:${WEB_PORT}${RESET}"
  echo -e "${GREEN}普通用户密码: ${USER_PASS}${RESET}"
  echo -e "${GREEN}管理员密码: ${ADMIN_PASS}${RESET}"
}

# ================== 管理菜单 ==================
while true; do
  echo -e "${GREEN}==============================${RESET}"
  echo -e "${GREEN}      Neko 一键管理脚本       ${RESET}"
  echo -e "${GREEN}==============================${RESET}"
  echo -e "${GREEN}1) 部署/安装${RESET}"
  echo -e "${GREEN}2) 启动${RESET}"
  echo -e "${GREEN}3) 停止${RESET}"
  echo -e "${GREEN}4) 删除 (包含配置)${RESET}"
  echo -e "${GREEN}5) 查看日志${RESET}"
  echo -e "${GREEN}6) 更新 (拉取最新镜像并重启)${RESET}"
  echo -e "${GREEN}7) 退出${RESET}"
  echo -e "${GREEN}==============================${RESET}"

  read -p "请输入选项 [1-7]: " choice
  case $choice in
    1)
      deploy
      ;;
    2)
      docker compose start
      ;;
    3)
      docker compose stop
      ;;
    4)
      docker compose down
      rm -f $COMPOSE_FILE
      echo -e "${RED}Neko 已删除${RESET}"
      ;;
    5)
      docker compose logs -f
      ;;
    6)
      echo -e "${GREEN}开始更新 Neko...${RESET}"
      docker compose pull
      docker compose up -d
      echo -e "${GREEN}更新完成并已重启 Neko${RESET}"
      ;;
    7)
      echo -e "${GREEN}退出脚本${RESET}"
      exit 0
      ;;
    *)
      echo -e "${RED}无效选项，请重新输入${RESET}"
      ;;
  esac
done
