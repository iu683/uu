#!/bin/bash

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

# ================== 变量 ==================
SERVICE_NAME="firefox"
CONFIG_DIR=~/firefox

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

  echo -e "${GREEN}开始部署 Firefox 容器...${RESET}"

  docker run -d \
    --name=$SERVICE_NAME \
    --security-opt seccomp=unconfined \
    -e PUID=1000 \
    -e PGID=1000 \
    -e TZ=Asia/Shanghai \
    -e DOCKER_MODS=linuxserver/mods:universal-package-install \
    -e INSTALL_PACKAGES=fonts-noto-cjk \
    -e LC_ALL=zh_CN.UTF-8 \
    -e CUSTOM_USER="$CUSTOM_USER" \
    -e PASSWORD="$PASSWORD" \
    -p ${WEB_PORT}:3000 \
    -p ${VNC_PORT}:3001 \
    -v $CONFIG_DIR:/config \
    --shm-size="1gb" \
    --restart unless-stopped \
    lscr.io/linuxserver/firefox:latest

  echo -e "${GREEN}部署完成！${RESET}"
  echo -e "${GREEN}Web访问: http://$(curl -s ifconfig.me):${WEB_PORT}${RESET}"
  echo -e "${GREEN}VNC端口: ${VNC_PORT}${RESET}"
  echo -e "${GREEN}用户名: ${CUSTOM_USER}${RESET}"
  echo -e "${GREEN}密码: ${PASSWORD}${RESET}"
}

# ================== 管理菜单 ==================
while true; do
  echo -e "${GREEN}==============================${RESET}"
  echo -e "${GREEN}       Firefox 容器管理        ${RESET}"
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
      docker start $SERVICE_NAME
      echo -e "${GREEN}已启动${RESET}"
      ;;
    3)
      docker stop $SERVICE_NAME
      echo -e "${GREEN}已停止${RESET}"
      ;;
    4)
      docker stop $SERVICE_NAME
      docker rm $SERVICE_NAME
      rm -rf $CONFIG_DIR
      echo -e "${RED}Firefox 容器已删除${RESET}"
      ;;
    5)
      docker logs -f $SERVICE_NAME
      ;;
    6)
      echo -e "${GREEN}开始更新 Firefox...${RESET}"
      docker pull lscr.io/linuxserver/firefox:latest
      docker stop $SERVICE_NAME
      docker rm $SERVICE_NAME
      echo -e "${GREEN}重新部署最新镜像...${RESET}"
      deploy
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
