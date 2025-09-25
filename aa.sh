#!/bin/bash

# ========== 颜色 ==========
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

# ========== 变量 ==========
CONTAINER_NAME="nodeseeker"
IMAGE_NAME="ersichub/nodeseeker:latest"
DATA_PATH=~/nodeseeker_data
CONFIG_FILE="./nodeseeker.conf"

# ========== 获取公网IP ==========
get_ip() {
  curl -s ifconfig.me || curl -s ipinfo.io/ip
}

# ========== 加载配置 ==========
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
  else
    WEB_PORT=3010
  fi
}

# ========== 保存配置 ==========
save_config() {
  cat > "$CONFIG_FILE" <<EOF
WEB_PORT=${WEB_PORT}
EOF
}

# ========== 部署函数 ==========
deploy() {
  read -p "请输入Web端口 (默认${WEB_PORT}): " input_port
  WEB_PORT=${input_port:-$WEB_PORT}

  mkdir -p $DATA_PATH
  save_config

  echo -e "${GREEN}正在部署 NodeSeeker...${RESET}"
  docker run -d \
    --name $CONTAINER_NAME \
    -p ${WEB_PORT}:3010 \
    -v $DATA_PATH:/usr/src/app/data \
    --restart unless-stopped \
    $IMAGE_NAME

  echo -e "${GREEN}部署完成！${RESET}"
  echo -e "${GREEN}访问地址: http://$(get_ip):${WEB_PORT}${RESET}"
}

# ========== 更新函数 ==========
update() {
  echo -e "${GREEN}开始更新 NodeSeeker...${RESET}"
  docker pull $IMAGE_NAME
  docker rm -f $CONTAINER_NAME >/dev/null 2>&1
  # 使用保存的端口，直接重建容器
  docker run -d \
    --name $CONTAINER_NAME \
    -p ${WEB_PORT}:3010 \
    -v $DATA_PATH:/usr/src/app/data \
    --restart unless-stopped \
    $IMAGE_NAME
  echo -e "${GREEN}更新完成！访问地址: http://$(get_ip):${WEB_PORT}${RESET}"
}

# ========== 卸载函数 ==========
uninstall() {
  docker rm -f $CONTAINER_NAME >/dev/null 2>&1
  rm -rf $DATA_PATH $CONFIG_FILE
  echo -e "${RED}NodeSeeker 已彻底卸载，数据和配置已删除${RESET}"
}

# ========== 菜单 ==========
load_config
while true; do
  echo -e "${GREEN}==============================${RESET}"
  echo -e "${GREEN}       NodeSeeker 管理        ${RESET}"
  echo -e "${GREEN}==============================${RESET}"
  echo -e "${GREEN}1) 部署安装${RESET}"
  echo -e "${GREEN}2) 启动${RESET}"
  echo -e "${GREEN}3) 停止${RESET}"
  echo -e "${GREEN}4) 卸载${RESET}"
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
      docker start $CONTAINER_NAME
      echo -e "${GREEN}已启动${RESET}"
      ;;
    3)
      docker stop $CONTAINER_NAME
      echo -e "${GREEN}已停止${RESET}"
      ;;
    4)
      uninstall
      ;;
    5)
      docker logs -f $CONTAINER_NAME
      ;;
    6)
      update
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
