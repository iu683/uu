#!/bin/bash
# Sehuatang Crawler 一键管理脚本（支持自定义端口和管理员密码，卸载彻底删除数据）

GREEN="\033[32m"
RESET="\033[0m"

APP_NAME="sehuatang-crawler"
BASE_DIR="/opt/sehuatang"
YML_FILE="$BASE_DIR/docker-compose.yml"

# 默认端口和密码
DEFAULT_PORT=8000
DEFAULT_ADMIN_PASS="admin123"

# 获取公网IP
get_ip() {
    curl -s ipv4.icanhazip.com || curl -s ifconfig.me
}

create_compose() {
    local port=$1
    local admin_pass=$2

    mkdir -p "$BASE_DIR"

    cat > $YML_FILE <<EOF
version: '3.8'

services:
  sehuatang-crawler:
    image: wyh3210277395/sehuatang-crawler:latest
    container_name: sehuatang-crawler
    ports:
      - "${port}:${port}"
    environment:
      - DATABASE_HOST=postgres
      - DATABASE_PORT=5432
      - DATABASE_NAME=sehuatang_db
      - DATABASE_USER=postgres
      - DATABASE_PASSWORD=postgres123
      - PYTHONPATH=/app/backend
      - ENVIRONMENT=production
      - ADMIN_PASSWORD=${admin_pass}
    volumes:
      - sehuatang_data:/app/data
      - sehuatang_logs:/app/logs
    depends_on:
      - postgres
    restart: unless-stopped

  postgres:
    image: postgres:15-alpine
    container_name: sehuatang-postgres
    ports:
      - "5432:5432"
    environment:
      - POSTGRES_DB=sehuatang_db
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=postgres123
    volumes:
      - postgres_data:/var/lib/postgresql/data
    restart: unless-stopped

volumes:
  sehuatang_data:
  sehuatang_logs:
  postgres_data:

networks:
  default:
    name: sehuatang-network
EOF
}

show_menu() {
    echo -e "${GREEN}=== Sehuatang 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装并启动服务${RESET}"
    echo -e "${GREEN}2) 停止服务${RESET}"
    echo -e "${GREEN}3) 启动服务${RESET}"
    echo -e "${GREEN}4) 重启服务${RESET}"
    echo -e "${GREEN}5) 更新服务${RESET}"
    echo -e "${GREEN}6) 查看爬虫日志${RESET}"
    echo -e "${GREEN}7) 卸载服务（含数据）${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}========================${RESET}"
    read -p "请选择: " choice
}

print_access_info() {
    local ip=$(get_ip)
    echo -e "🌐 访问地址: ${GREEN}http://$ip:${PORT}${RESET}"
    echo -e "👤 管理员密码: ${GREEN}${ADMIN_PASSWORD}${RESET}"
}

install_app() {
    read -p "请输入映射端口 (默认 ${DEFAULT_PORT}): " PORT
    PORT=${PORT:-$DEFAULT_PORT}
    read -p "请输入管理员密码 (默认 ${DEFAULT_ADMIN_PASS}): " ADMIN_PASSWORD
    ADMIN_PASSWORD=${ADMIN_PASSWORD:-$DEFAULT_ADMIN_PASS}

    create_compose "$PORT" "$ADMIN_PASSWORD"
    docker compose -f $YML_FILE up -d
    echo -e "✅ ${GREEN}Sehuatang 服务已安装并启动${RESET}"
    print_access_info
}

stop_app() {
    docker compose -f $YML_FILE down
    echo -e "🛑 ${GREEN}Sehuatang 服务已停止${RESET}"
}

start_app() {
    docker compose -f $YML_FILE up -d
    echo -e "🚀 ${GREEN}Sehuatang 服务已启动${RESET}"
    print_access_info
}

restart_app() {
    docker compose -f $YML_FILE down
    docker compose -f $YML_FILE up -d
    echo -e "🔄 ${GREEN}Sehuatang 服务已重启${RESET}"
    print_access_info
}

update_app() {
    docker compose -f $YML_FILE pull
    docker compose -f $YML_FILE up -d
    echo -e "⬆️ ${GREEN}Sehuatang 服务已更新到最新版本${RESET}"
    print_access_info
}

logs_app() {
    docker logs -f $APP_NAME
}

uninstall_app() {
    docker compose -f $YML_FILE down
    rm -f $YML_FILE
    # 删除数据卷
    docker volume rm sehuatang_data sehuatang_logs postgres_data
    echo -e "🗑️ ${GREEN}Sehuatang 服务已卸载，所有数据已删除${RESET}"
}

while true; do
    show_menu
    case $choice in
        1) install_app ;;
        2) stop_app ;;
        3) start_app ;;
        4) restart_app ;;
        5) update_app ;;
        6) logs_app ;;
        7) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "❌ ${GREEN}无效选择${RESET}" ;;
    esac
done
