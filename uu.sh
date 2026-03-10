#!/bin/bash
# ========================================
# PPanel + MySQL + Redis 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="ppanel"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_DIR="$APP_DIR/config"

# ==============================
# Docker 检测
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

if ss -tlnp | grep -q ":$1 "; then
echo -e "${RED}端口 $1 已被占用${RESET}"
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
# 菜单
# ==============================

menu(){

while true; do

clear

echo -e "${GREEN}===== PPanel 管理菜单 =====${RESET}"
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

mkdir -p "$CONFIG_DIR"
mkdir -p "$APP_DIR/web"

read -p "请输入 Web 端口 [默认:8080]: " input_port
PORT=${input_port:-8080}

check_port "$PORT" || return

read -p "MySQL 用户名 [默认:ppanel]: " MYSQL_USER
MYSQL_USER=${MYSQL_USER:-ppanel}

read -p "MySQL 密码 [默认:ppanel123]: " MYSQL_PASS
MYSQL_PASS=${MYSQL_PASS:-ppanel123}

read -p "Redis 密码 [默认:redis123]: " REDIS_PASS
REDIS_PASS=${REDIS_PASS:-redis123}

# ======================
# 生成配置
# ======================

SECRET=$(openssl rand -hex 16)

cat > "$CONFIG_DIR/ppanel.yaml" <<EOF
Host: 0.0.0.0
Port: 8080

TLS:
  Enable: false
  CertFile: ""
  KeyFile: ""

Debug: false

Static:
  Admin:
    Enabled: true
    Prefix: /admin
    Path: ./static/admin
  User:
    Enabled: true
    Prefix: /
    Path: ./static/user

JwtAuth:
  AccessSecret: ${SECRET}
  AccessExpire: 604800

Logger:
  ServiceName: ApiService
  Mode: console
  Encoding: plain
  Path: logs
  Level: info

MySQL:
  Addr: mysql:3306
  Username: ${MYSQL_USER}
  Password: ${MYSQL_PASS}
  Dbname: ppanel
  Config: charset=utf8mb4&parseTime=true&loc=Asia%2FShanghai

Redis:
  Host: redis:6379
  Pass: ${REDIS_PASS}
  DB: 0
EOF

# ======================
# docker compose
# ======================

cat > "$COMPOSE_FILE" <<EOF
services:

  ppanel:
    image: ppanel/ppanel:latest
    container_name: ppanel
    restart: always
    ports:
      - "${PORT}:8080"
    volumes:
      - ./config:/app/etc
      - ./web:/app/static
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_started

  mysql:
    image: mysql:8
    container_name: ppanel-mysql
    restart: always
    environment:
      MYSQL_DATABASE: ppanel
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASS}
      MYSQL_ROOT_PASSWORD: ${MYSQL_PASS}
    volumes:
      - ./mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-p${MYSQL_PASS}"]
      interval: 10s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7
    container_name: ppanel-redis
    restart: always
    command: redis-server --requirepass ${REDIS_PASS}
    volumes:
      - ./redis:/data

EOF

cd "$APP_DIR"

docker compose up -d

SERVER_IP=$(get_public_ip)


echo
echo -e "${GREEN}✅ PPanel 已安装完成${RESET}"
echo -e "${YELLOW}访问地址:${RESET}"
echo -e "${YELLOW}http://${SERVER_IP}:${PORT}${RESET}"
echo
echo -e "${YELLOW}后台:${RESET}"
echo -e "${YELLOW}http://${SERVER_IP}:${PORT}/admin${RESET}"
echo
echo -e "${YELLOW}安装目录: $APP_DIR${RESET}"

read -p "按回车返回菜单..."

}

# ==============================
# 重启
# ==============================

restart_app(){

cd "$APP_DIR"

docker compose restart

echo -e "${GREEN}服务已重启${RESET}"

read -p "回车返回"

}

# ==============================
# 更新
# ==============================

update_app(){

cd "$APP_DIR"

docker compose pull
docker compose up -d

echo -e "${GREEN}更新完成${RESET}"

read -p "回车返回"

}

# ==============================
# 日志
# ==============================

view_logs(){

docker logs -f ppanel

}

# ==============================
# 状态
# ==============================

check_status(){

docker ps | grep ppanel

read -p "回车返回"

}

# ==============================
# 卸载
# ==============================

uninstall_app(){

cd "$APP_DIR"

docker compose down -v

rm -rf "$APP_DIR"

echo -e "${RED}PPanel 已彻底卸载${RESET}"

read -p "回车返回"

}

menu
