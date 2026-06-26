#!/bin/bash
# =================================================================
# Relay Panel Docker Compose 管理面板 (内置 SQLite / PostgreSQL 双模版)
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/relaypanel"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
PANEL_IMAGE="ghcr.io/moeshinx/relay-panel-panel:1.0.2"

# 生成随机字符串函数
generate_secret() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1:-32} | head -n 1
}

# 检测依赖环境
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

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

# 动态获取容器整体状态和端口
get_status_info() {
    if [ -f "$COMPOSE_FILE" ]; then
        # 匹配包含 relay-panel-panel 镜像或服务名为 panel 的容器
        local container_id=$(docker ps -q -f "name=panel")
        if [ -n "$container_id" ]; then
            status="${GREEN}运行中${RESET}"
            web_port=$(docker ps -f "id=$container_id" --format "{{.Ports}}" | sed -E 's/.*0.0.0.0:([0-9]+)->.*/\1/' | head -n 1)
            if ! [[ "$web_port" =~ ^[0-9]+$ ]]; then
                if [ -f "$ENV_FILE" ]; then
                    web_port=$(grep "RELAYPANEL_PANEL_PORT_BINDING" "$ENV_FILE" | awk -F ':' '{print $NF}')
                fi
            fi
        elif [ "$(docker ps -aq -f "name=panel")" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' $(docker ps -aq -f "name=panel" | head -n 1) 2>/dev/null)
        else
            status="${RED}未部署${RESET}"
        fi
        [[ -z "$web_port" || ! "$web_port" =~ ^[0-9]+$ ]] && web_port="18888"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署 Relay Panel
install_relaypanel() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 数据库模式选择 ======${RESET}"
    echo -e " 1. 使用内置轻量级 SQLite 数据库 (单文件，即开即用推荐)"
    echo -e " 2. 部署全新的 PostgreSQL 16 数据库容器后端"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Relay Panel Web 访问端口 [默认: 18888]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="18888"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 自动生成安全密钥
    local jwt_sec=$(generate_secret 32)
    local panel_k=$(generate_secret 16)

    # 基础配置文件写入
    cat << EOF > "$COMPOSE_FILE"
services:
  panel:
    image: ${PANEL_IMAGE}
    container_name: relaypanel-panel
    ports:
      - "\${RELAYPANEL_PANEL_PORT_BINDING:-0.0.0.0:${custom_port}}:18888"
    environment:
      - DATABASE_URL=\${DATABASE_URL:-sqlite:/app/data/data.db?mode=rwc}
      - LISTEN=0.0.0.0:18888
      - PUBLIC_DIR=/app/public
      - JWT_SECRET=\${JWT_SECRET}
      - PANEL_KEY=\${PANEL_KEY}
      - PUBLIC_PANEL_URL=\${PUBLIC_PANEL_URL:-}
      - GEOIP_ENABLED=\${GEOIP_ENABLED:-true}
      - GEOIP_CACHE_TTL=\${GEOIP_CACHE_TTL:-604800}
    volumes:
      - panel_data:/app/data
    restart: unless-stopped
EOF

    # ------------------ 模式 1：SQLite 模式 ------------------
    if [[ "$db_mode" == "1" ]]; then
        cat << EOF > "$ENV_FILE"
JWT_SECRET=${jwt_sec}
PANEL_KEY=${panel_k}
RELAYPANEL_PANEL_PORT_BINDING=0.0.0.0:${custom_port}
DATABASE_URL=sqlite:/app/data/data.db?mode=rwc
EOF
        
        # 闭合 docker-compose 的 volumes 声明
        cat << EOF >> "$COMPOSE_FILE"

volumes:
  panel_data:
EOF

        echo -e "${YELLOW}正在通过 Docker Compose 启动 Relay Panel (SQLite)...${RESET}"
        cd "$BASE_DIR" && docker compose up -d --force-recreate

    # ------------------ 模式 2：PostgreSQL 模式 ------------------
    else
        local db_pass=$(generate_secret 16)
        
        cat << EOF > "$ENV_FILE"
JWT_SECRET=${jwt_sec}
PANEL_KEY=${panel_k}
RELAYPANEL_PANEL_PORT_BINDING=0.0.0.0:${custom_port}
POSTGRES_DB=relaypanel
POSTGRES_USER=relaypanel
POSTGRES_PASSWORD=${db_pass}
DATABASE_URL=postgresql://relaypanel:${db_pass}@postgres:5432/relaypanel
EOF

        # 往 compose 文件追加 postgres 服务定义
        cat << EOF >> "$COMPOSE_FILE"
    depends_on:
      postgres:
        condition: service_healthy

  postgres:
    image: postgres:16-alpine
    container_name: relaypanel-postgres
    environment:
      - POSTGRES_DB=relaypanel
      - POSTGRES_USER=relaypanel
      - POSTGRES_PASSWORD=${db_pass}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U relaypanel -d relaypanel"]
      interval: 5s
      timeout: 5s
      retries: 5
      start_period: 10s
    restart: unless-stopped

volumes:
  panel_data:
  postgres_data:
EOF

        echo -e "${YELLOW}正在通过 Docker Compose 启动 Relay Panel 集群 (PostgreSQL)...${RESET}"
        cd "$BASE_DIR" && docker compose up -d --force-recreate
    fi

    if [ $? -ne 0 ]; then
        echo -e "${RED}====================================================${RESET}"
        echo -e "${RED} 错误: 容器启动失败。请检查网络或 Docker 日志。     ${RESET}"
        echo -e "${RED}====================================================${RESET}"
        return
    fi

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}              Relay Panel 部署成功！                 ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}面板访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}面板默认账号   : admin${RESET}"
    echo -e "${YELLOW}面板默认密码   : admin123${RESET}"
    echo -e "${YELLOW}宿主机映射端口 : ${custom_port}${RESET}"
    echo -ne "${YELLOW}数据库运行模式 : ${RESET}"
    if [[ "$db_mode" == "1" ]]; then 
        echo -e "${GREEN}内置轻量级 SQLite${RESET}"
    else 
        echo -e "${GREEN}内置容器化 PostgreSQL 16${RESET}"
        echo -e "${YELLOW}数据库初始凭证 : relaypanel / ${db_pass}${RESET}"
    fi
    echo -e "${YELLOW}安全 JWT_SECRET: ${jwt_sec}${RESET}"
    echo -e "${YELLOW}安全 PANEL_KEY : ${panel_k}${RESET}"
    echo -e "${YELLOW}部署工作目录   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${CYAN}提示: 如果需要添加转发节点(node)，请参考官方文档在节点服务器上独立运行。${RESET}"
}

# 更新镜像
update_relaypanel() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取 Relay Panel 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}服务更新完成！${RESET}"
}

# 卸载 Relay Panel
uninstall_relaypanel() {
    echo -ne "${RED}确定要卸载并删除 Relay Panel 服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}是否同时删除所有配置文件、缓存、数据库及数据卷文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                cd "$BASE_DIR" && docker compose down -v
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}所有相关数据文件及工作目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f relaypanel-panel relaypanel-postgres 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

# 基础生命周期控制
start_rp() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}Relay Panel 服务已启动${RESET}"; }
stop_rp() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}Relay Panel 服务已停止${RESET}"; }
restart_rp() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}Relay Panel 服务已重启${RESET}"; }
logs_rp() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

# 显示配置面板
show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态   : $status"
    echo -e "${YELLOW}宿主机映射端口 : ${web_port}${RESET}"
    echo -e "${YELLOW}工作路径       : ${BASE_DIR}${RESET}"
    if [ -f "$ENV_FILE" ]; then
        echo -e "${YELLOW}数据库连接串   : $(grep "DATABASE_URL" "$ENV_FILE" | cut -d'=' -f2-)${RESET}"
    fi
    echo -e "${GREEN}====================================================${RESET}"
}

# 主菜单
menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}    ◈  Relay Panel 管理面板  ◈     ${RESET}"
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
        1) install_relaypanel ;;
        2) update_relaypanel ;;
        3) uninstall_relaypanel ;;
        4) start_rp ;;
        5) stop_rp ;;
        6) restart_rp ;;
        7) logs_rp ;;
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
