#!/bin/bash
# =================================================================
# Mozilla Send (双模智选 + 远程分区号版) Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="send"
REDIS_CONTAINER_NAME="send_redis"
DEFAULT_BASE_DIR="/opt/send"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口和数据目录
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

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "1443/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="1443"

        custom_uploads_dir=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/uploads"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        if [[ -n "$custom_uploads_dir" ]]; then
            BASE_DIR=$(dirname "$custom_uploads_dir")
        fi
    fi
    
    [[ -z "$BASE_DIR" || "$BASE_DIR" == "." ]] && BASE_DIR="$DEFAULT_BASE_DIR"
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
    [[ -z "$custom_uploads_dir" ]] && custom_uploads_dir="$BASE_DIR/uploads"
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

# 部署 Send
install_send() {
    check_dependencies
    
    echo -e "${CYAN}====== 1. 基础环境参数配置 ======${RESET}"
    
    # 1. 端口配置
    echo -ne "${YELLOW}请输入 Send 访问端口 [默认: 1443]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="1443"

    # 2. 存放目录
    echo -ne "${YELLOW}请输入面板配置文件存放路径 [默认: $DEFAULT_BASE_DIR]: ${RESET}"
    read -r input_base
    [[ -z "$input_base" ]] && input_base="$DEFAULT_BASE_DIR"
    BASE_DIR="$input_base"
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

    # 3. 自定义上传路径
    echo -ne "${YELLOW}请输入【文件上传(uploads)】宿主机存储绝对路径 [默认: $BASE_DIR/uploads]: ${RESET}"
    read -r input_uploads
    [[ -z "$input_uploads" ]] && input_uploads="$BASE_DIR/uploads"
    custom_uploads_dir="$input_uploads"

    # 4. 业务环境变量
    DETECT_IP=$(get_public_ip)
    echo -ne "${YELLOW}请输入 Send 的外部访问域名/IP (BASE_URL) [默认: http://$DETECT_IP:$custom_port]: ${RESET}"
    read -r custom_domain
    [[ -z "$custom_domain" ]] && custom_domain="http://$DETECT_IP:$custom_port"

    echo -ne "${YELLOW}请输入单文件最大限制 (单位字节，默认 2.5GB = 2684354560): ${RESET}"
    read -r max_size
    [[ -z "$max_size" ]] && max_size="2684354560"

    # 5. 选择 Redis 模式
    echo -e "\n${CYAN}====== 2. Redis 运行模式选择 ======${RESET}"
    echo -e "${GREEN}1. 本地模式 ${RESET}(自动拉取并部署一个全新的本地 Redis 容器)"
    echo -e "${GREEN}2. 远程模式 ${RESET}(连接你现有的外部/其它服务器的 Redis 数据库，支持指定分区号)"
    echo -ne "${YELLOW}请选择 Redis 模式 [1 或 2, 默认 1]: ${RESET}"
    read -r redis_mode
    [[ -z "$redis_mode" ]] && redis_mode="1"

    # 创建基础目录
    mkdir -p "$BASE_DIR"
    mkdir -p "$custom_uploads_dir"
    chmod -R 777 "$BASE_DIR" "$custom_uploads_dir"

    if [[ "$redis_mode" == "1" ]]; then
        # 本地模式
        local custom_redis_dir="$BASE_DIR/redis_data"
        mkdir -p "$custom_redis_dir" && chmod -R 777 "$custom_redis_dir"
        
        echo -e "${YELLOW}正在生成 [本地 Redis 容器版] docker-compose.yml...${RESET}"
        cat <<EOF > "$COMPOSE_FILE"
services:
  send:
    image: registry.gitlab.com/timvisee/send:latest
    container_name: ${CONTAINER_NAME}
    depends_on:
      - redis
    ports:
      - "${custom_port}:1443"
    environment:
      - NODE_ENV=production
      - PORT=1443
      - BASE_URL=${custom_domain}
      - MAX_FILE_SIZE=${max_size}
      - REDIS_ENABLED=true
      - REDIS_HOST=redis
      - REDIS_PORT=6379
    volumes:
      - ${custom_uploads_dir}:/uploads
    restart: unless-stopped

  redis:
    image: redis:latest
    container_name: ${REDIS_CONTAINER_NAME}
    volumes:
      - ${custom_redis_dir}:/data
    restart: unless-stopped
EOF
        redis_info_str="内置本地 Redis 容器"
    else
        # 远程模式 (加入了分区号支持)
        echo -e "\n${CYAN}---> 请输入远程连接参数:${RESET}"
        echo -ne "${YELLOW}▶ 远程 Redis 服务器 IP 或 域名: ${RESET}"
        read -r remote_redis_host
        echo -ne "${YELLOW}▶ 远程 Redis 端口 [默认: 6379]: ${RESET}"
        read -r remote_redis_port
        [[ -z "$remote_redis_port" ]] && remote_redis_port="6379"
        echo -ne "${YELLOW}▶ 远程 Redis 连接密码 (无密码请直接敲回车): ${RESET}"
        read -r remote_redis_pass
        echo -ne "${YELLOW}▶ 远程 Redis 分区号 (DB Index) [默认: 0]: ${RESET}"
        read -r remote_redis_db
        [[ -z "$remote_redis_db" ]] && remote_redis_db="0"

        # 智能拼接带分区号的 URL 字符串
        if [[ -n "$remote_redis_pass" ]]; then
            redis_url="redis://:${remote_redis_pass}@${remote_redis_host}:${remote_redis_port}/${remote_redis_db}"
        else
            redis_url="redis://${remote_redis_host}:${remote_redis_port}/${remote_redis_db}"
        fi

        echo -e "${YELLOW}正在生成 [连接外部远程 Redis(分区:${remote_redis_db}) 版] docker-compose.yml...${RESET}"
        cat <<EOF > "$COMPOSE_FILE"
services:
  send:
    image: registry.gitlab.com/timvisee/send:latest
    container_name: ${CONTAINER_NAME}
    ports:
      - "${custom_port}:1443"
    environment:
      - NODE_ENV=production
      - PORT=1443
      - BASE_URL=${custom_domain}
      - MAX_FILE_SIZE=${max_size}
      - REDIS_ENABLED=true
      - REDIS_URL=${redis_url}
    volumes:
      - ${custom_uploads_dir}:/uploads
    restart: unless-stopped
EOF
        redis_info_str="外部远程 Redis (${remote_redis_host}:${remote_redis_port} / 分区: ${remote_redis_db})"
    fi

    echo -e "${YELLOW}正在通过 Docker Compose 启动服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务联调初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}=====================================================${RESET}"
    echo -e "${GREEN}                  Send 部署成功！                    ${RESET}"
    echo -e "${GREEN}=====================================================${RESET}"
    echo -e "${YELLOW}文件存储路径 ：$custom_uploads_dir${RESET}"
    echo -e "${YELLOW}Redis 运行模式：$redis_info_str${RESET}"
    echo -e "${YELLOW}服务访问地址 ：$custom_domain${RESET}"
    echo -e "${GREEN}=====================================================${RESET}"
}

# 更新镜像
update_send() {
    get_status_info
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！${RESET}"
}

# 卸载服务
uninstall_send() {
    get_status_info
    echo -ne "${YELLOW}确定要卸载并删除 Send 相关容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}服务已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地所有上传的文件和配置数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                rm -rf "$custom_uploads_dir"
                echo -e "${GREEN}本地自定义存储目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" "$REDIS_CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_send() { get_status_info && cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_send() { get_status_info && cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_send() { get_status_info && cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_send() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}=====================================================${RESET}"
    echo -e "${YELLOW}当前状态     : $status"
    echo -e "${YELLOW}核心镜像     : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}本地存储路径 : ${custom_uploads_dir}${RESET}"
    echo -e "${GREEN}=====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈  Mozilla Send 管理面板 ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}存储 :${RESET} ${CYAN}${custom_uploads_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新服务${RESET}"
    echo -e "${GREEN}3. 卸载服务${RESET}"
    echo -e "${GREEN}4. 启动服务${RESET}"
    echo -e "${GREEN}5. 停止服务${RESET}"
    echo -e "${GREEN}6. 重启服务${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_send ;;
        2) update_send ;;
        3) uninstall_send ;;
        4) start_send ;;
        5) stop_send ;;
        6) restart_send ;;
        7) logs_send ;;
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
