#!/bin/bash
# ========================================
# Redis Docker 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="redis"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

# ==============================
# Docker 检查
# ==============================

check_docker(){

if ! command -v docker &>/dev/null; then
echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
curl -fsSL https://get.docker.com | bash
fi

if ! docker compose version &>/dev/null; then
echo -e "${RED}未检测到 Docker Compose v2${RESET}"
exit 1
fi

}

check_port(){

PORT=$1

if ss -tuln | grep -q ":$PORT "; then
echo -e "${RED}端口 $PORT 已被占用${RESET}"
return 1
fi

}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。"
}

# ==============================
# Redis 启动检测
# ==============================

check_redis(){

echo -e "${YELLOW}检测 Redis 是否启动...${RESET}"

sleep 5

if docker ps | grep -q redis-server; then
echo -e "${GREEN}✅ Redis 启动成功${RESET}"
else
echo -e "${RED}❌ Redis 启动失败${RESET}"
echo "查看日志: docker logs redis-server"
fi

}

# ==============================
# 菜单
# ==============================

menu(){

while true; do

clear

echo -e "${GREEN}====== Redis 管理菜单 ======${RESET}"
echo -e "${GREEN}1) 安装启动${RESET}"
echo -e "${GREEN}2) 重启${RESET}"
echo -e "${GREEN}3) 更新${RESET}"
echo -e "${GREEN}4) 查看日志${RESET}"
echo -e "${GREEN}5) 查看状态${RESET}"
echo -e "${GREEN}6) 卸载${RESET}"
echo -e "${GREEN}0) 退出${RESET}"

read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

case $choice in
1) install_app ;;
2) restart_app ;;
3) update_app ;;
4) view_logs ;;
5) check_status ;;
6) uninstall_app ;;
0) exit 0 ;;
*) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
esac

done

}

# ==============================
# 安装
# ==============================

install_app(){

check_docker

mkdir -p "$APP_DIR"

read -p "请输入 Redis 端口 [默认:6379]: " input_port
PORT=${input_port:-6379}

check_port "$PORT" || return

read -p "请输入 Redis 密码 [默认:redis123]: " REDIS_PASS
REDIS_PASS=${REDIS_PASS:-redis123}

cat > "$COMPOSE_FILE" <<EOF
services:
  redis:
    image: redis:7
    container_name: redis-server
    restart: always
    ports:
      - "${PORT}:6379"
    command: redis-server --requirepass ${REDIS_PASS}
    volumes:
      - ./data:/data
EOF

cd "$APP_DIR"

docker compose up -d

check_redis

echo
echo -e "${GREEN}✅ Redis 安装完成${RESET}"
echo -e "${YELLOW}地址: ${SERVER_IP}:${PORT}${RESET}"
echo -e "${YELLOW}密码: ${REDIS_PASS}${RESET}"
echo -e "${YELLOW}目录: ${APP_DIR}${RESET}"

read -p "按回车返回菜单..."

}

# ==============================
# 重启
# ==============================

restart_app(){

cd "$APP_DIR"

docker compose restart

echo -e "${GREEN}✅ Redis 已重启${RESET}"

read -p "回车返回"

}

# ==============================
# 更新
# ==============================

update_app(){

cd "$APP_DIR"

docker compose pull
docker compose up -d

echo -e "${GREEN}✅ Redis 更新完成${RESET}"

read -p "回车返回"

}

# ==============================
# 日志
# ==============================

view_logs(){

docker logs -f redis-server

}

# ==============================
# 状态
# ==============================

check_status(){

docker ps | grep redis-server

read -p "回车返回"

}

# ==============================
# 卸载
# ==============================

uninstall_app(){

cd "$APP_DIR"

docker compose down -v

rm -rf "$APP_DIR"

echo -e "${RED}✅ Redis 已彻底卸载${RESET}"

read -p "回车返回"

}

menu
