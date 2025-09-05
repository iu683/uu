#!/bin/bash
set -euo pipefail

GREEN="\033[32m"
RESET="\033[0m"

COMPOSE_FILE="docker-compose.redis.yml"

# 获取公网 IP
get_ip() {
  curl -s https://api.ipify.org || echo "服务器IP"
}

# ==================== 基础功能 ====================
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

download_configs() {
  echo -e "${GREEN}正在下载配置文件...${RESET}"
  curl -fsSLO https://raw.githubusercontent.com/katelya77/KatelyaTV/main/docker-compose.redis.yml
  curl -fsSLO https://raw.githubusercontent.com/katelya77/KatelyaTV/main/.env.redis.example
}

config_env() {
  echo -e "${GREEN}请输入管理员账号 (默认：admin)：${RESET}"
  read -r USERNAME
  USERNAME=${USERNAME:-admin}

  echo -e "${GREEN}请输入管理员密码 (留空则随机生成)：${RESET}"
  read -r ADMIN_PASSWORD
  if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 16)
    echo -e "${GREEN}已生成随机管理员密码：${ADMIN_PASSWORD}${RESET}"
  fi

  echo -e "${GREEN}是否允许用户注册？(true/false，默认 true)：${RESET}"
  read -r ENABLE_REGISTER
  ENABLE_REGISTER=${ENABLE_REGISTER:-true}

  echo -e "${GREEN}请输入站点访问密码 (留空则随机生成)：${RESET}"
  read -r SITE_PASSWORD
  if [ -z "$SITE_PASSWORD" ]; then
    SITE_PASSWORD=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 12)
    echo -e "${GREEN}已生成随机站点访问密码：${SITE_PASSWORD}${RESET}"
  fi

  NEXTAUTH_SECRET=$(openssl rand -base64 32)
  NEXTAUTH_URL="http://$(get_ip):3000"

  # 合并官方模板和自定义变量
  cat > .env <<EOF
# ==================== 管理员账号 ====================
USERNAME=${USERNAME}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
NEXT_PUBLIC_ENABLE_REGISTER=${ENABLE_REGISTER}

# ==================== 站点访问密码 ====================
PASSWORD=${SITE_PASSWORD}

EOF

  # 追加官方模板内容
  grep -v -E "^USERNAME=|^ADMIN_PASSWORD=|^NEXT_PUBLIC_ENABLE_REGISTER=|^PASSWORD=" .env.redis.example >> .env

  # 替换关键字段
  sed -i "s|NEXTAUTH_SECRET=.*|NEXTAUTH_SECRET=${NEXTAUTH_SECRET}|" .env
  sed -i "s|NEXTAUTH_URL=.*|NEXTAUTH_URL=${NEXTAUTH_URL}|" .env
  sed -i "s|REDIS_URL=.*|REDIS_URL=redis://katelyatv-redis:6379|" .env
  sed -i "s|NEXT_PUBLIC_STORAGE_TYPE=.*|NEXT_PUBLIC_STORAGE_TYPE=redis|" .env
}

install_service() {
  install_docker
  download_configs
  config_env
  docker compose -f $COMPOSE_FILE up -d
  echo -e "${GREEN}✅ 部署完成${RESET}"
  echo -e "访问地址: ${GREEN}http://$(get_ip):3000${RESET}"
  echo -e "管理员账号: ${GREEN}${USERNAME}${RESET}"
  echo -e "管理员密码: ${GREEN}${ADMIN_PASSWORD}${RESET}"
  echo -e "站点访问密码: ${GREEN}${SITE_PASSWORD}${RESET}"
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
  echo -e "${GREEN}⚠️ 确定要卸载 KatelyaTV 并清理数据吗？(y/N)${RESET}"
  read -r CONFIRM
  if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
    echo -e "${GREEN}正在清理 Redis 数据...${RESET}"
    docker exec -it katelyatv-redis redis-cli FLUSHALL || true
    echo -e "${GREEN}正在停止并删除容器...${RESET}"
    docker compose -f $COMPOSE_FILE down -v
    echo -e "${GREEN}正在删除配置文件...${RESET}"
    rm -f $COMPOSE_FILE .env .env.redis.example
    echo -e "${GREEN}✅ 已彻底卸载并清理${RESET}"
  else
    echo -e "${GREEN}已取消${RESET}"
  fi
}

status_service() {
  echo -e "${GREEN}容器运行状态:${RESET}"
  docker ps --filter "name=katelyatv" --filter "name=katelyatv-redis"
  echo -e "\n${GREEN}资源占用:${RESET}"
  docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
  echo -e "\n${GREEN}站点访问密码: ${SITE_PASSWORD}${RESET}"
}

# ==================== 菜单 ====================
show_menu() {
  echo -e "
${GREEN}=== KatelyaTV 管理菜单 ===${RESET}
${GREEN}1) 安装 / 部署${RESET}
${GREEN}2) 重启服务${RESET}
${GREEN}3) 查看日志${RESET}
${GREEN}4) 更新服务${RESET}
${GREEN}5) 卸载服务${RESET}
${GREEN}6) 查看状态${RESET}
${GREEN}0) 退出${RESET}
"
}

while true; do
  show_menu
  echo -ne "${GREEN}请选择操作: ${RESET}"
  read -r choice
  case $choice in
    1) install_service ;;
    2) restart_service ;;
    3) logs_service ;;
    4) update_service ;;
    5) uninstall_service ;;
    6) status_service ;;
    0) exit 0 ;;
    *) echo -e "${GREEN}无效选择，请重试${RESET}" ;;
  esac
done
