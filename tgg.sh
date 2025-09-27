#!/bin/bash
# =========================================
# DNSMgr Docker 管理脚本 (显示访问信息)
# =========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

COMPOSE_FILE="./docker-compose.yml"
WEB_DIR="./web"
MYSQL_CONF_DIR="./mysql/conf"
MYSQL_LOGS_DIR="./mysql/logs"
MYSQL_DATA_DIR="./mysql/data"
NETWORK_NAME="dnsmgr-network"

MYSQL_ROOT_PASSWORD="554751"
MYSQL_DB_NAME="dnsmgr"

# 检查端口是否被占用
function check_port() {
    local port=$1
    if lsof -i:"$port" &>/dev/null; then
        return 1
    else
        return 0
    fi
}

# 创建目录
function create_dirs() {
    mkdir -p "$WEB_DIR" "$MYSQL_CONF_DIR" "$MYSQL_LOGS_DIR" "$MYSQL_DATA_DIR"
}

# 生成 my.cnf
function generate_my_cnf() {
    local cnf_file="$MYSQL_CONF_DIR/my.cnf"
    if [ ! -f "$cnf_file" ]; then
        cat > "$cnf_file" <<'EOF'
[mysqld]
sql_mode=STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION
EOF
    fi
}

# 生成 docker-compose.yml
function generate_docker_compose() {
    local web_port="$1"
    cat > "$COMPOSE_FILE" <<EOF
version: '3'
services:
  dnsmgr-web:
    container_name: dnsmgr-web
    stdin_open: true
    tty: true
    ports:
      - ${web_port}:80
    volumes:
      - ./web:/app/www
    image: netcccyun/dnsmgr
    depends_on:
      - dnsmgr-mysql
    networks:
      - $NETWORK_NAME

  dnsmgr-mysql:
    container_name: dnsmgr-mysql
    restart: always
    ports:
      - 3306:3306
    volumes:
      - ./mysql/conf/my.cnf:/etc/mysql/my.cnf
      - ./mysql/logs:/logs
      - ./mysql/data:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
      - MYSQL_DATABASE=$MYSQL_DB_NAME
      - TZ=Asia/Shanghai
    image: mysql:5.7
    networks:
      - $NETWORK_NAME

networks:
  $NETWORK_NAME:
    driver: bridge
EOF
}

# 等待 MySQL 启动完成
function wait_mysql_ready() {
    echo "等待 MySQL 启动..."
    while ! docker exec dnsmgr-mysql mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent &>/dev/null; do
        sleep 2
    done
    echo "MySQL 已就绪"
}

# 初始化 MySQL (第一次启动自动创建数据库)
function init_mysql() {
    docker-compose up -d dnsmgr-mysql
    wait_mysql_ready
}

# 启动服务
function start_all() {
    docker-compose up -d
}

# 停止服务
function stop_all() {
    docker-compose down
}

# 更新服务
function update_services() {
    docker-compose pull
    docker-compose up -d
}

# 卸载服务
function uninstall() {
    read -p "是否保留数据? [y/N]: " keep
    stop_all
    docker rm -f dnsmgr-web dnsmgr-mysql 2>/dev/null || true
    docker network rm $NETWORK_NAME 2>/dev/null || true

    if [[ "$keep" =~ ^[Yy]$ ]]; then
        docker rmi netcccyun/dnsmgr mysql:5.7 2>/dev/null || true
    else
        docker-compose down -v --rmi all
        rm -rf "$WEB_DIR" "$MYSQL_CONF_DIR" "$MYSQL_LOGS_DIR" "$MYSQL_DATA_DIR"
    fi
    echo -e "${GREEN}卸载完成！${RESET}"
}

# 显示访问信息
function show_info() {
    local web_port="$1"
    local ip=$(hostname -I | awk '{print $1}')
    echo -e "\n${GREEN}==== 安装完成信息 ====${RESET}"
    echo -e "${YELLOW}访问 dnsmgr-web:${RESET} http://$ip:$web_port"
    echo -e "${YELLOW}MySQL 主机:${RESET} dnsmgr-mysql"
    echo -e "${YELLOW}MySQL 端口:${RESET} 3306"
    echo -e "${YELLOW}MySQL 用户名:${RESET} root"
    echo -e "${YELLOW}MySQL 密码:${RESET} $MYSQL_ROOT_PASSWORD"
    echo -e "${YELLOW}数据库名称:${RESET} $MYSQL_DB_NAME"
}

# 菜单
function menu() {
    while true; do
        echo -e "${GREEN}==== DNSMgr Docker 管理菜单 ====${RESET}"
        echo -e "${GREEN}1) 安装并初始化${RESET}"
        echo -e "${GREEN}2) 启动服务${RESET}"
        echo -e "${GREEN}3) 停止服务${RESET}"
        echo -e "${GREEN}4) 更新服务${RESET}"
        echo -e "${GREEN}5) 卸载${RESET}"
        echo -e "${GREEN}6) 退出${RESET}"
        read -p "请输入操作编号: " choice
        case "$choice" in
            1)
                while true; do
                    read -p "请输入 dnsmgr-web 映射端口 (默认 8081): " web_port
                    web_port=${web_port:-8081}
                    if check_port "$web_port"; then
                        break
                    else
                        echo -e "${RED}端口 $web_port 已被占用，请重新输入！${RESET}"
                    fi
                done
                create_dirs
                generate_my_cnf
                generate_docker_compose "$web_port"
                init_mysql
                start_all
                show_info "$web_port"
                ;;
            2)
                start_all
                echo -e "${GREEN}服务已启动！${RESET}"
                ;;
            3) stop_all ;;
            4) update_services ;;
            5) uninstall ;;
            6) exit 0 ;;
            *) echo -e "${RED}无效选项！${RESET}" ;;
        esac
    done
}

menu
