#!/bin/bash
# =================================================================
# Lsky Pro 兰空图床 Docker Compose 管理面板
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/lsky-pro"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
CONFIG_FILE="$BASE_DIR/lsky.env"
DEFAULT_IMAGE="dko0/lsky-pro:latest"

# 检测依赖环境
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        # 强制获取 IPv4
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        # 强制获取 IPv6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        # auto 模式：双栈环境优先获取 IPv4 (更适合大众网络)，纯 v6 环境自动fallback到 v6
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        # 如果获取 v4 失败，说明可能是纯 v6 机器，尝试获取 v6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    # 兜底处理：所有接口都失败时，直接输出 127.0.0.1，不报错
    echo "127.0.0.1" && return 0
}

# 动态获取容器整体状态和端口
get_status_info() {
    if [ -f "$COMPOSE_FILE" ]; then
        if [ "$(docker ps -q -f name=lsky-pro)" ]; then
            status="${GREEN}运行中${RESET}"
            web_port=$(docker ps -f name=lsky-pro --format "{{.Ports}}" | sed -E 's/.*:([0-9]+)->.*/\1/' | head -n 1)
            if ! [[ "$web_port" =~ ^[0-9]+$ ]]; then
                web_port=$(sed -n '/lsky-pro:/,/^[[:space:]]*[a-zA-Z]/p' "$COMPOSE_FILE" | grep -E '\-[[:space:]]*["'\'']?[0-9]+:' | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"''-')
            fi
        elif [ "$(docker ps -aq -f name=lsky-pro)" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' lsky-pro 2>/dev/null)
        else
            status="${RED}未部署${RESET}"
        fi
        [[ -z "$web_port" ]] && web_port="8080"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署 Lsky Pro
install_lsky() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    # 1. 基础参数配置
    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Lsky Pro 宿主机映射访问端口 [默认: 8089]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8089"

    # 2. 数据库运行模式选择
    echo -e "\n${CYAN}====== MySQL 数据库运行模式选择 ======${RESET}"
    echo -e " 1) 直接部署全新的 MySQL 8.0 容器 (包含本地持久化卷)"
    echo -e " 2) 使用已有的外部/远程外部 MySQL 数据库 (需提前手动建好空库)"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    local db_host="mysql"
    local db_port="3306"
    local db_name="lsky"
    local db_user="lsky"
    local db_pass=""
    local db_root_pass=""

    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}使用全新内置 MySQL 容器，正在生成高强度随机密码...${RESET}"
        db_pass=$(openssl rand -hex 12)
        db_root_pass=$(openssl rand -hex 16)
    else
        echo -ne "${YELLOW}请输入远程 MySQL 的 IP 或域名: ${RESET}"
        read -r ext_db_ip
        echo -ne "${YELLOW}请输入远程 MySQL 端口 [默认: 3306]: ${RESET}"
        read -r ext_db_port
        [[ -z "$ext_db_port" ]] && ext_db_port="3306"
        db_host="$ext_db_ip"
        db_port="$ext_db_port"
        echo -ne "${YELLOW}请输入远程 MySQL 用户名 [默认: lsky]: ${RESET}"
        read -r db_user
        [[ -z "$db_user" ]] && db_user="lsky"
        echo -ne "${YELLOW}请输入远程 MySQL 密码: ${RESET}"
        read -r db_pass
        echo -ne "${YELLOW}请输入远程已存在的数据库名 [默认: lsky]: ${RESET}"
        read -r db_name
        [[ -z "$db_name" ]] && db_name="lsky"
        
        # 兼容本地宿主机回环网关
        if [[ "$ext_db_ip" == "127.0.0.1" || "$ext_db_ip" == "localhost" ]]; then
            db_host="172.17.0.1"
        fi
    fi

    # 3. 备份保留凭证配置文件 lsky.env (值全部外加双引号防截断)
    cat << EOF > "$CONFIG_FILE"
PORT="${custom_port}"
DB_HOST="${db_host}"
DB_PORT="${db_port}"
MYSQL_DATABASE="${db_name}"
MYSQL_USER="${db_user}"
MYSQL_PASSWORD="${db_pass}"
MYSQL_ROOT_PASSWORD="${db_root_pass}"
EOF

    # 4. 创建持久化数据目录
    mkdir -p "$BASE_DIR/data/html"

    # 5. 生成规范化 Docker Compose 配置文件 (双模彻底分流)
    echo -e "${YELLOW}正在生成规范化 Docker Compose 配置文件...${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        # 模式 1：包含本地内置 MySQL 容器及专属桥接网络
        mkdir -p "$BASE_DIR/data/db"
        cat << EOF > "$COMPOSE_FILE"
networks:
  lsky-net:

services:
  lsky-pro:
    image: ${DEFAULT_IMAGE}
    container_name: lsky-pro
    restart: always
    ports:
      - "127.0.0.1:${custom_port}:80"
    volumes:
      - ./data/html:/var/www/html
    environment:
      - DB_HOST=${db_host}
      - DB_PORT=${db_port}
      - DB_DATABASE=${db_name}
      - DB_USERNAME=${db_user}
      - DB_PASSWORD=${db_pass}
    depends_on:
      - mysql
    networks:
      - lsky-net

  mysql:
    image: mysql:8.0
    container_name: lsky-pro-db
    restart: always
    environment:
      - MYSQL_DATABASE=${db_name}
      - MYSQL_USER=${db_user}
      - MYSQL_PASSWORD=${db_pass}
      - MYSQL_ROOT_PASSWORD=${db_root_pass}
    command: --default-authentication-plugin=mysql_native_password
    volumes:
      - ./data/db:/var/lib/mysql
    networks:
      - lsky-net
EOF
    else
        # 模式 2：纯净外部远程对接，无本地 mysql 节点，无 lsky-net 网络限制
        cat << EOF > "$COMPOSE_FILE"
services:
  lsky-pro:
    image: ${DEFAULT_IMAGE}
    container_name: lsky-pro
    restart: always
    ports:
      - "127.0.0.1:${custom_port}:80"
    volumes:
      - ./data/html:/var/www/html
    environment:
      - DB_HOST=${db_host}
      - DB_PORT=${db_port}
      - DB_DATABASE=${db_name}
      - DB_USERNAME=${db_user}
      - DB_PASSWORD=${db_pass}
EOF
    fi

    # 6. 清理残余并拉起容器集群
    echo -e "${YELLOW}正在通过 Docker Compose 部署图床环境...${RESET}"
    cd "$BASE_DIR"
    docker compose down -v 2>/dev/null
    docker compose up -d --force-recreate

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 服务拉起失败，请检查端口 ${custom_port} 是否被占用。${RESET}"
        return
    fi

    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             Lsky Pro 图床系统部署成功！              ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}内部提取端口   : ${custom_port} (绑定在 127.0.0.1)${RESET}"
    echo -e "${YELLOW}本地 Nginx 反代: http://127.0.0.1:${custom_port}${RESET}"
    echo -e "----------------------------------------------------"
    echo -e "${CYAN}[数据库凭据回显]${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}MySQL 运行模式 : ${GREEN}全新内置容器 (MySQL 8.0)${RESET}"
        echo -e "${YELLOW}MySQL 地址 : ${GREEN}mysql${RESET}"
        echo -e "${YELLOW}MySQL 数据库名 : ${GREEN}${db_name}${RESET}"
        echo -e "${YELLOW}MySQL 用户名 : ${GREEN}${db_user}${RESET}"
        echo -e "${YELLOW}常规用户密码   : ${GREEN}${db_pass}${RESET}"
        echo -e "${YELLOW}ROOT 超管密码  : ${GREEN}${db_root_pass}${RESET}"
    else
        echo -e "${YELLOW}MySQL 运行模式 : ${CYAN}外部远程连接${RESET}"
        echo -e "${YELLOW}远程目标主机   : ${db_host}:${db_port}${RESET}"
        echo -e "${YELLOW}连接指定库名   : ${db_name}${RESET}"
    fi
    echo -e "----------------------------------------------------"
    echo -e "${YELLOW}持久化工作目录 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新图床
update_lsky() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 Lsky Pro 镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}升级完成！${RESET}"
}

# 卸载图床
uninstall_lsky() {
    echo -ne "${RED}确定要完全卸载并删除 Lsky Pro 服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            rm -rf "$BASE_DIR"
        else
            docker rm -f lsky-pro lsky-pro-db 2>/dev/null
        fi
        echo -e "${GREEN}完全卸载成功，数据已彻底清理。${RESET}"
    fi
}

start_lsky() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已拉起运行${RESET}"; }
stop_lsky() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止运行${RESET}"; }
restart_lsky() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已成功重启${RESET}"; }
logs_lsky() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态   : $status"
    echo -e "${YELLOW}外部提取端口   : ${web_port}${RESET}"
    echo -e "${YELLOW}安装绝对路径   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 主菜单管理
menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}     ◈  Lsky Pro 管理面板  ◈        ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN} 当前状态 :${RESET} $status"
    echo -e "${GREEN} 映射端口 :${RESET} ${YELLOW}${web_port}${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN} 1. 部署启动${RESET}"
    echo -e "${GREEN} 2. 更新服务${RESET}"
    echo -e "${GREEN} 3. 卸载服务${RESET}"
    echo -e "${GREEN} 4. 启动服务${RESET}"
    echo -e "${GREEN} 5. 停止服务${RESET}"
    echo -e "${GREEN} 6. 重启服务${RESET}"
    echo -e "${GREEN} 7. 查看日志${RESET}"
    echo -e "${GREEN} 8. 查看配置${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_lsky ;;
        2) update_lsky ;;
        3) uninstall_lsky ;;
        4) start_lsky ;;
        5) stop_lsky ;;
        6) restart_lsky ;;
        7) logs_lsky ;;
        8) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
