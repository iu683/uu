#!/bin/bash
# =================================================================
# Gitea Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="gitea"
BASE_DIR="/opt/gitea"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 数据挂载本地的宿主机路径
GITEA_DATA_DIR="$BASE_DIR/gitea-data"
DB_DATA_DIR="$BASE_DIR/db-data"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 格式化 URL 中的 IP (如果是 IPv6 则加上方括号 [])
format_ip_for_url() {
    local ip="$1"
    if [[ "$ip" == *":"* ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

# 动态获取容器状态、映射端口和数据库类型
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        ssh_port="N/A"
        db_type="N/A"
        return 0
    fi
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取镜像名称/版本
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 从容器状态提取前端映射端口（容器内部监听的是 3000 端口）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3000"

        # 从容器状态提取 SSH 映射端口（容器内部监听的是 22 端口）
        ssh_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "22/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$ssh_port" ]] && ssh_port="222"

        # 探测当前数据库类型
        local env_db_type=$(docker inspect -f '{{range .Config.Env}}{{printf "%s\n" .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | grep "GITEA__database__DB_TYPE=")
        local env_db_host=$(docker inspect -f '{{range .Config.Env}}{{printf "%s\n" .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | grep "GITEA__database__HOST=")
        
        if [[ "$env_db_type" == *"postgres"* ]]; then
            if [[ "$env_db_host" == *"db:5432"* ]]; then
                db_type="PostgreSQL (容器内联)"
            else
                db_type="PostgreSQL (远程外部)"
            fi
        elif [[ "$env_db_type" == *"mysql"* ]]; then
            if [[ "$env_db_host" == *"db:3306"* ]]; then
                db_type="MySQL (容器内联)"
            else
                db_type="MySQL (远程外部)"
            fi
        else
            db_type="SQLite (内置)"
        fi
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        ssh_port="N/A"
        db_type="N/A"
    fi
}

# 获取公网 IP (兼容双栈环境)
get_public_ip() {
    local mode=${1:-"auto"}
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
}

# 部署 Gitea
install_gitea() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    mkdir -p "$GITEA_DATA_DIR"

    echo -e "${CYAN}====== 1. 数据库及架构选择 ======${RESET}"
    echo -e "${GREEN}1) SQLite (最轻量，无需独立数据库容器)${RESET}"
    echo -e "${GREEN}2) PostgreSQL (自带内联数据库容器)${RESET}"
    echo -e "${GREEN}3) MySQL / MariaDB (自带内联数据库容器)${RESET}"
    echo -e "${GREEN}4) 远程外部 MySQL (连接您现有的远程库)${RESET}"
    echo -e "${GREEN}5) 远程外部 PostgreSQL (连接您现有的远程库)${RESET}"
    echo -ne "${YELLOW}请选择部署架构模式 [默认 1]: ${RESET}"
    read -r db_choice
    [[ -z "$db_choice" ]] && db_choice="1"

    # 初始化基础变量
    local print_db_type="SQLite"
    local print_db_host="内置"
    local print_db_name="gitea.db (自动)"
    local print_db_user="N/A"
    local print_db_pass="N/A"
    local ext_domain=""
    local compose_db_type=""

    # 针对远程外部数据库（MySQL / Postgres）引导交互输入
    if [ "$db_choice" = "4" ] || [ "$db_choice" = "5" ]; then
        if [ "$db_choice" = "4" ]; then
            print_db_type="MySQL (远程外部)"
            compose_db_type="mysql"
            local default_port="3306"
        else
            print_db_type="PostgreSQL (远程外部)"
            compose_db_type="postgres"
            local default_port="5432"
        fi

        echo -e "${CYAN}--- ${print_db_type} 连接配置 ---${RESET}"
        echo -ne "${YELLOW}请输入远程数据库 IP 和端口 [例如 192.168.1.100:${default_port}]: ${RESET}"
        read -r print_db_host
        echo -ne "${YELLOW}请输入要连接的数据库名 [默认: gitea]: ${RESET}"
        read -r print_db_name
        [[ -z "$print_db_name" ]] && print_db_name="gitea"
        echo -ne "${YELLOW}请输入数据库用户名: ${RESET}"
        read -r print_db_user
        echo -ne "${YELLOW}请输入数据库密码: ${RESET}"
        read -r print_db_pass
        
        RAW_IP=$(get_public_ip)
        echo -ne "${YELLOW}请输入访问域名或外网IP [默认: $RAW_IP]: ${RESET}"
        read -r ext_domain
        [[ -z "$ext_domain" ]] && ext_domain="$RAW_IP"
    fi

    echo -e "${CYAN}====== 2. 端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Web 访问端口 (宿主机端口) [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"

    echo -ne "${YELLOW}请输入 SSH 映射端口 (宿主机端口) [默认: 222]: ${RESET}"
    read -r custom_ssh
    [[ -z "$custom_ssh" ]] && custom_ssh="222"

    # 统一修改宿主机本地挂载目录权限
    chmod -R 777 "$BASE_DIR"

    echo -e "${YELLOW}正在生成对应的 docker-compose.yml 配置文件...${RESET}"

    # 根据选择生成不同的模版
    if [ "$db_choice" = "2" ]; then
        # 2. PostgreSQL 内联容器模版
        print_db_type="PostgreSQL (容器内联)"
        print_db_host="db:5432"
        print_db_name="gitea"
        print_db_user="gitea"
        print_db_pass="gitea"

        mkdir -p "$DB_DATA_DIR"
        cat <<EOF > "$COMPOSE_FILE"
networks:
  gitea:
    external: false

services:
  server:
    image: docker.gitea.com/gitea:1.26.4
    container_name: ${CONTAINER_NAME}
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__database__DB_TYPE=postgres
      - GITEA__database__HOST=${print_db_host}
      - GITEA__database__NAME=${print_db_name}
      - GITEA__database__USER=${print_db_user}
      - GITEA__database__PASSWD=${print_db_pass}
    restart: always
    networks:
      - gitea
    volumes:
      - ${GITEA_DATA_DIR}:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "${custom_port}:3000"
      - "${custom_ssh}:22"
    depends_on:
      - db

  db:
    image: docker.io/library/postgres:14
    restart: always
    environment:
      - POSTGRES_USER=${print_db_user}
      - POSTGRES_PASSWORD=${print_db_pass}
      - POSTGRES_DB=${print_db_name}
    networks:
      - gitea
    volumes:
      - ${DB_DATA_DIR}:/var/lib/postgresql/data
EOF

    elif [ "$db_choice" = "3" ]; then
        # 3. MySQL 内联容器模版
        print_db_type="MySQL (容器内联)"
        print_db_host="db:3306"
        print_db_name="gitea"
        print_db_user="gitea"
        print_db_pass="gitea"

        mkdir -p "$DB_DATA_DIR"
        cat <<EOF > "$COMPOSE_FILE"
networks:
  gitea:
    external: false

services:
  server:
    image: docker.gitea.com/gitea:1.26.4
    container_name: ${CONTAINER_NAME}
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__database__DB_TYPE=mysql
      - GITEA__database__HOST=${print_db_host}
      - GITEA__database__NAME=${print_db_name}
      - GITEA__database__USER=${print_db_user}
      - GITEA__database__PASSWD=${print_db_pass}
    restart: always
    networks:
      - gitea
    volumes:
      - ${GITEA_DATA_DIR}:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "${custom_port}:3000"
      - "${custom_ssh}:22"
    depends_on:
      - db

  db:
    image: docker.io/library/mysql:8
    restart: always
    environment:
      - MYSQL_ROOT_PASSWORD=${print_db_pass}
      - MYSQL_USER=${print_db_user}
      - MYSQL_PASSWORD=${print_db_pass}
      - MYSQL_DATABASE=${print_db_name}
    networks:
      - gitea
    volumes:
      - ${DB_DATA_DIR}:/var/lib/mysql
EOF

    elif [ "$db_choice" = "4" ] || [ "$db_choice" = "5" ]; then
        # 4 & 5. 远程外部数据库共有通用模版 (UID改为1010，增加高阶优化环境参数)
        cat <<EOF > "$COMPOSE_FILE"
networks:
  gitea:
    external: false

services:
  server:
    image: docker.gitea.com/gitea:1.26.4
    container_name: ${CONTAINER_NAME}
    environment:
      - USER_UID=1010
      - USER_GID=1010
      - GITEA__database__DB_TYPE=${compose_db_type}
      - GITEA__database__HOST=${print_db_host}
      - GITEA__database__NAME=${print_db_name}
      - GITEA__database__USER=${print_db_user}
      - GITEA__database__PASSWD=${print_db_pass}
      - DOMAIN=${ext_domain}
      - LFS_START_SERVER=true
      - DISABLE_REGISTRATION=true
    restart: always
    networks:
      - gitea
    volumes:
      - ${GITEA_DATA_DIR}:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "${custom_port}:3000"
      - "${custom_ssh}:22"
EOF

    else
        # 1. SQLite 默认内置库模版
        cat <<EOF > "$COMPOSE_FILE"
networks:
  gitea:
    external: false

services:
  server:
    image: docker.gitea.com/gitea:1.26.4
    container_name: ${CONTAINER_NAME}
    environment:
      - USER_UID=1000
      - USER_GID=1000
    restart: always
    networks:
      - gitea
    volumes:
      - ${GITEA_DATA_DIR}:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "${custom_port}:3000"
      - "${custom_ssh}:22"
EOF
    fi

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Gitea 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}               Gitea 部署完成！                     ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}Web 访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}SSH 映射端口 : ${custom_ssh}${RESET}"
    echo -e "${YELLOW}本地数据挂载 : $GITEA_DATA_DIR${RESET}"
    [[ -d "$DB_DATA_DIR" && "$db_choice" != "4" && "$db_choice" != "5" ]] && echo -e "${YELLOW}本地数据库群 : $DB_DATA_DIR${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    
    # 打印数据库连接详细信息
    echo -e "${CYAN}💾 数据库配置信息清单：${RESET}"
    echo -e "${GREEN}   👉 数据库类型 (Type) : ${RESET}${RED}${print_db_type}${RESET}"
    echo -e "${GREEN}   👉 数据库主机 (Host) : ${RESET}${YELLOW}${print_db_host}${RESET}"
    echo -e "${GREEN}   👉 数据库库名 (Name) : ${RESET}${YELLOW}${print_db_name}${RESET}"
    echo -e "${GREEN}   👉 用户名 (Username) : ${RESET}${YELLOW}${print_db_user}${RESET}"
    echo -e "${GREEN}   👉 密  码 (Password) : ${RESET}${YELLOW}${print_db_pass}${RESET}"
    if [[ -n "$ext_domain" ]]; then
    echo -e "${GREEN}   👉 绑定域名 (Domain) : ${RESET}${YELLOW}${ext_domain}${RESET}"
    fi
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    
    echo -e "${CYAN}💡 提示: 请直接打开上方浏览器地址进入初始化页面。${RESET}"
    if [ "$db_choice" = "4" ] || [ "$db_choice" = "5" ]; then
        echo -e "${RED}⚠️  注意: 远程数据库部署模式下，已默认配置禁止注册 (DISABLE_REGISTRATION=true)。${RESET}"
        echo -e "${RED}         请在安装引导页底部填写并创建您的首个管理员，之后普通用户将无法自主注册。${RESET}"
    else
        echo -e "${CYAN}       在页面最下方创建的第一个账号，即为管理员账号。${RESET}"
    fi
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_gitea() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像并更新...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！Gitea 容器已处于最新状态。${RESET}"
}

# 卸载服务
uninstall_gitea() {
    echo -ne "${YELLOW}确定要卸载并删除 Gitea 容器及网络吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器及网络已移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有本地的代码数据和数据库？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
            docker rm -f "${CONTAINER_NAME}-db" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_gitea() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_gitea() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_gitea() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_gitea() { 
    echo -e "${CYAN}--- Gitea 容器当前运行日志 (按 Ctrl+C 退出查看) ---${RESET}"
    docker logs -f "$CONTAINER_NAME"; 
}

show_info() {
    get_status_info
    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${YELLOW}当前状态     : $status"
    echo -e "${YELLOW}数据库架构   : $db_type"
    echo -e "${YELLOW}镜像名称     : ${img_version}${RESET}"
    echo -e "${YELLOW}网页访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}SSH 映射端口 : ${ssh_port}${RESET}"
    echo -e "${YELLOW}数据挂载路径 : ${GITEA_DATA_DIR}${RESET}"
    echo -e "${GREEN}========================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN}   ◈  Gitea 代码托管管理面板  ◈   ${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}网页 :${RESET} ${YELLOW}${webui_port}${RESET}   ${GREEN}SSH端口 :${RESET} ${YELLOW}${ssh_port}${RESET}"
    echo -e "${GREEN}架构 :${RESET} ${CYAN}${db_type}${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动服务${RESET}"
    echo -e "${GREEN}5. 停止服务${RESET}"
    echo -e "${GREEN}6. 重启服务${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_gitea ;;
        2) update_gitea ;;
        3) uninstall_gitea ;;
        4) start_gitea ;;
        5) stop_gitea ;;
        6) restart_gitea ;;
        7) logs_gitea ;;
        8) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
