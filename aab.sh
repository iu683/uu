#!/bin/bash
# =========================================
# DNSMgr Docker 管理脚本 (无数据库版)
# =========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

COMPOSE_FILE="./docker-compose.yml"
WEB_DIR="./web"
NETWORK_NAME="dnsmgr-network"

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
    mkdir -p "$WEB_DIR"
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
    networks:
      - $NETWORK_NAME

networks:
  $NETWORK_NAME:
    driver: bridge
EOF
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
    read -p "是否删除 web 文件? [y/N]: " keep
    stop_all
    docker rm -f dnsmgr-web 2>/dev/null || true
    docker network rm $NETWORK_NAME 2>/dev/null || true

    if [[ ! "$keep" =~ ^[Yy]$ ]]; then
        rm -rf "$WEB_DIR"
    fi
    docker rmi netcccyun/dnsmgr 2>/dev/null || true
    echo -e "${GREEN}卸载完成！${RESET}"
}

# 显示访问信息
function show_info() {
    local web_port="$1"
    local ip=$(hostname -I | awk '{print $1}')
    echo -e "\n${GREEN}==== 安装完成信息 ====${RESET}"
    echo -e "${YELLOW}访问 dnsmgr-web:${RESET} http://$ip:$web_port"
}

# 菜单
function menu() {
    while true; do
        echo -e "${GREEN}==== DNSMgr Docker 管理菜单 (无数据库版) ====${RESET}"
        echo -e "${GREEN}1) 安装并启动${RESET}"
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
                generate_docker_compose "$web_port"
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
