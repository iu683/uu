#!/bin/bash
# =================================================================
# Flarum 论坛 Docker Compose 管理面板 (多库远程切换 + 完美凭据回显版)
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/flarum"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/flarum.env"
DEFAULT_IMAGE="mondedie/flarum:stable"

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
        if [ "$(docker ps -q -f name=flarum)" ]; then
            status="${GREEN}运行中${RESET}"
            web_port=$(docker ps -f name=flarum --format "{{.Ports}}" | sed -E 's/.*:([0-9]+)->.*/\1/' | head -n 1)
            if ! [[ "$web_port" =~ ^[0-9]+$ ]]; then
                web_port=$(sed -n '/flarum:/,/^[[:space:]]*[a-zA-Z]/p' "$COMPOSE_FILE" | grep -E '\-[[:space:]]*["'\'']?[0-9]+:' | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"''-')
            fi
        elif [ "$(docker ps -aq -f name=flarum)" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' flarum 2>/dev/null)
        else
            status="${RED}未部署${RESET}"
        fi
        [[ -z "$web_port" ]] && web_port="80"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署 Flarum
install_flarum() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    # 1. 基础参数配置
    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Flarum 宿主机映射访问端口 [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"
    
    DETECT_IP=$(get_public_ip)
    echo -ne "${YELLOW}请输入 Flarum 论坛域名/URL [默认: http://${DETECT_IP}:${custom_port}]: ${RESET}"
    read -r forum_domain
    [[ -z "$forum_domain" ]] && forum_domain="http://${DETECT_IP}:${custom_port}"

    echo -ne "${YELLOW}请输入论坛管理员用户名 [默认: admin]: ${RESET}"
    read -r admin_user
    [[ -z "$admin_user" ]] && admin_user="admin"

    echo -ne "${YELLOW}请输入论坛管理员邮箱 [默认: admin@example.com]: ${RESET}"
    read -r admin_mail
    [[ -z "$admin_mail" ]] && admin_mail="admin@example.com"

    echo -ne "${YELLOW}请输入论坛标题 [默认: Flarum Forum]: ${RESET}"
    read -r forum_title
    [[ -z "$forum_title" ]] && forum_title="Flarum Forum"

    # 2. 数据库运行模式选择
    echo -e "\n${CYAN}====== MySQL 数据库运行模式选择 ======${RESET}"
    echo -e " 1) 直接部署全新的 MySQL 8.0 容器 (包含本地持久化卷)"
    echo -e " 2) 使用已有的外部/远程 MySQL 数据库 (需提前手动建好空库并授权)"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    local db_host="mysql-db"
    local db_port="3306"
    local db_user="flarum"
    local db_pass=""
    local db_name="flarum"
    local root_pass=""

    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}正在自动计算生成数据库高强度随机密码...${RESET}"
        root_pass=$(openssl rand -hex 12)
        db_pass=$(openssl rand -hex 12)
        admin_pass=$(openssl rand -hex 10)
    else
        echo -ne "${YELLOW}请输入外部 MySQL 的 IP 或域名 [例如: 47.79.88.134]: ${RESET}"
        read -r ext_db_ip
        echo -ne "${YELLOW}请输入外部 MySQL 端口 [默认: 3306]: ${RESET}"
        read -r ext_db_port
        [[ -z "$ext_db_port" ]] && ext_db_port="3306"
        db_host="$ext_db_ip"
        db_port="$ext_db_port"
        echo -ne "${YELLOW}请输入外部 MySQL 用户名 [默认: flarum]: ${RESET}"
        read -r db_user
        [[ -z "$db_user" ]] && db_user="flarum"
        echo -ne "${YELLOW}请输入外部 MySQL 密码: ${RESET}"
        read -r db_pass
        echo -ne "${YELLOW}请输入外部已存在的数据库名 [默认: flarum]: ${RESET}"
        read -r db_name
        [[ -z "$db_name" ]] && db_name="flarum"
        echo -ne "${YELLOW}请设置您论坛管理员的初始化密码 (至少8位): ${RESET}"
        read -r admin_pass
        
        if [[ "$ext_db_ip" == "127.0.0.1" || "$ext_db_ip" == "localhost" ]]; then
            db_host="172.17.0.1"
        fi
    fi

    # 3. 创建核心持久化数据目录
    mkdir -p "$BASE_DIR/assets" "$BASE_DIR/extensions" "$BASE_DIR/logs" "$BASE_DIR/nginx"

    # 4. 生成 flarum.env 配置文件
    echo -e "\n${YELLOW}正在生成 Flarum 环境变量配置文件 (.env)...${RESET}"
    cat << EOF > "$ENV_FILE"
DEBUG=false
FORUM_URL=${forum_domain}

DB_HOST=${db_host}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASS=${db_pass}
DB_PREF=flarum_
DB_PORT=${db_port}

FLARUM_ADMIN_USER=${admin_user}
FLARUM_ADMIN_PASS=${admin_pass}
FLARUM_ADMIN_MAIL=${admin_mail}
FLARUM_TITLE=${forum_title}
EOF

    # 5. 生成 docker-compose.yml 文本
    echo -e "${YELLOW}正在生成 Docker Compose 配置文件...${RESET}"
    cat << EOF > "$COMPOSE_FILE"
services:
  flarum:
    image: ${DEFAULT_IMAGE}
    container_name: flarum
    restart: unless-stopped
    env_file:
      - ./flarum.env
    volumes:
      - ./assets:/flarum/app/public/assets
      - ./extensions:/flarum/app/extensions
      - ./logs:/flarum/app/storage/logs
      - ./nginx:/etc/nginx/flarum
    ports:
      - "${custom_port}:8888"
EOF

    # 动态追加依赖节点
    if [[ "$db_mode" == "1" ]]; then
        cat << EOF >> "$COMPOSE_FILE"
    depends_on:
      - mysql-db
EOF
    fi

    # 动态追加本地内置纯正 MySQL 8.0 服务 (替代原本的 MariaDB)
    if [[ "$db_mode" == "1" ]]; then
        mkdir -p "$BASE_DIR/mysql"
        cat << EOF >> "$COMPOSE_FILE"

  mysql-db:
    image: mysql:8.0
    container_name: flarum-db
    restart: unless-stopped
    command: --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    environment:
      MYSQL_ROOT_PASSWORD: ${root_pass}
      MYSQL_DATABASE: ${db_name}
      MYSQL_USER: ${db_user}
      MYSQL_PASSWORD: ${db_pass}
    volumes:
      - ./mysql:/var/lib/mysql
EOF
    fi

    # 6. 执行一键拉起
    echo -e "${YELLOW}正在通过 Docker Compose 启动 Flarum 论坛系统...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 架构拉起失败，请检查端口是否被占用。${RESET}"
        return
    fi

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             Flarum 论坛部署成功！                   ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}论坛访问地址   : ${forum_domain}${RESET}"
    echo -e "${YELLOW}管理员账号     : ${GREEN}${admin_user}${RESET}"
    echo -e "${YELLOW}管理员密码     : ${GREEN}${admin_pass}${RESET}"
    echo -e "${YELLOW}管理员邮箱     : ${admin_mail}${RESET}"
    echo -e "----------------------------------------------------"
    echo -e "${CYAN}[数据库凭据回显]${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}MySQL 运行模式 : ${GREEN}全新内置容器 (MySQL 8.0)${RESET}"
        echo -e "${YELLOW}内置连接地址   : mysql-db${RESET}"
        echo -e "${YELLOW}内置实例库名   : ${db_name}${RESET}"
        echo -e "${YELLOW}MySQL root密码 : ${RED}${root_pass}${RESET}"
        echo -e "${YELLOW}应用专账用户名 : ${GREEN}${db_user}${RESET}"
        echo -e "${YELLOW}应用专账访问密码 : ${GREEN}${db_pass}${RESET}"
    else
        echo -e "${YELLOW}MySQL 运行模式 : ${CYAN}外部远程连接${RESET}"
        echo -e "${YELLOW}远程目标主机   : ${db_host}:${db_port}${RESET}"
        echo -e "${YELLOW}指定连接库名   : ${db_name}${RESET}"
        echo -e "${YELLOW}连接用户名     : ${db_user}${RESET}"
        echo -e "${YELLOW}连接密码       : ****** (您输入的外部密码)${RESET}"
        echo -e "----------------------------------------------------"
        echo -e "${RED}【重要提醒】${RESET}"
        echo -e "${YELLOW}由于属于跨网段容器请求，请确保您远程 MySQL 服务器执行过：${RESET}"
        echo -e "${GREEN}GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'%'; FLUSH PRIVILEGES;${RESET}"
    fi
    echo -e "----------------------------------------------------"
    echo -e "${YELLOW}持久化工作目录 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_flarum() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 Flarum 镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}升级完成！${RESET}"
}

# 卸载 Flarum
uninstall_flarum() {
    echo -ne "${RED}确定要完全卸载并删除 Flarum 服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            rm -rf "$BASE_DIR"
        else
            docker rm -f flarum flarum-db 2>/dev/null
        fi
        echo -e "${GREEN}完全卸载成功，数据已彻底清理。${RESET}"
    fi
}

start_flarum() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已拉起运行${RESET}"; }
stop_flarum() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止运行${RESET}"; }
restart_flarum() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已成功重启${RESET}"; }
logs_flarum() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态   : $status"
    echo -e "${YELLOW}外部提取端口   : ${web_port}${RESET}"
    echo -e "${YELLOW}安装绝对路径   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}


install_chinese() {

    if ! docker ps | grep -q flarum; then
        echo -e "${RED}Flarum 未运行${RESET}"
        read -p "按回车返回..."
        return
    fi

    echo -e "${GREEN}正在安装简体中文语言包...${RESET}"

    docker exec -it flarum sh -c "
    cd /flarum/app &&
    composer require flarum-lang/chinese-simplified &&
    php flarum cache:clear
    "

    echo
    echo -e "${GREEN}✅ 中文语言包安装完成${RESET}"
    echo -e "${YELLOW}后台启用:${RESET}"
    echo -e "${YELLOW}Administration → Languages → 简体中文${RESET}"

    read -p "按回车返回菜单..."
}


# 主菜单管理
menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}       ◈  Flarum 管理面板  ◈        ${RESET}"
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
    echo -e "${GREEN} 9. 安装中文语言包${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_flarum ;;
        2) update_flarum ;;
        3) uninstall_flarum ;;
        4) start_flarum ;;
        5) stop_flarum ;;
        6) restart_flarum ;;
        7) logs_flarum ;;
        8) show_info ;;
        9) install_chinese ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
