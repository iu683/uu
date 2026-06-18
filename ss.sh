#!/bin/bash
# =================================================================
# 小桔问卷 (Xiaoju Survey) Docker Compose 管理面板 
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\03 counseling31m"
RESET="\033[0m"

BASE_DIR="/opt/xiaoju-survey"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/survey.env"
DEFAULT_IMAGE="xiaojusurvey/xiaoju-survey:1.3.4-slim"

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
        if [ "$(docker ps -q -f name=xiaoju-survey)" ]; then
            status="${GREEN}运行中${RESET}"
            web_port=$(docker ps -f name=xiaoju-survey --format "{{.Ports}}" | sed -E 's/.*:([0-9]+)->.*/\1/' | head -n 1)
            if ! [[ "$web_port" =~ ^[0-9]+$ ]]; then
                web_port=$(sed -n '/xiaoju-survey:/,/^[[:space:]]*[a-zA-Z]/p' "$COMPOSE_FILE" | grep -E '\-[[:space:]]*["'\'']?[0-9]+:' | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"''-')
            fi
        elif [ "$(docker ps -aq -f name=xiaoju-survey)" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' xiaoju-survey 2>/dev/null)
        else
            status="${RED}未部署${RESET}"
        fi
        [[ -z "$web_port" ]] && web_port="8080"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署小桔问卷
install_survey() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    # 1. 基础参数配置
    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入小桔问卷宿主机映射访问端口 [默认: 8585]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8585"

    # 2. 数据库运行模式选择
    echo -e "\n${CYAN}====== MongoDB 数据库运行模式选择 ======${RESET}"
    echo -e " 1) 直接部署全新的 MongoDB 4 容器 (包含本地数据卷挂载)"
    echo -e " 2) 使用已有的外部/远程外部 MongoDB 数据库"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    local db_host="mongo"
    local db_port="27017"
    local db_user="root"
    local db_pass=""
    local db_auth_source="admin"

    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}使用全新内置 Mongo 容器，正在生成高强度随机密码...${RESET}"
        db_pass=$(openssl rand -hex 16)
    else
        echo -ne "${YELLOW}请输入远程 MongoDB 的 IP 或域名 [例如: 47.79.88.134]: ${RESET}"
        read -r ext_db_ip
        echo -ne "${YELLOW}请输入远程 MongoDB 端口 [默认: 27017]: ${RESET}"
        read -r ext_db_port
        [[ -z "$ext_db_port" ]] && ext_db_port="27017"
        db_host="$ext_db_ip"
        db_port="$ext_db_port"
        echo -ne "${YELLOW}请输入远程 MongoDB 用户名 [默认: root]: ${RESET}"
        read -r db_user
        [[ -z "$db_user" ]] && db_user="root"
        echo -ne "${YELLOW}请输入远程 MongoDB 密码: ${RESET}"
        read -r db_pass
        echo -ne "${YELLOW}请输入远程认证数据库 authSource [默认: admin]: ${RESET}"
        read -r db_auth_source
        [[ -z "$db_auth_source" ]] && db_auth_source="admin"
        
        # 兼容本地宿主机回环网关
        if [[ "$ext_db_ip" == "127.0.0.1" || "$ext_db_ip" == "localhost" ]]; then
            db_host="172.17.0.1"
        fi
    fi

    # 3. 组装安全的 MongoDB 连接 URL
    local mongo_url="mongodb://${db_user}:${db_pass}@${db_host}:${db_port}/?authSource=${db_auth_source}"

    # 4. 备份保留凭证文件 survey.env (全部通过双引号死锁防特殊字符截断)
    cat << EOF > "$ENV_FILE"
HOST_PORT="${custom_port}"
MONGO_USER="${db_user}"
MONGO_PASS="${db_pass}"
MONGO_URL="${mongo_url}"
EOF

    # 5. 生成规整的 docker-compose.yml (针对双模彻底分流)
    echo -e "${YELLOW}正在生成规范化 Docker Compose 配置文件...${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        # 模式 1：包含本地内置 Mongo 拓扑及桥接网络
        mkdir -p "$BASE_DIR/data/mongo"
        cat << EOF > "$COMPOSE_FILE"
services:
  mongo:
    image: mongo:4
    container_name: xiaoju-survey-mongo
    restart: always
    environment:
      MONGO_INITDB_ROOT_USERNAME: "${db_user}"
      MONGO_INITDB_ROOT_PASSWORD: "${db_pass}"
    volumes:
      - ./data/mongo:/data/db
    networks:
      - xiaoju-survey

  xiaoju-survey:
    image: ${DEFAULT_IMAGE}
    container_name: xiaoju-survey
    restart: always
    ports:
      - "127.0.0.1:${custom_port}:8080"
    environment:
      XIAOJU_SURVEY_MONGO_URL: "${mongo_url}"
    depends_on:
      - mongo
    networks:
      - xiaoju-survey

networks:
  xiaoju-survey:
    driver: bridge
EOF
    else
        # 模式 2：纯净外部远程对接，无本地 mongo 节点，无 networks 隔离
        cat << EOF > "$COMPOSE_FILE"
services:
  xiaoju-survey:
    image: ${DEFAULT_IMAGE}
    container_name: xiaoju-survey
    restart: always
    ports:
      - "127.0.0.1:${custom_port}:8080"
    environment:
      XIAOJU_SURVEY_MONGO_URL: "${mongo_url}"
EOF
    fi

    # 6. 清理残余并重新拉起新集群
    echo -e "${YELLOW}正在通过 Docker Compose 部署应用状态...${RESET}"
    cd "$BASE_DIR"
    docker compose down -v 2>/dev/null
    docker compose up -d --force-recreate

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 服务拉起失败，请检查端口 ${custom_port} 是否被占用。${RESET}"
        return
    fi

    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             小桔问卷系统部署成功！                   ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}内部提取端口   : ${custom_port} (绑定在 127.0.0.1)${RESET}"
    echo -e "${YELLOW}本地 Nginx 反代: http://127.0.0.1:${custom_port}${RESET}"
    echo -e "----------------------------------------------------"
    echo -e "${CYAN}[MongoDB 凭据回显]${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}Mongo 运行模式 : ${GREEN}全新内置容器 (Mongo 4)${RESET}"
        echo -e "${YELLOW}安全随机密码   : ${GREEN}${db_pass}${RESET}"
    else
        echo -e "${YELLOW}Mongo 运行模式 : ${CYAN}外部远程连接${RESET}"
        echo -e "${YELLOW}远程目标主机   : ${db_host}:${db_port}${RESET}"
        echo -e "${YELLOW}认证库名称     : ${db_auth_source}${RESET}"
    fi
    echo -e "----------------------------------------------------"
    echo -e "${YELLOW}持久化工作目录 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_survey() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新小桔问卷镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}升级完成！${RESET}"
}

# 卸载小桔问卷
uninstall_survey() {
    echo -ne "${RED}确定要完全卸载并删除小桔问卷服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            rm -rf "$BASE_DIR"
        else
            docker rm -f xiaoju-survey xiaoju-survey-mongo 2>/dev/null
        fi
        echo -e "${GREEN}完全卸载成功，数据已彻底清理。${RESET}"
    fi
}

start_survey() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已拉起运行${RESET}"; }
stop_survey() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止运行${RESET}"; }
restart_survey() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已成功重启${RESET}"; }
logs_survey() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

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
    echo -e "${GREEN}     ◈  小桔问卷 管理面板  ◈        ${RESET}"
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
        1) install_survey ;;
        2) update_survey ;;
        3) uninstall_survey ;;
        4) start_survey ;;
        5) stop_survey ;;
        6) restart_survey ;;
        7) logs_survey ;;
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
