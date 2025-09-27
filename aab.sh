#!/bin/bash

CONTAINER_NAME="gh-proxy-py"
IMAGE_NAME="hunsh/gh-proxy-py:latest"

# 颜色
green="\033[32m"
red="\033[31m"
yellow="\033[33m"
reset="\033[0m"

# 保存端口和数据目录
CONFIG_FILE="$HOME/.gh_proxy_config"

# 获取本机 IP
get_ip() {
  IP=$(hostname -I | awk '{print $1}')
}

menu() {
  clear
  echo -e "${green}====== gh-proxy-py Docker 管理脚本 ======${reset}"
  echo -e "${green}1.${green} 部署并运行容器${reset}"
  echo -e "${green}2.${green} 启动容器${reset}"
  echo -e "${green}3.${green} 停止容器${reset}"
  echo -e "${green}4.${green} 重启容器${reset}"
  echo -e "${green}5.${green} 查看容器日志${reset}"
  echo -e "${green}6.${green} 删除容器${reset}"
  echo -e "${green}7.${green} 更新容器${reset}"
  echo -e "${green}0.${green} 退出${reset}"
  echo -e "${green}=====================================${reset}"
}

# 读取端口和数据目录
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
  else
    read -p "请输入要映射的外部端口 (默认 5569): " PORT
    PORT=${PORT:-5569}
    read -p "请输入数据目录路径 (默认 ~/gh_proxy_data): " DATA_DIR
    DATA_DIR=${DATA_DIR:-$HOME/gh_proxy_data}
    mkdir -p "$DATA_DIR"
    echo "PORT=$PORT" > "$CONFIG_FILE"
    echo "DATA_DIR=$DATA_DIR" >> "$CONFIG_FILE"
  fi
}

deploy_container() {
  load_config
  docker rm -f $CONTAINER_NAME >/dev/null 2>&1
  echo -e "${yellow}正在部署容器，端口: $PORT，数据目录: $DATA_DIR${reset}"
  docker run -d --name="$CONTAINER_NAME" \
    -p 0.0.0.0:$PORT:80 \
    -v "$DATA_DIR":/app/data \
    --restart=always \
    $IMAGE_NAME
  if [ $? -eq 0 ]; then
    get_ip
    echo -e "${green}容器已成功运行！访问地址：http://$IP:$PORT${reset}"
  else
    echo -e "${red}部署失败，请检查 Docker 是否正常运行${reset}"
  fi
}

check_status() {
  if docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    echo -e "${green}容器状态:${reset}"
    docker ps -a --filter "name=$CONTAINER_NAME"
  else
    echo -e "${red}容器 $CONTAINER_NAME 未安装${reset}"
  fi
}

update_image() {
  load_config
  echo -e "${yellow}正在拉取最新镜像...${reset}"
  docker pull $IMAGE_NAME
  echo -e "${yellow}更新完成，正在重新部署...${reset}"
  deploy_container
}

delete_container() {
  load_config
  read -p "是否同时删除数据目录 $DATA_DIR ? [y/N]: " yn
  docker rm -f $CONTAINER_NAME
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    rm -rf "$DATA_DIR"
    rm -f "$CONFIG_FILE"
    echo -e "${green}容器和数据已删除${reset}"
  else
    echo -e "${green}容器已删除，数据保留在 $DATA_DIR${reset}"
  fi
}

while true; do
  menu
  read -p "请选择操作: " choice
  case $choice in
    1) deploy_container ;;
    2) load_config; docker start $CONTAINER_NAME && echo -e "${green}容器已启动${reset}" ;;
    3) docker stop $CONTAINER_NAME && echo -e "${green}容器已停止${reset}" ;;
    4) docker restart $CONTAINER_NAME && echo -e "${green}容器已重启${reset}" ;;
    5) docker logs -f $CONTAINER_NAME ;;
    6) delete_container ;;
    7) update_image ;;
    0) echo -e "${green}退出${reset}"; exit 0 ;;
    *) echo -e "${red}无效选项，请重试${reset}" ;;
  esac
  echo -e "\n按任意键返回菜单..."
  read -n 1
done
