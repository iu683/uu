#!/bin/bash
# ================== 一键部署/管理异次元发卡 ==================
# 功能：Docker 部署 ACGFaka，带 MySQL、Redis、OPcache，加速
# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ================== 检查 root ==================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 用户运行此脚本！${RESET}"
    exit 1
fi

# ================== 检查 Docker ==================
if ! command -v docker >/dev/null 2>&1; then
    echo -e "${YELLOW}Docker 未安装，正在安装...${RESET}"
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
fi

if ! command -v docker-compose >/dev/null 2>&1; then
    echo -e "${YELLOW}docker-compose 未安装，正在安装...${RESET}"
    apt update -y
    apt install -y docker-compose
fi

# ================== 配置路径 ==================
INSTALL_DIR=~/acgfaka
mkdir -p $INSTALL_DIR/{mysql,acgfaka}

# ================== 状态检测函数 ==================
check_status() {
    cd $INSTALL_DIR
    echo -e "${GREEN}===== 当前服务状态 =====${RESET}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    # 检测 Redis
    if docker exec -it acgfaka php -r "echo extension_loaded('redis') ? '已启用' : '未启用';" &>/dev/null; then
        REDIS_STATUS="已启用"
    else
        REDIS_STATUS="未启用"
    fi

    # 检测 OPcache
    if docker exec -it acgfaka php -r "echo ini_get('opcache.enable') ? '已启用' : '未启用';" &>/dev/null; then
        OPCACHE_STATUS="已启用"
    else
        OPCACHE_STATUS="未启用"
    fi

    echo -e "${GREEN}Redis 扩展: ${REDIS_STATUS}${RESET}"
    echo -e "${GREEN}OPcache 扩展: ${OPCACHE_STATUS}${RESET}"
    echo -e "${GREEN}数据库地址: mysql${RESET}"
    echo -e "${GREEN}数据库名称: acgfakadb${RESET}"
    echo -e "${GREEN}数据库账号: acgfakauser${RESET}"
    echo -e "${GREEN}数据库密码: ${MYSQL_PASSWORD:-未设置}${RESET}"
    echo -e "${GREEN}=======================${RESET}"
}

# ================== 菜单函数 ==================
show_menu() {
    while true; do
        echo -e "${GREEN}===== 异次元发卡 Docker 管理菜单 =====${RESET}"
        echo -e "${GREEN}1. 安装/启动服务${RESET}"
        echo -e "${GREEN}2. 停止服务${RESET}"
        echo -e "${GREEN}3. 重启服务${RESET}"
        echo -e "${GREEN}4. 查看日志${RESET}"
        echo -e "${GREEN}5. 更新服务${RESET}"
        echo -e "${GREEN}6. 卸载服务及数据${RESET}"
        echo -e "${GREEN}7. 查看状态（含 Redis/OPcache/数据库信息）${RESET}"
        echo -e "${GREEN}8. 退出${RESET}"
        read -p "请选择操作: " choice
        case $choice in
            1)
                # ===== 输入配置（只在安装时执行） =====
                read -p "请输入网站端口（默认 9000）: " WEB_PORT
                WEB_PORT=${WEB_PORT:-9000}

                read -p "请输入 MySQL root 密码（默认 rootpassword）: " MYSQL_ROOT_PASSWORD
                MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-rootpassword}

                read -p "请输入 MySQL 数据库密码（默认 acgfakapassword）: " MYSQL_PASSWORD
                MYSQL_PASSWORD=${MYSQL_PASSWORD:-acgfakapassword}

                # ===== 生成 docker-compose.yaml =====
                cat > $INSTALL_DIR/docker-compose.yaml <<EOF

services:
  acgfaka:
    image: dapiaoliang666/acgfaka
    ports:
      - "127.0.0.1:$WEB_PORT:80"
    depends_on:
      - mysql
      - redis
    restart: always
    environment:
      PHP_OPCACHE_ENABLE: 1
      PHP_OPCACHE_MEMORY_CONSUMPTION: 128
      PHP_OPCACHE_MAX_ACCELERATED_FILES: 10000
      PHP_OPCACHE_REVALIDATE_FREQ: 2
      PHP_REDIS_HOST: redis
      PHP_REDIS_PORT: 6379
    volumes:
      - ./acgfaka:/var/www/html

  mysql:
    image: mysql:5.7
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: acgfakadb
      MYSQL_USER: acgfakauser
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - ./mysql:/var/lib/mysql
    restart: always

  redis:
    image: redis:latest
    restart: always
EOF

                cd $INSTALL_DIR
                docker compose up -d
                IP=$(curl -s ifconfig.me)
                echo -e "${GREEN}网站访问地址: http://127.0.0.1:$WEB_PORT${RESET}"
                echo -e "${GREEN}后台路径: http://127.0.0.1:$WEB_PORT/admin${RESET}"
                echo -e "${GREEN}数据库地址: mysql${RESET}"
                echo -e "${GREEN}数据库名称: acgfakadb${RESET}"
                echo -e "${GREEN}数据库账号: acgfakauser${RESET}"
                echo -e "${GREEN}数据库密码: ${MYSQL_PASSWORD}${RESET}"
                read -p "回车返回菜单..."
                ;;
            2)
                cd $INSTALL_DIR
                docker compose stop
                read -p "回车返回菜单..."
                ;;
            3)
                cd $INSTALL_DIR
                docker compose restart
                read -p "回车返回菜单..."
                ;;
            4)
                cd $INSTALL_DIR
                docker compose logs -f
                read -p "回车返回菜单..."
                ;;
            5)
                cd $INSTALL_DIR
                docker compose pull
                docker compose up -d
                echo -e "${GREEN}已更新到最新镜像并重启服务${RESET}"
                read -p "回车返回菜单..."
                ;;
            6)
                read -p "确认卸载？此操作将删除容器和所有数据！(y/n): " yn
                if [[ $yn == "y" || $yn == "Y" ]]; then
                    cd $INSTALL_DIR
                    docker compose down -v
                    rm -rf $INSTALL_DIR
                    echo -e "${GREEN}已完全卸载！${RESET}"
                    exit
                fi
                ;;
            7)
                check_status
                read -p "回车返回菜单..."
                ;;
            8)
                exit
                ;;
            *)
                echo -e "${RED}无效选项！${RESET}"
                ;;
        esac
    done
}

# ================== 执行菜单 ==================
show_menu
