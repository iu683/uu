#!/bin/bash
# =================================================================
# grok2api Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="grok2api"
BASE_DIR="/opt/grok2api"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
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
# 动态获取容器状态
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 读取映射端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8000"
    else
        webui_port="N/A"
    fi
}

# 部署 grok2api
install_grok2api() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 宿主机映射端口
    echo -ne "${YELLOW}请输入服务访问端口 (宿主机 Host Port) [默认: 8000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8000"

    # 2. 数据与日志存储路径
    echo -ne "${YELLOW}请输入数据与日志宿主机存放绝对基准路径 [默认: /opt/grok2api]: ${RESET}"
    read -r custom_path
    [[ -z "$custom_path" ]] && custom_path="/opt/grok2api"

    # 创建子目录并赋权
    mkdir -p "$custom_path/data" "$custom_path/logs"
    chmod -R 777 "$custom_path" 2>/dev/null

    # 3. 高级可选服务询问 (回车默认不开启)
    echo -ne "${YELLOW}是否启用 CF 自动刷新功能 (Flaresolverr)？(y/n) [默认: n]: ${RESET}"
    read -r enable_cf
    [[ -z "$enable_cf" ]] && enable_cf="n"

    echo -ne "${YELLOW}是否启用 Warp 落地代理防止 IP 变脏？(y/n) [默认: n]: ${RESET}"
    read -r enable_warp
    [[ -z "$enable_warp" ]] && enable_warp="n"

    # 开始组织 docker-compose.yml 文本
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml...${RESET}"
    
    # 写入 compose 头部及主服务
    cat <<EOF > "$COMPOSE_FILE"
services:
  grok2api:
    container_name: grok2api
    image: ghcr.io/chenyme/grok2api:latest
    ports:
      - "\${HOST_PORT:-8000}:\${SERVER_PORT:-8000}"
    environment:
      TZ: Asia/Shanghai
      LOG_LEVEL: \${LOG_LEVEL:-INFO}
      SERVER_HOST: \${SERVER_HOST:-0.0.0.0}
      SERVER_PORT: \${SERVER_PORT:-8000}
      SERVER_WORKERS: \${SERVER_WORKERS:-1}
      ACCOUNT_STORAGE: \${ACCOUNT_STORAGE:-local}
      ACCOUNT_LOCAL_PATH: \${ACCOUNT_LOCAL_PATH:-data/accounts.db}
      ACCOUNT_REDIS_URL: \${ACCOUNT_REDIS_URL:-}
      ACCOUNT_MYSQL_URL: \${ACCOUNT_MYSQL_URL:-}
      ACCOUNT_POSTGRESQL_URL: \${ACCOUNT_POSTGRESQL_URL:-}
EOF

    # 处理 grok2api 服务内部针对 CF 的环境变量注释
    if [[ "$enable_cf" == "y" || "$enable_cf" == "Y" ]]; then
        cat <<EOF >> "$COMPOSE_FILE"
      FLARESOLVERR_URL: http://flaresolverr:8191
      CF_REFRESH_INTERVAL: "600"
      CF_TIMEOUT: "60"
EOF
    else
        cat <<EOF >> "$COMPOSE_FILE"
      # FLARESOLVERR_URL: http://flaresolverr:8191
      # CF_REFRESH_INTERVAL: "600"
      # CF_TIMEOUT: "60"
EOF
    fi

    # 写入主服务的卷挂载和重启策略
    cat <<EOF >> "$COMPOSE_FILE"
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
    restart: unless-stopped
EOF

    # 附加可选服务 1: Warp
    if [[ "$enable_warp" == "y" || "$enable_warp" == "Y" ]]; then
        cat <<EOF >> "$COMPOSE_FILE"

  warp:
    container_name: warp
    image: caomingjun/warp:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:1080:1080"
    environment:
      - WARP_SLEEP=2
    cap_add:
      - NET_ADMIN
EOF
    fi

    # 附加可选服务 2: Flaresolverr
    if [[ "$enable_cf" == "y" || "$enable_cf" == "Y" ]]; then
        cat <<EOF >> "$COMPOSE_FILE"

  flaresolverr:
    container_name: flaresolverr
    image: ghcr.io/flaresolverr/flaresolverr:latest
    ports:
      - "127.0.0.1:8191:8191"
    environment:
      TZ: Asia/Shanghai
      LOG_LEVEL: info
    restart: unless-stopped
EOF
    fi


    # 开始组织并生成环境配置文件 .env
    echo -e "${YELLOW}正在生成配对的 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
# ==================== 基础运行 ====================
TZ=Asia/Shanghai
LOG_LEVEL=INFO
LOG_FILE_ENABLED=true
ACCOUNT_SYNC_INTERVAL=30

# ==================== Web 服务 / Docker Compose ====================
SERVER_HOST=0.0.0.0
SERVER_PORT=8000
SERVER_WORKERS=1

# Docker Compose 宿主机映射端口
HOST_PORT=${custom_port}

# ==================== 账号存储（启动期） ====================
ACCOUNT_STORAGE=local

# ==================== 可选：本地数据 / 日志目录 ====================
DATA_DIR=${custom_path}/data
LOG_DIR=${custom_path}/logs
EOF

    # 纠正或者软链接本地 compose 执行目录内的数据流，确保和用户自定路径一致
    rm -rf "$BASE_DIR/data" "$BASE_DIR/logs"
    ln -sf "$custom_path/data" "$BASE_DIR/data"
    ln -sf "$custom_path/logs" "$BASE_DIR/logs"

    echo -e "${YELLOW}正在通过 Docker Compose 启动 grok2api 服务集群...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务初始化 (约5秒)...${RESET}"
    sleep 5

    local current_ip
    current_ip=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}        grok2api 部署成功！       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址     : http://${current_ip}:${custom_port}${RESET}"
    echo -e "${YELLOW}数据存储路径     : $custom_path/data${RESET}"
    echo -e "${YELLOW}日志存储路径     : $custom_path/logs${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${CYAN}💡 功能开启状态：${RESET}"
    echo -e "${YELLOW}CF 盾自动刷新服务 : $([ "$enable_cf" = "y" ] && echo -e "${GREEN}已开启${RESET}" || echo -e "${RED}未开启${RESET}")${RESET}"
    echo -e "${YELLOW}Warp 落地代理服务 : $([ "$enable_warp" = "y" ] && echo -e "${GREEN}开(请至config.toml配置socks5://warp:1080)${RESET}" || echo -e "${RED}未开启${RESET}")${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_grok2api() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新服务集群镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}集群更新完成！组件均已处于最新状态。${RESET}"
}

# 卸载集群
uninstall_grok2api() {
    echo -ne "${YELLOW}确定要卸载并删除 grok2api 容器集群吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器集群已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地存储的所有账号数据库和配置日志？(y/n): ${RESET}"
            read -r clean_data
            if [[ "$clean_data" == "y" || "$clean_data" == "Y" ]]; then
                # 从 .env 提取路径安全清理
                local real_data
                real_data=$(grep DATA_DIR "$ENV_FILE" | cut -d'=' -f2)
                rm -rf "$BASE_DIR"
                if [[ -n "$real_data" && -d "$(dirname "$real_data")" ]]; then
                    rm -rf "$(dirname "$real_data")"
                fi
                echo -e "${GREEN}所有数据资产和配置文件已彻底清理。${RESET}"
            fi
        else
            docker rm -f grok2api warp flaresolverr 2>/dev/null
            echo -e "${GREEN}独立容器已强行清除。${RESET}"
        fi
        echo -e "${GREEN}卸载彻底完成！${RESET}"
    fi
}

start_grok2api() { 
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}集群服务已启动${RESET}"
    else
        echo -e "${RED}错误: 未检测到配置，无法启动。${RESET}"
    fi
}

stop_grok2api() { 
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}集群服务已挂起停止${RESET}"
    else
        echo -e "${RED}错误: 未检测到配置，无法停止。${RESET}"
    fi
}

restart_grok2api() { 
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}集群服务已成功重启${RESET}"
    else
        echo -e "${RED}错误: 未检测到配置，无法重启。${RESET}"
    fi
}

logs_grok2api() { 
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        docker logs -f "$CONTAINER_NAME"
    else
        echo -e "${RED}错误: 主业务容器不存在，无法追踪日志。${RESET}"
    fi
}

show_info() {
    get_status_info
    local current_ip
    current_ip=$(get_public_ip)
    
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}主服务状态     : $status"
    if [[ "$webui_port" == "N/A" ]]; then
        echo -e "${YELLOW}API 访问地址   : N/A${RESET}"
    else
        echo -e "${YELLOW}API 访问地址   : http://${current_ip}:${webui_port}${RESET}"
    fi
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${CYAN}📂 运行配置文件分布情况：${RESET}"
    echo -e "${YELLOW}Docker Compose 结构文件 : $COMPOSE_FILE${RESET}"
    echo -e "${YELLOW}底层环境变量映射文件    : $ENV_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  grok2api 管理面板  ◈    ${RESET}"
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
        1) install_grok2api ;;
        2) update_grok2api ;;
        3) uninstall_grok2api ;;
        4) start_grok2api ;;
        5) stop_grok2api ;;
        6) restart_grok2api ;;
        7) logs_grok2api ;;
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
