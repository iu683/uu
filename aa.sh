#!/bin/bash
# =================================================================
# MetaTube Docker Compose 管理面板 
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/metatube"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
DEFAULT_IMAGE="ghcr.io/metatube-community/metatube-server:latest"

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

# 动态获取容器整体状态和端口 (采用原生 Docker Inspect 终极技术)
get_status_info() {
    if [ -f "$COMPOSE_FILE" ]; then
        if [ "$(docker ps -q -f name=metatube)" ]; then
            status="${GREEN}运行中${RESET}"
            # 直接向 Docker 引擎索要 metatube 容器内部 8080 端口映射到宿主机的真实端口
            web_port=$(docker inspect --format='{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' metatube 2>/dev/null)
        elif [ "$(docker ps -aq -f name=metatube)" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=""
        else
            status="${RED}未部署${RESET}"
            web_port=""
        fi
        
        # 兜底逻辑：如果容器没启动，退回静态解析 YAML 文件
        if [ -z "$web_port" ]; then
            web_port=$(grep -A 5 "metatube:" "$COMPOSE_FILE" 2>/dev/null | grep -E '\-[[:space:]]*["'\'']?.*:8080' | head -n 1 | grep -oE '[0-9]+:8080' | cut -d':' -f1)
            [[ -z "$web_port" ]] && web_port="8080"
        fi
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署 MetaTube
install_metatube() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 数据库运行模式选择 ======${RESET}"
    echo -e " 1. 直接部署全新完整环境 (包含全新本地 PostgreSQL 15 容器)"
    echo -e " 2. 连接外部/远程已有的 PostgreSQL 数据库 (需提前手动创建好数据库)"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 MetaTube 宿主机访问端口 [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # ------------------ 模式 1：全套本地内置容器化 ------------------
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}正在自动计算生成数据库高强度防破解随机密码...${RESET}"
        local rand_db_pass=$(openssl rand -hex 16)
        local db_user="metatube"
        local db_name="metatube"

        cat << EOF > "$COMPOSE_FILE"
services:
  postgres:
    image: postgres:15-alpine
    container_name: metatube-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${db_user}
      - POSTGRES_PASSWORD=${rand_db_pass}
      - POSTGRES_DB=${db_name}
    volumes:
      - ${BASE_DIR}/db:/var/lib/postgresql/data

  metatube:
    image: ${DEFAULT_IMAGE}
    container_name: metatube
    restart: unless-stopped
    depends_on:
      - postgres
    ports:
      - "${custom_port}:8080"
    volumes:
      - ${BASE_DIR}/config:/config
    command: >
      -dsn "postgres://${db_user}:${rand_db_pass}@postgres:5432/${db_name}?sslmode=disable"
      -port 8080
      -db-auto-migrate
EOF

    # ------------------ 模式 2：连接外部/远程已有的 PostgreSQL（免建库） ------------------
    else
        echo -e "${CYAN}====== 远程/外部 PostgreSQL 信息输入 ======${RESET}"
        echo -ne "${YELLOW}请输入外部 PostgreSQL 的 IP 或域名 [默认: 127.0.0.1]: ${RESET}"
        read -r ext_host
        [[ -z "$ext_host" ]] && ext_host="127.0.0.1"
        
        echo -ne "${YELLOW}请输入 PostgreSQL 端口 [默认: 5432]: ${RESET}"
        read -r ext_port
        [[ -z "$ext_port" ]] && ext_port="5432"
        
        echo -ne "${YELLOW}请输入数据库用户名 [默认: metatube]: ${RESET}"
        read -r ext_user
        [[ -z "$ext_user" ]] && ext_user="metatube"
        
        echo -ne "${YELLOW}请输入数据库密码: ${RESET}"
        read -r ext_pass
        
        echo -ne "${YELLOW}请输入目标数据库名 [默认: metatube]: ${RESET}"
        read -r ext_dbname
        [[ -z "$ext_dbname" ]] && ext_dbname="metatube"

        # 突破 Docker 宿主机回环地址限制
        if [[ "$ext_host" == "127.0.0.1" || "$ext_host" == "localhost" ]]; then
            ext_host="172.17.0.1"
        fi

        cat << EOF > "$COMPOSE_FILE"
services:
  metatube:
    image: ${DEFAULT_IMAGE}
    container_name: metatube
    restart: unless-stopped
    ports:
      - "${custom_port}:8080"
    volumes:
      - ${BASE_DIR}/config:/config
    command: >
      -dsn "postgres://${ext_user}:${ext_pass}@${ext_host}:${ext_port}/${ext_dbname}?sslmode=disable"
      -port 8080
      -db-auto-migrate
EOF
    fi

    # ------------------ 启动集群 ------------------
    echo -e "${YELLOW}正在通过 Docker Compose 启动 MetaTube 服务中...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    if [ $? -ne 0 ]; then
        echo -e "${RED}部署失败，请检查 Docker 日志。${RESET}"
        return
    fi

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             MetaTube 部署成功！                    ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}访问端点(URL) : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}映射宿主机端口 : ${custom_port}${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}内置库密码凭证 : 用户:${db_user} | 密码:${rand_db_pass} | 库名:${db_name}${RESET}"
    else
        echo -e "${YELLOW}连接外部数据库 : ${ext_host}:${ext_port} -> 库名:${ext_dbname}${RESET}"
    fi
    echo -e "${YELLOW}部署工作路径   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新服务
update_metatube() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取 MetaTube 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}服务已升级并拉升至最新状态！${RESET}"
}

# 卸载集群
uninstall_metatube() {
    echo -ne "${RED}确定要注销并删除 MetaTube 服务集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已全部终止并移除。${RESET}"
            echo -ne "${RED}是否同步清理掉本地所有挂载的数据卷和数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                cd "$BASE_DIR" && docker compose down -v
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}工作目录及数据已被彻底清除。${RESET}"
            fi
        else
            docker rm -f metatube metatube-postgres 2>/dev/null
        fi
        echo -e "${GREEN}完全卸载完毕！${RESET}"
    fi
}

# 周期控制
start_mt() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已正常启动${RESET}"; }
stop_mt() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已安全暂停${RESET}"; }
restart_mt() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已完成软重启${RESET}"; }
logs_mt() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

# 配置显示
show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态   : $status"
    echo -e "${YELLOW}实际映射端口   : ${web_port}${RESET}"
    echo -e "${YELLOW}本地项目路径   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 主菜单
menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}      ◈  MetaTube 管理面板  ◈      ${RESET}"
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
        1) install_metatube ;;
        2) update_metatube ;;
        3) uninstall_metatube ;;
        4) start_mt ;;
        5) stop_mt ;;
        6) restart_mt ;;
        7) logs_mt ;;
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
