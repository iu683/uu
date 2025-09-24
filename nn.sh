#!/bin/bash

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

# ================== 变量 ==================
SERVICE_NAME="firefox"
COMPOSE_FILE="docker-compose.yaml"
CONFIG_DIR=~/firefox

# ================== 获取公网IP ==================
get_ip() {
  curl -s ifconfig.me || curl -s ipinfo.io/ip
}

# ================== 生成 docker-compose.yaml ==================
generate_compose() {
  cat > $COMPOSE_FILE <<EOF
version: '3.8'

services:
  ${SERVICE_NAME}:
    image: lscr.io/linuxserver/firefox:latest
    container_name: ${SERVICE_NAME}
    restart: unless-stopped
    security_opt:
      - seccomp=unconfined
    environment:
      PUID: 1000
      PGID: 1000
      TZ: Asia/Shanghai
      DOCKER_MODS: linuxserver/mods:universal-package-install
      INSTALL_PACKAGES: fonts-noto-cjk
      LC_ALL: zh_CN.UTF-8
      CUSTOM_USER: "${CUSTOM_USER}"
      PASSWORD: "${PASSWORD}"
    ports:
      - "${WEB_PORT}:3000"
      - "${VNC_PORT}:3001"
    volumes:
      - ${CONFIG_DIR}:/config
    shm_size: 1gb
EOF
}

# ================== 部署函数 ==================
deploy() {
  read -p "请输入Web登录用户名 (默认 admin): " CUSTOM_USER
  CUSTOM_USER=${CUSTOM_USER:-admin}

  read -p "请输入Web登录密码 (默认 123456): " PASSWORD
  PASSWORD=${PASSWORD:-123456}

  read -p "请输入Web UI端口 (默认3000): " WEB_PORT
  WEB_PORT=${WEB_PORT:-3000}

  read -p "请输入VNC端口 (默认3001): " VNC_PORT
  VNC_PORT=${VNC_PORT:-3001}

  mkdir -p $CONFIG_DIR

  generate_compose

  echo -e "${GREEN}生成 docker-compose.yaml 并启动容器...${RESET}"
  docker compose up -d

  echo -e "${GREEN}部署完成！${RESET}"
  echo -e "${GREEN}Web访问: http://$(get_ip):${WEB_PORT}${RESET}"
  echo -e "${GREEN}VNC端口: ${VNC_PORT}${RESET}"
  echo -e "${GREEN}用户名: ${CUSTOM_USER}${RESET}"
  echo -e "${GREEN}密码: ${PASSWORD}${RESET}"
}

# ================== 管理菜单 ==================
while true; do
  echo -e "${GREEN}==============================${RESET}"
  echo -e "${GREEN}       Firefox 容器管理        ${RESET}"
  echo -e "${GREEN}==============================${RESET}"
  echo -e "${GREEN}1) 部署安装${RESET}"
  echo -e "${GREEN}2) 启动${RESET}"
  echo -e "${GREEN}3) 停止${RESET}"
  echo -e "${GREEN}4) 删除 (包含配置)${RESET}"
  echo -e "${GREEN}5) 查看日志${RESET}"
  echo -e "${GREEN}6) 更新${RESET}"
  echo -e "${GREEN}7) 退出${RESET}"
  echo -e "${GREEN}==============================${RESET}"

  read -p "请输入选项 [1-7]: " choice
  case $choice in
    1)
      deploy
      ;;
    2)
      docker compose start
      echo -e "${GREEN}已启动${RESET}"
      ;;
    3)
      docker compose stop
      echo -e "${GREEN}已停止${RESET}"
      ;;
    4)
      docker compose down
      rm -rf $CONFIG_DIR $COMPOSE_FILE
      echo -e "${RED}Firefox 容器已删除${RESET}"
      ;;
    5)
      docker compose logs -f
      ;;
    6)
      echo -e "${GREEN}开始更新 Firefox...${RESET}"
      docker compose pull
      docker compose up -d
      echo -e "${GREEN}更新完成并已重启 Firefox${RESET}"
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
