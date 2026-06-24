#!/bin/bash
# =================================================================
# BepUSDT 服务 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/bepusdt-panel"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
CONTAINER_NAME="bepusdt"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器的状态、映射端口和数据目录
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ] || [ "$(docker ps -q -f name=bepusdt-panel-bepusdt-1)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ] || [ "$(docker ps -aq -f name=bepusdt-panel-bepusdt-1)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 从 .env 文件中提取配置信息（如果存在）
    if [ -f "$ENV_FILE" ]; then
        webui_port=$(grep "^PANEL_PORT=" "$ENV_FILE" | cut -d'=' -f2 | sed 's/\r//g')
        [[ -z "$webui_port" ]] && webui_port="8080"
        
        pg_dsn=$(grep "^POSTGRESQL_DSN=" "$ENV_FILE" | cut -d'=' -f2- | sed 's/\r//g')
        
        data_dir=$(grep "\- " "$COMPOSE_FILE" 2>/dev/null | grep ":/var/lib/bepusdt" | awk -F':' '{print $1}' | sed 's/-//g' | sed 's/^[ \t]*//' | head -n 1)
        [[ -z "$data_dir" ]] && data_dir="/opt/bepusdt"
    else
        webui_port="N/A"
        pg_dsn="N/A"
        data_dir="N/A"
    fi
}

get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
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

# 部署 BepUSDT
install_translate() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 配置映射端口
    echo -ne "${YELLOW}请输入 BepUSDT 访问端口 (宿主机端口) [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"

    # 2. 配置数据目录
    echo -ne "${YELLOW}请输入宿主机数据存储绝对路径 [默认: /opt/bepusdt]: ${RESET}"
    read -r custom_data
    [[ -z "$custom_data" ]] && custom_data="/opt/bepusdt"

    # 3. 配置 PostgreSQL 数据库连接信息（不填直接剔除）
    echo -e "\n${CYAN}--- PostgreSQL 动态配置 (不填直接回车去掉该参数项) ---${RESET}"
    
    echo -ne "${YELLOW}1. 用户名: ${RESET}"
    read -r db_user

    echo -ne "${YELLOW}2. 密码: ${RESET}"
    read -r db_pass

    echo -ne "${YELLOW}3. 服务器地址端口 (如 localhost:5432): ${RESET}"
    read -r db_host

    echo -ne "${YELLOW}4. 数据库名称: ${RESET}"
    read -r db_name

    # --- 核心动态拼接逻辑 ---
    local auth_part=""
    local host_part=""
    local db_part=""

    # 只有填了用户名才去处理账号密码组合
    if [[ -n "$db_user" ]]; then
        if [[ -n "$db_pass" ]]; then
            auth_part="${db_user}:${db_pass}@"
        else
            auth_part="${db_user}@"
        fi
    elif [[ -n "$db_pass" ]]; then
        auth_part=":${db_pass}@"
    fi

    # 只有填了服务器才拼接地址
    if [[ -n "$db_host" ]]; then
        host_part="$db_host"
    fi

    # 只有填了数据库名才拼斜杠和名称，否则直接留空（连斜杠都不带）
    if [[ -n "$db_name" ]]; then
        db_part="/${db_name}"
    fi

    # 组合最终 DSN
    constructed_dsn="postgres://${auth_part}${host_part}${db_part}?sslmode=disable&connect_timeout=3"

    # 创建自定义持久化根目录
    mkdir -p "${custom_data}"
    chmod -R 777 "$BASE_DIR" "${custom_data}"

    # 生成环境变量 .env 配置文件
    echo -e "${YELLOW}正在生成环境变量 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
PANEL_PORT=${custom_port}
POSTGRESQL_DSN=${constructed_dsn}
EOF

    # 动态生成 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  bepusdt:
    image: v03413/bepusdt:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "\${PANEL_PORT:-8080}:8080"
    environment:
      - POSTGRESQL_DSN=\${POSTGRESQL_DSN}
    volumes:
      - ${custom_data}:/var/lib/bepusdt
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 BepUSDT 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      BepUSDT 部署成功！      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}生成的 DSN 串 : ${constructed_dsn}${RESET}"
    echo -e "${YELLOW}服务访问地址  : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}面板配置目录  : $BASE_DIR${RESET}"
    echo -e "${YELLOW}用户数据存储  : ${custom_data}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新 BepUSDT 镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载服务
uninstall_translate() {
    get_status_info
    echo -ne "${YELLOW}确定要卸载并删除 BepUSDT 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            rm -rf "$BASE_DIR"
            echo -e "${GREEN}项目配置主目录 [${BASE_DIR}] 已彻底清理。${RESET}"
        else
            echo -e "${RED}未找到 compose 文件，尝试强制清理可能残留的容器...${RESET}"
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}所有容器已重启${RESET}"; }
logs_translate() { cd "$BASE_DIR" && docker compose logs -f; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}BepUSDT 服务状态    : ${status}"
    echo -e "${YELLOW}当前 PostgreSQL DSN : ${pg_dsn}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  BepUSDT 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}服务状态 : ${status}"
    echo -e "${GREEN}映射端口 : ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_translate ;;
        2) update_translate ;;
        3) uninstall_translate ;;
        4) start_translate ;;
        5) stop_translate ;;
        6) restart_translate ;;
        7) logs_translate ;;
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
