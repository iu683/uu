#!/bin/bash
# =================================================================
# Typecho Docker Compose 管理面板 (多库远程切换 + 完美凭据回显版)
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/typecho"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
DEFAULT_IMAGE="joyqi/typecho:nightly-php8.2-apache"

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

# 动态获取容器整体状态和端口 (实时从运行状态提取)
get_status_info() {
    if [ -f "$COMPOSE_FILE" ]; then
        if [ "$(docker ps -q -f name=typecho-server)" ]; then
            status="${GREEN}运行中${RESET}"
            web_port=$(docker ps -f name=typecho-server --format "{{.Ports}}" | sed -E 's/.*:([0-9]+)->.*/\1/' | head -n 1)
            if ! [[ "$web_port" =~ ^[0-9]+$ ]]; then
                web_port=$(sed -n '/typecho:/,/^[[:space:]]*[a-zA-Z]/p' "$COMPOSE_FILE" | grep -E '\-[[:space:]]*["'\'']?[0-9]+:' | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"''-')
            fi
        elif [ "$(docker ps -aq -f name=typecho-server)" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' typecho-server 2>/dev/null)
        else
            status="${RED}未部署${RESET}"
        fi
        [[ -z "$web_port" ]] && web_port="80"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署 Typecho
install_typecho() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    # 1. 基础映射端口与站点 URL 配置
    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Typecho 宿主机映射访问端口 [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"
    
    DETECT_IP=$(get_public_ip)
    echo -ne "${YELLOW}请输入 Typecho 站点 URL [默认: http://${DETECT_IP}:${custom_port}]: ${RESET}"
    read -r site_url
    [[ -z "$site_url" ]] && site_url="http://${DETECT_IP}:${custom_port}"

    # 2. 数据库运行模式选择
    echo -e "\n${CYAN}====== MySQL 数据库运行模式选择 ======${RESET}"
    echo -e " 1) 直接部署全新的 MySQL 8.0 容器 (包含本地持久化卷)"
    echo -e " 2) 使用已有的外部/远程 MySQL 数据库 (需提前手动建好空库并授权)"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    local db_host="db"
    local db_user="typecho"
    local db_pass=""
    local db_name="typecho"
    local root_pass=""

    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}正在自动计算生成数据库高强度随机密码...${RESET}"
        root_pass=$(openssl rand -hex 12)
        db_pass=$(openssl rand -hex 12)
    else
        echo -ne "${YELLOW}请输入外部 MySQL 的 IP 或域名 [例如: 47.79.88.134]: ${RESET}"
        read -r ext_db_ip
        echo -ne "${YELLOW}请输入外部 MySQL 端口 [默认: 3306]: ${RESET}"
        read -r ext_db_port
        [[ -z "$ext_db_port" ]] && ext_db_port="3306"
        db_host="${ext_db_ip}:${ext_db_port}"
        echo -ne "${YELLOW}请输入外部 MySQL 用户名 [默认: typecho]: ${RESET}"
        read -r db_user
        [[ -z "$db_user" ]] && db_user="typecho"
        echo -ne "${YELLOW}请输入外部 MySQL 密码: ${RESET}"
        read -r db_pass
        echo -ne "${YELLOW}请输入外部已存在的数据库名 [默认: typecho]: ${RESET}"
        read -r db_name
        [[ -z "$db_name" ]] && db_name="typecho"
        
        # 兼容宿主机回环地址
        if [[ "$ext_db_ip" == "127.0.0.1" || "$ext_db_ip" == "localhost" ]]; then
            db_host="172.17.0.1:${ext_db_port}"
        fi
    fi

    # 3. 生成 docker-compose.yml 文本
    echo -e "\n${YELLOW}正在生成 Typecho Docker Compose 配置文件...${RESET}"
    mkdir -p "$BASE_DIR/data"

    cat << EOF > "$COMPOSE_FILE"
services:
  typecho:
    image: ${DEFAULT_IMAGE}
    container_name: typecho-server
    restart: always
    ports:
      - "${custom_port}:80"
    volumes:
      - ${BASE_DIR}/data:/app/usr
    environment:
      TYPECHO_SITE_URL: ${site_url}
      TZ: Asia/Shanghai
EOF

    # 处理 depends_on 依赖节点
    if [[ "$db_mode" == "1" ]]; then
        cat << EOF >> "$COMPOSE_FILE"
    depends_on:
      - db
EOF
    fi

    # 动态追加本地内置 MySQL 服务
    if [[ "$db_mode" == "1" ]]; then
        mkdir -p "$BASE_DIR/db"
        cat << EOF >> "$COMPOSE_FILE"

  db:
    image: mysql:8.0
    container_name: typecho-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${root_pass}
      MYSQL_DATABASE: ${db_name}
      MYSQL_USER: ${db_user}
      MYSQL_PASSWORD: ${db_pass}
    volumes:
      - ${BASE_DIR}/db:/var/lib/mysql
EOF
    fi

    # 4. 执行一键拉起
    echo -e "${YELLOW}正在启动 Typecho 容器集群...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 架构拉起失败，请检查端口是否被占用。${RESET}"
        return
    fi

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             Typecho 部署成功！                      ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}外部访问地址   : ${site_url}${RESET}"
    echo -e "${YELLOW}宿主机映射端口 : ${custom_port}${RESET}"
    echo -e "----------------------------------------------------"
    echo -e "${CYAN}[数据库凭据回显]${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}MySQL 运行模式 : ${GREEN}全新内置容器 (MySQL 8.0)${RESET}"
        echo -e "${YELLOW}内置连接主机   : db (容器局域网内网互通)${RESET}"
        echo -e "${YELLOW}内置实例库名   : ${db_name}${RESET}"
        echo -e "${YELLOW}MySQL root密码 : ${RED}${root_pass}${RESET}"
        echo -e "${YELLOW}博客专账用户名 : ${GREEN}${db_user}${RESET}"
        echo -e "${YELLOW}博客专账访问密码 : ${GREEN}${db_pass}${RESET}"
    else
        echo -e "${YELLOW}MySQL 运行模式 : ${CYAN}外部远程连接${RESET}"
        echo -e "${YELLOW}远程连接主机   : ${db_host}${RESET}"
        echo -e "${YELLOW}指定目标库名   : ${db_name}${RESET}"
        echo -e "${YELLOW}连接用户名     : ${db_user}${RESET}"
        echo -e "${YELLOW}连接密码       : ****** (您输入的外部密码)${RESET}"
        echo -e "----------------------------------------------------"
        echo -e "${RED}【重要安全提示】${RESET}"
        echo -e "${YELLOW}请确保远程 MySQL 已经为用户 '${db_user}' 授权。${RESET}"
        echo -e "${YELLOW}由于容器网段跨界，请在远程库执行：${RESET}"
        echo -e "${GREEN}GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'%'; FLUSH PRIVILEGES;${RESET}"
    fi
    echo -e "----------------------------------------------------"
    echo -e "${YELLOW}持久化数据目录 : ${BASE_DIR}/data${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_typecho() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 Typecho 镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}升级完成！${RESET}"
}

# 卸载 Typecho
uninstall_typecho() {
    echo -ne "${RED}确定要完全卸载并删除 Typecho 服务吗？数据将无法恢复！(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            rm -rf "$BASE_DIR"
        else
            docker rm -f typecho-server typecho-db 2>/dev/null
        fi
        echo -e "${GREEN}完全卸载成功，数据已彻底清理。${RESET}"
    fi
}

start_typecho() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已拉起运行${RESET}"; }
stop_typecho() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止运行${RESET}"; }
restart_typecho() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已成功重启${RESET}"; }
logs_typecho() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

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
    echo -e "${GREEN}       ◈  Typecho 管理面板  ◈        ${RESET}"
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
    echo -e "${0} 0. 退出${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_typecho ;;
        2) update_typecho ;;
        3) uninstall_typecho ;;
        4) start_typecho ;;
        5) stop_typecho ;;
        6) restart_typecho ;;
        7) logs_typecho ;;
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
