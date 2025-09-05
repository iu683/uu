#!/bin/bash
set -euo pipefail

GREEN="\033[32m"
RESET="\033[0m"

COMPOSE_FILE="docker-compose.redis.yml"

# 获取公网 IP
get_ip() {
  curl -s https://api.ipify.org || echo "服务器IP"
}

# -----------------------------
# 功能函数
# -----------------------------
install_docker() {
  if ! command -v docker &>/dev/null; then
    echo -e "${GREEN}未检测到 Docker，正在安装...${RESET}"
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
  fi

  if ! command -v docker compose &>/dev/null; then
    echo -e "${GREEN}未检测到 Docker Compose，正在安装...${RESET}"
    DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
    mkdir -p $DOCKER_CONFIG/cli-plugins
    curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m) \
      -o $DOCKER_CONFIG/cli-plugins/docker-compose
    chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose
    ln -sf $DOCKER_CONFIG/cli-plugins/docker-compose /usr/local/bin/docker-compose || true
  fi
}

install_service() {
  echo -e "${GREEN}正在下载配置文件...${RESET}"
  curl -fsSLO https://raw.githubusercontent.com/katelya77/KatelyaTV/main/docker-compose.redis.yml
  curl -fsSLO https://raw.githubusercontent.com/katelya77/KatelyaTV/main/.env.redis.example
  cp -n .env.redis.example .env

  echo -e "${GREEN}请输入管理员账号 (默认：admin)：${RESET}"
  read -r USERNAME
  USERNAME=${USERNAME:-admin}

  echo -e "${GREEN}请输入管理员密码 (留空则随机生成)：${RESET}"
  read -r PASSWORD
  if [ -z "$PASSWORD" ]; then
    PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    echo -e "${GREEN}已生成随机密码：${PASSWORD}${RESET}"
  fi

  echo -e "${GREEN}是否允许用户注册？(true/false，默认 true)：${RESET}"
  read -r ENABLE_REGISTER
  ENABLE_REGISTER=${ENABLE_REGISTER:-true}

  sed -i "s/^USERNAME=.*/USERNAME=${USERNAME}/" .env
  sed -i "s/^PASSWORD=.*/PASSWORD=${PASSWORD}/" .env
  sed -i "s|^NEXT_PUBLIC_ENABLE_REGISTER=.*|NEXT_PUBLIC_ENABLE_REGISTER=${ENABLE_REGISTER}|" .env
  sed -i "s|^REDIS_URL=.*|REDIS_URL=redis://katelyatv-redis:6379|" .env
  sed -i "s|^NEXT_PUBLIC_STORAGE_TYPE=.*|NEXT_PUBLIC_STORAGE_TYPE=redis|" .env

  docker compose -f $COMPOSE_FILE up -d
  echo -e "${GREEN}✅ 部署完成${RESET}"
  echo -e "访问地址: ${GREEN}http://$(get_ip):3000${RESET}"
  echo -e "账号: ${GREEN}${USERNAME}${RESET}"
  echo -e "密码: ${GREEN}${PASSWORD}${RESET}"
  echo -e "注册功能: ${GREEN}${ENABLE_REGISTER}${RESET}"
}

restart_service() {
  echo -e "${GREEN}正在重启服务...${RESET}"
  docker compose -f $COMPOSE_FILE restart
  echo -e "${GREEN}✅ 重启完成${RESET}"
}

logs_service() {
  echo -e "${GREEN}正在查看日志 (Ctrl+C 退出)...${RESET}"
  docker compose -f $COMPOSE_FILE logs -f
}

update_service() {
  echo -e "${GREEN}正在更新服务镜像...${RESET}"
  docker compose -f $COMPOSE_FILE pull
  docker compose -f $COMPOSE_FILE up -d
  echo -e "${GREEN}✅ 更新完成${RESET}"
}

uninstall_service() {
  echo -e "${GREEN}⚠️ 确定要卸载 KatelyaTV 吗？(y/N)${RESET}"
  read -r CONFIRM
  if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
    docker compose -f $COMPOSE_FILE down -v
    rm -f $COMPOSE_FILE .env .env.redis.example
    echo -e "${GREEN}✅ 已卸载${RESET}"
  else
    echo -e "${GREEN}已取消${RESET}"
  fi
}

# -----------------------------
# 菜单
# -----------------------------
show_menu() {
  echo -e "
${GREEN}=== KatelyaTV 管理菜单 ===${RESET}
${GREEN}1) 安装 / 部署${RESET}
${GREEN}2) 重启服务${RESET}
${GREEN}3) 查看日志${RESET}
${GREEN}4) 更新服务${RESET}
${GREEN}5) 卸载服务${RESET}
${GREEN}0) 退出${RESET}
"
}

while true; do
  show_menu
  echo -ne "${GREEN}请选择操作: ${RESET}"
  read -r choice
  case $choice in
    1) install_docker && install_service ;;
    2) restart_service ;;
    3) logs_service ;;
    4) update_service ;;
    5) uninstall_service ;;
    0) exit 0 ;;
    *) echo -e "${GREEN}无效选择，请重试${RESET}" ;;
  esac
done
