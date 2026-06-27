#!/bin/bash
# =================================================================
# Kerkerker 工具箱 Docker Compose 管理面板 (本地挂载 & 精细化远程DB版)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="kerkerker-app"
BASE_DIR="/opt/kerkerker"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口等
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3008"
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
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

# 部署 Kerkerker
install_utils() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 端口配置
    echo -ne "${YELLOW}请输入 Kerkerker 访问端口 [默认: 3008]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3008"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 2. 管理员密码配置
    echo -ne "${YELLOW}请设置管理员密码 (ADMIN_PASSWORD) [默认: admin123]: ${RESET}"
    read -r admin_password
    [[ -z "$admin_password" ]] && admin_password="admin123"

    # 3. 豆瓣 API 微服务配置
    echo -ne "${YELLOW}请输入豆瓣 API 微服务地址 (留空则不配置): ${RESET}"
    read -r douban_api_url

    # 4. 数据库模式选择
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${YELLOW}请选择 MongoDB 数据库类型:${RESET}"
    echo -e "  ${GREEN}1)${RESET} 安装本地 MongoDB (数据挂载至 $BASE_DIR/mongodb_data)"
    echo -e "  ${GREEN}2)${RESET} 连接远程/已有 MongoDB (按指定参数交互连接)"
    echo -ne "${YELLOW}请选择 [默认: 1]: ${RESET}"
    read -r db_choice
    [[ -z "$db_choice" ]] && db_choice="1"

    if [[ "$db_choice" == "2" ]]; then
        # 你的自定义远程 DB 交互逻辑
        echo -ne "${YELLOW}请输入远程 MongoDB 的 IP 或域名: ${RESET}"
        read -r ext_db_ip
        if [[ -z "$ext_db_ip" ]]; then
            echo -e "${RED}错误: 数据库 IP 或域名不能为空！${RESET}"
            return
        fi

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
        
        # 兼容本地宿主机回环网关 (使用 Compose 标准的 host.docker.internal 获得更好的平台兼容性)
        local has_extra_host="false"
        if [[ "$ext_db_ip" == "127.0.0.1" || "$ext_db_ip" == "localhost" ]]; then
            db_host="host.docker.internal"
            has_extra_host="true"
        fi

        # 组装安全的 MongoDB 连接 URL
        local mongodb_uri="mongodb://${db_user}:${db_pass}@${db_host}:${db_port}/kerkerker?authSource=${db_auth_source}"

        # 生成不含本地数据库的 compose 文件
        echo -e "${YELLOW}正在生成连接远程数据库的 docker-compose.yml...${RESET}"
        
        # 构建基础 Compose 结构
        cat <<EOF > "$COMPOSE_FILE"
services:
  app:
    image: unilei/kerkerker:latest
    container_name: ${CONTAINER_NAME}
    ports:
      - "${custom_port}:3000"
    environment:
      - NODE_ENV=production
      - ADMIN_PASSWORD=${admin_password}
      - MONGODB_URI=${mongodb_uri}
      - NEXT_PUBLIC_DOUBAN_API_URL=${douban_api_url}
    restart: unless-stopped
EOF

        # 如果连接的是宿主机本地，追加 extra_hosts 字段使其网络畅通
        if [[ "$has_extra_host" == "true" ]]; then
            cat <<EOF >> "$COMPOSE_FILE"
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF
        fi

    else
        # 本地数据库流程（含宿主机本地目录挂载）
        mkdir -p "$BASE_DIR/mongodb_data"
        mkdir -p "$BASE_DIR/mongodb_config"
        
        echo -e "${YELLOW}正在生成含本地挂载的 docker-compose.yml...${RESET}"
        cat <<EOF > "$COMPOSE_FILE"
services:
  app:
    image: unilei/kerkerker:latest
    container_name: ${CONTAINER_NAME}
    ports:
      - "${custom_port}:3000"
    environment:
      - NODE_ENV=production
      - ADMIN_PASSWORD=${admin_password}
      - MONGODB_URI=mongodb://mongodb:27017/kerkerker
      - NEXT_PUBLIC_DOUBAN_API_URL=${douban_api_url}
    depends_on:
      mongodb:
        condition: service_healthy
    networks:
      - kerkerker-network
    restart: unless-stopped

  mongodb:
    image: mongo:7
    container_name: kerkerker-mongodb
    ports:
      - "27018:27017"
    environment:
      - MONGO_INITDB_DATABASE=kerkerker
    volumes:
      - ${BASE_DIR}/mongodb_data:/data/db
      - ${BASE_DIR}/mongodb_config:/data/configdb
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - kerkerker-network
    restart: unless-stopped

networks:
  kerkerker-network:
    driver: bridge
EOF
    fi

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Kerkerker 堆栈...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器群初始化与网络连接检查 (约5秒)...${RESET}"
    sleep 5

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     Kerkerker 部署成功！      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}管理员密码     : ${admin_password}${RESET}"
    [[ "$db_choice" == "1" ]] && echo -e "${YELLOW}本地数据挂载点 : $BASE_DIR/mongodb_data${RESET}"
    [[ "$db_choice" == "2" ]] && echo -e "${YELLOW}数据库连接方式 : 远程数据库 (${db_host})${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 Kerkerker 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像并更新...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！${RESET}"
}

# 卸载 Kerkerker
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 Kerkerker 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时彻底删除本地配置及数据库挂载目录 ($BASE_DIR)？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地目录及数据已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" kerkerker-mongodb 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}核心镜像       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}管理员密码     : ${admin_password}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Kerkerker 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
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
        1) install_utils ;;
        2) update_utils ;;
        3) uninstall_utils ;;
        4) start_utils ;;
        5) stop_utils ;;
        6) restart_utils ;;
        7) logs_utils ;;
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
