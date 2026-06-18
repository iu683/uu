#!/bin/bash
# =================================================================
# Subboost Docker Compose 管理面板
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/subboost"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
DEFAULT_IMAGE="ghcr.io/subboost/subboost:latest"

# 检测依赖环境
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器整体状态和端口
get_status_info() {
    if [ -f "$COMPOSE_FILE" ]; then
        if [ "$(docker ps -q -f name=subboost-app)" ]; then
            status="${GREEN}运行中${RESET}"
        elif [ "$(docker ps -aq -f name=subboost-app)" ]; then
            status="${YELLOW}已停止${RESET}"
        else
            status="${RED}未部署${RESET}"
        fi
        
        if [ -f "$ENV_FILE" ]; then
            web_port=$(grep -E "^SUBBOOST_PORT=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
        fi
        [[ -z "$web_port" ]] && web_port="3000"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://4.ip.sb"; do
        ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
    done
    echo "127.0.0.1" && return 0
}

# 部署 Subboost
install_subboost() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 数据库模式选择 ======${RESET}"
    echo -e " 1. 直接部署全新的 PostgreSQL (Docker 容器化)"
    echo -e " 2. 使用已有的外部 PostgreSQL (自建/云数据库)"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Subboost 访问端口 [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入外部访问域名或公网IP (例如 http://1.2.3.4:${custom_port}) [回车自动探测]: ${RESET}"
    read -r custom_url
    if [[ -z "$custom_url" ]]; then
        DETECT_IP=$(get_public_ip)
        custom_url="http://${DETECT_IP}:${custom_port}"
    fi

    # 自动化生成应用核心安全密钥
    ENC_KEY=$(openssl rand -hex 32)
    JWT_SEC=$(openssl rand -hex 32)
    CRON_SEC=$(openssl rand -hex 16)

    # ------------------ 模式 1：全新 Docker 部署 PostgreSQL ------------------
    if [[ "$db_mode" == "1" ]]; then
        DB_PASS=$(openssl rand -hex 16)
        
        # 写入环境配置 (.env)
        cat <<EOF > "$ENV_FILE"
POSTGRES_DB=subboost
POSTGRES_USER=subboost
POSTGRES_PASSWORD=${DB_PASS}
DATABASE_URL=postgresql://subboost:${DB_PASS}@db:5432/subboost?schema=public

ENCRYPTION_KEY=${ENC_KEY}
JWT_SECRET=${JWT_SEC}
CRON_SECRET=${CRON_SEC}

APP_URL=${custom_url}
SUBBOOST_PORT=${custom_port}
SUBBOOST_IMAGE=${DEFAULT_IMAGE}
EOF

        # 生成包含 db 服务的完整 docker-compose.yml
        cat << 'EOF' > "$COMPOSE_FILE"
services:
  db:
    image: postgres:16-alpine
    container_name: subboost-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-subboost}
      POSTGRES_USER: ${POSTGRES_USER:-subboost}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD}
    volumes:
      - subboost-local-db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 10

  app:
    image: ${SUBBOOST_IMAGE:?set SUBBOOST_IMAGE}
    container_name: subboost-app
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "${SUBBOOST_PORT:-3000}:3000"
    environment:
      DATABASE_URL: ${DATABASE_URL:?set DATABASE_URL}
      ENCRYPTION_KEY: ${ENCRYPTION_KEY:?set ENCRYPTION_KEY}
      JWT_SECRET: ${JWT_SECRET:?set JWT_SECRET}
      CRON_SECRET: ${CRON_SECRET:?set CRON_SECRET}
      APP_URL: ${APP_URL:-http://localhost:3000}

  cron:
    image: curlimages/curl:8.11.1
    container_name: subboost-cron
    restart: unless-stopped
    depends_on:
      app:
        condition: service_started
    environment:
      CRON_SECRET: ${CRON_SECRET:?set CRON_SECRET}
    command: >
      sh -c '
      counter=0;
      while true; do
        echo "[local-cron] $(date -Iseconds) POST /api/cron/update-subscriptions"
        curl -fsS -X POST -H "Authorization: Bearer $${CRON_SECRET}" http://app:3000/api/cron/update-subscriptions || true
        
        if [ $((counter % 10)) -eq 0 ]; then
          echo "[local-cron] $(date -Iseconds) POST /api/cron/update-rule-index"
          curl -fsS -X POST -H "Authorization: Bearer $${CRON_SECRET}" http://app:3000/api/cron/update-rule-index || true
        fi
        
        counter=$((counter + 1))
        sleep 360
      done
      '

volumes:
  subboost-local-db:
EOF

    # ------------------ 模式 2：连接外部已有 PostgreSQL ------------------
    else
        echo -e "${CYAN}====== 外部数据库信息输入 ======${RESET}"
        echo -ne "${YELLOW}请输入外部 PostgreSQL 的 IP 或域名 [默认: 127.0.0.1]: ${RESET}"
        read -r ext_host
        [[ -z "$ext_host" ]] && ext_host="127.0.0.1"
        
        echo -ne "${YELLOW}请输入 PostgreSQL 端口 [默认: 5432]: ${RESET}"
        read -r ext_port
        [[ -z "$ext_port" ]] && ext_port="5432"
        
        echo -ne "${YELLOW}请输入数据库用户名 [默认: subboost]: ${RESET}"
        read -r ext_user
        [[ -z "$ext_user" ]] && ext_user="subboost"
        
        echo -ne "${YELLOW}请输入数据库密码: ${RESET}"
        read -r ext_pass
        
        echo -ne "${YELLOW}请输入数据库名 [默认: subboost]: ${RESET}"
        read -r ext_dbname
        [[ -z "$ext_dbname" ]] && ext_dbname="subboost"

        # 如果外部数据库运行在宿主机上，且写了 127.0.0.1，需自动转换为 docker 桥接网关 IP 以允许容器外连
        if [[ "$ext_host" == "127.0.0.1" || "$ext_host" == "localhost" ]]; then
            ext_host="172.17.0.1"
            echo -e "${YELLOW}提示: 检测到本地回环地址，已自动桥接为宿主机网卡 IP: 172.17.0.1${RESET}"
        fi

        # 写入连接外部库的环境配置 (.env)
        cat <<EOF > "$ENV_FILE"
DATABASE_URL=postgresql://${ext_user}:${ext_pass}@${ext_host}:${ext_port}/${ext_dbname}?schema=public

ENCRYPTION_KEY=${ENC_KEY}
JWT_SECRET=${JWT_SEC}
CRON_SECRET=${CRON_SEC}

APP_URL=${custom_url}
SUBBOOST_PORT=${custom_port}
SUBBOOST_IMAGE=${DEFAULT_IMAGE}
EOF

        # 生成精简版 docker-compose.yml（剥离 db 服务）
        cat << 'EOF' > "$COMPOSE_FILE"
services:
  app:
    image: ${SUBBOOST_IMAGE:?set SUBBOOST_IMAGE}
    container_name: subboost-app
    restart: unless-stopped
    ports:
      - "${SUBBOOST_PORT:-3000}:3000"
    environment:
      DATABASE_URL: ${DATABASE_URL:?set DATABASE_URL}
      ENCRYPTION_KEY: ${ENCRYPTION_KEY:?set ENCRYPTION_KEY}
      JWT_SECRET: ${JWT_SECRET:?set JWT_SECRET}
      CRON_SECRET: ${CRON_SECRET:?set CRON_SECRET}
      APP_URL: ${APP_URL:-http://localhost:3000}

  cron:
    image: curlimages/curl:8.11.1
    container_name: subboost-cron
    restart: unless-stopped
    depends_on:
      app:
        condition: service_started
    environment:
      CRON_SECRET: ${CRON_SECRET:?set CRON_SECRET}
    command: >
      sh -c '
      counter=0;
      while true; do
        echo "[local-cron] $(date -Iseconds) POST /api/cron/update-subscriptions"
        curl -fsS -X POST -H "Authorization: Bearer $${CRON_SECRET}" http://app:3000/api/cron/update-subscriptions || true
        
        if [ $((counter % 10)) -eq 0 ]; then
          echo "[local-cron] $(date -Iseconds) POST /api/cron/update-rule-index"
          curl -fsS -X POST -H "Authorization: Bearer $${CRON_SECRET}" http://app:3000/api/cron/update-rule-index || true
        fi
        
        counter=$((counter + 1))
        sleep 360
      done
      '
EOF
    fi

    # ------------------ 启动集群 ------------------
    echo -e "${YELLOW}正在通过 Docker Compose 启动 Subboost 服务集群...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    if [ $? -ne 0 ]; then
        echo -e "${RED}====================================================${RESET}"
        echo -e "${RED} 错误: 容器启动失败。请检查网络环境或外部数据库配置。${RESET}"
        echo -e "${RED}====================================================${RESET}"
        return
    fi

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             Subboost 部署成功！                    ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}应用访问地址   : ${custom_url}${RESET}"
    echo -e "${YELLOW}宿主机映射端口 : ${custom_port}${RESET}"
    echo -e "${YELLOW}数据库运行模式 : $([ "$db_mode" == "1" ] && echo '全新内置容器' || echo '外部已有数据库')${RESET}"
    echo -e "${YELLOW}CRON 鉴权密钥  : ${CRON_SEC}${RESET}"
    echo -e "${YELLOW}部署工作目录   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新 Subboost 镜像
update_subboost() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取 Subboost 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}集群更新完成！${RESET}"
}

# 卸载 Subboost
uninstall_subboost() {
    echo -ne "${RED}确定要卸载并删除 Subboost 容器集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}是否同时删除所有工作目录及可能存在的数据卷？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                cd "$BASE_DIR" && docker compose down -v
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}工作目录及 Docker 卷已彻底清理。${RESET}"
            fi
        else
            docker rm -f subboost-app subboost-db subboost-cron 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

# 控制命令
start_sb() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}Subboost 服务集群已启动${RESET}"; }
stop_sb() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}Subboost 服务集群已停止${RESET}"; }
restart_sb() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}Subboost 服务集群已重启${RESET}"; }
logs_sb() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

# 显示配置面板
show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态   : $status"
    if [ -f "$ENV_FILE" ]; then
        local app_url=$(grep -E "^APP_URL=" "$ENV_FILE" | cut -d'=' -f2)
        local cron_sec=$(grep -E "^CRON_SECRET=" "$ENV_FILE" | cut -d'=' -f2)
        echo -e "${YELLOW}外部访问地址   : ${app_url}${RESET}"
        echo -e "${YELLOW}宿主机映射端口 : ${web_port}${RESET}"
        echo -e "${YELLOW}CRON 鉴权密钥  : ${cron_sec}${RESET}"
    else
        echo -e "${RED}未检测到环境配置文件 (.env)${RESET}"
    fi
    echo -e "${YELLOW}部署工作路径   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 主菜单
menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}      ◈  Subboost 管理面板  ◈       ${RESET}"
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
        1) install_subboost ;;
        2) update_subboost ;;
        3) uninstall_subboost ;;
        4) start_sb ;;
        5) stop_sb ;;
        6) restart_sb ;;
        7) logs_sb ;;
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
