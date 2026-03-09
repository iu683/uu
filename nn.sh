#!/bin/bash
# ========================================
# FOSS Billing 一键管理脚本（含自动 Cron 配置）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="fossbilling"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

# ==============================
# 基础检测
# ==============================
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2，请升级 Docker${RESET}"
        exit 1
    fi
}

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

# ==============================
# 菜单
# ==============================
menu() {
    while true; do
        clear
        echo -e "${GREEN}=== FOSS Billing 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 重启${RESET}"
        echo -e "${GREEN}3) 更新${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 配置 Cron 定时任务${RESET}" 
        echo -e "${GREEN}7) 卸载（含数据）${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) restart_app ;;
            3) update_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) setup_cron ;;
            7) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

# ==============================
# 安装
# ==============================
install_app() {
    check_docker
    mkdir -p "$APP_DIR"

    # 自定义端口
    read -p "请输入 Web 访问端口 [默认:80]: " input_port
    PORT=${input_port:-80}
    check_port "$PORT" || return

    # 自定义数据库
    read -p "请输入 MySQL 用户名 [默认:fossbilling]: " DB_USER
    DB_USER=${DB_USER:-fossbilling}

    read -p "请输入 MySQL 密码 [默认:fossbilling]: " DB_PASSWORD
    DB_PASSWORD=${DB_PASSWORD:-fossbilling}

    read -p "请输入 MySQL 数据库名 [默认:fossbilling]: " DB_NAME
    DB_NAME=${DB_NAME:-fossbilling}

    cat > "$COMPOSE_FILE" <<EOF

services:
  fossbilling:
    image: fossbilling/fossbilling:latest
    restart: always
    ports:
      - "127.0.0.1:${PORT}:80"
    volumes:
      - fossbilling:/var/www/html
  mysql:
    image: mysql:8.2
    restart: always
    environment:
      MYSQL_DATABASE: $DB_NAME
      MYSQL_USER: $DB_USER
      MYSQL_PASSWORD: $DB_PASSWORD
      MYSQL_RANDOM_ROOT_PASSWORD: '1'
    volumes:
      - mysql:/var/lib/mysql
volumes:
  fossbilling:
  mysql:
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ FOSS Billing 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}✅ 主机名：mysql${RESET}"
    echo -e "${GREEN}✅ 数据库：$DB_NAME${RESET}"
    echo -e "${GREEN}✅ 用户名：$DB_USER${RESET}"
    echo -e "${GREEN}✅ 密码：$DB_PASSWORD${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"

    read -p "按回车返回菜单..."
}

# ==============================
# 重启
# ==============================
restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose restart
    echo -e "${GREEN}✅ FOSS Billing 已重启${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 更新
# ==============================
update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ FOSS Billing 已更新${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 查看日志
# ==============================
view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f fossbilling
}

# ==============================
# 查看状态
# ==============================
check_status() {
    docker ps | grep fossbilling
    read -p "按回车返回菜单..."
}

# ==============================
# 卸载
# ==============================
# ==============================
# 卸载
# ==============================
uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }

    # 获取容器名
    CONTAINER=$(docker ps -a --filter "name=fossbilling" --format "{{.Names}}")
    
    # 删除 cron 定时任务
    if [ -n "$CONTAINER" ]; then
        echo -e "${YELLOW}正在删除与 $CONTAINER 相关的 cron 定时任务...${RESET}"
        crontab -l 2>/dev/null | grep -v "$CONTAINER" | crontab -
        echo -e "${GREEN}✅ Cron 定时任务已删除${RESET}"
    fi

    # 停止并删除容器及数据
    docker compose down -v
    rm -rf "$APP_DIR"

    echo -e "${RED}✅ FOSS Billing 已彻底卸载（含数据和定时任务）${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# Cron 自动配置
# ==============================
setup_cron() {
    # 自动获取容器名
    CONTAINER=$(docker ps --filter "name=fossbilling" --format "{{.Names}}")
    if [ -z "$CONTAINER" ]; then
        echo -e "${RED}未检测到 FOSSBilling 容器，请先启动${RESET}"
        return
    fi

    # 添加 cron，每5分钟执行一次，不重复
    (crontab -l 2>/dev/null; \
     echo "*/5 * * * * docker exec $CONTAINER su www-data -s /usr/local/bin/php /var/www/html/cron.php") \
     | awk '!x[$0]++' \
     | crontab -

    echo -e "${GREEN}✅ Cron 定时任务已配置，每 5 分钟执行一次 FOSSBilling cron.php${RESET}"
    echo -e "${YELLOW}可使用 crontab -l 查看当前 cron 作业${RESET}"
}

# ==============================
# 启动菜单
# ==============================
menu
