#!/bin/bash
# =================================================================
# Nodeget Docker Compose 管理面板
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/nodeget"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
DEFAULT_IMAGE="genshinmc/nodeget:latest"

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
        if [ "$(docker ps -q -f name=nodeget-app)" ]; then
            status="${GREEN}运行中${RESET}"
        elif [ "$(docker ps -aq -f name=nodeget-app)" ]; then
            status="${YELLOW}已停止${RESET}"
        else
            status="${RED}未部署${RESET}"
        fi
        
        # 精准提取 Nodeget 宿主机映射端口
        web_port=$(grep -E "\-[[:space:]]*[\"']?([0-9.]+:)?[0-9]+" "$COMPOSE_FILE" | head -n 1 | awk -F ':' '{print $2 ? $2 : $1}' | tr -d '[:space:]"''-/tcp')
        [[ -z "$web_port" ]] && web_port="2211"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署 Nodeget
install_nodeget() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 数据库模式选择 ======${RESET}"
    echo -e " 1. 直接部署全新的 PostgreSQL 17 (Docker 容器化)"
    echo -e " 2. 使用已有的外部/远程 PostgreSQL (自建/云数据库)"
    echo -e " 3. 使用超轻量级本地 SQLite 数据库"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Nodeget 访问端口 [默认: 2211]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="2211"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # ------------------ 模式 1：全新 Docker 部署 PostgreSQL 17 ------------------
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}正在配置全新容器化 PostgreSQL 数据库环境...${RESET}"
        
        cat << EOF > "$COMPOSE_FILE"
name: nodeget-postgres

services:
  postgres:
    image: postgres:17-alpine
    container_name: nodeget-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: nodeget
      POSTGRES_USER: nodeget
      POSTGRES_PASSWORD: nodeget
    volumes:
      - ${BASE_DIR}/data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: [ "CMD-SHELL", "pg_isready -U nodeget -d nodeget" ]
      interval: 5s
      timeout: 5s
      retries: 20

  nodeget:
    image: ${DEFAULT_IMAGE}
    container_name: nodeget-app
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      NODEGET_DATABASE_URL: postgres://nodeget:nodeget@postgres:5432/nodeget
    ports:
      - "${custom_port}:2211"
    volumes:
      - ${BASE_DIR}/data/nodeget:/nodeget
EOF

    # ------------------ 模式 2：连接外部/远程已有 PostgreSQL ------------------
    elif [[ "$db_mode" == "2" ]]; then
        echo -e "${CYAN}====== 远程/外部数据库信息输入 ======${RESET}"
        echo -ne "${YELLOW}请输入外部 PostgreSQL 的 IP 或域名 [默认: 127.0.0.1]: ${RESET}"
        read -r ext_host
        [[ -z "$ext_host" ]] && ext_host="127.0.0.1"
        
        echo -ne "${YELLOW}请输入 PostgreSQL 端口 [默认: 5432]: ${RESET}"
        read -r ext_port
        [[ -z "$ext_port" ]] && ext_port="5432"
        
        echo -ne "${YELLOW}请输入数据库用户名 [默认: nodeget]: ${RESET}"
        read -r ext_user
        [[ -z "$ext_user" ]] && ext_user="nodeget"
        
        echo -ne "${YELLOW}请输入数据库密码 [默认: nodeget]: ${RESET}"
        read -r ext_pass
        [[ -z "$ext_pass" ]] && ext_pass="nodeget"
        
        echo -ne "${YELLOW}请输入数据库名 [默认: nodeget]: ${RESET}"
        read -r ext_dbname
        [[ -z "$ext_dbname" ]] && ext_dbname="nodeget"

        # 处理本地回环外连突破
        if [[ "$ext_host" == "127.0.0.1" || "$ext_host" == "localhost" ]]; then
            ext_host="172.17.0.1"
            echo -e "${YELLOW}提示: 检测到本地回环地址，已自动桥接至宿主机网卡 IP: 172.17.0.1${RESET}"
        fi

        cat << EOF > "$COMPOSE_FILE"
name: nodeget-postgres

services:
  nodeget:
    image: ${DEFAULT_IMAGE}
    container_name: nodeget-app
    restart: unless-stopped
    environment:
      NODEGET_DATABASE_URL: postgres://${ext_user}:${ext_pass}@${ext_host}:${ext_port}/${ext_dbname}
    ports:
      - "${custom_port}:2211"
    volumes:
      - ${BASE_DIR}/data/nodeget:/nodeget
EOF

    # ------------------ 模式 3：使用本地轻量级 SQLite 数据库 ------------------
    else
        echo -e "${YELLOW}正在配置轻量级本地 SQLite 数据库环境...${RESET}"
        mkdir -p "${BASE_DIR}/data"
        
        cat << EOF > "$COMPOSE_FILE"
name: nodeget-sqlite

services:
  nodeget:
    image: ${DEFAULT_IMAGE}
    container_name: nodeget-app
    restart: unless-stopped
    environment:
      NODEGET_DATABASE_URL: sqlite:///nodeget/nodeget.db?mode=rwc
    ports:
      - "${custom_port}:2211"
    volumes:
      - ${BASE_DIR}/data:/nodeget
EOF
    fi

    # ------------------ 启动集群 ------------------
    echo -e "${YELLOW}正在通过 Docker Compose 启动 Nodeget 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    if [ $? -ne 0 ]; then
        echo -e "${RED}====================================================${RESET}"
        echo -e "${RED} 错误: 容器启动失败。请检查网络环境或数据库配置。   ${RESET}"
        echo -e "${RED}====================================================${RESET}"
        return
    fi

    # ------------------ 自动化获取 Super Token 逻辑 ------------------
    echo -e "${YELLOW}正在等待容器初始化并提取 Super Token (最多等待 30 秒)...${RESET}"
    local token=""
    for i in {1..30}; do
        sleep 1
        token=$(docker logs nodeget-app 2>&1 | grep -E 'Super Token')
        if [[ -n "$token" ]]; then
            break
        fi
        echo -n "."
    done
    echo "" # 换行

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             Nodeget 部署成功！                     ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}应用访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}宿主机映射端口 : ${custom_port}${RESET}"
    echo -ne "${YELLOW}数据库运行模式 : ${RESET}"
    if [[ "$db_mode" == "1" ]]; then echo -e "${GREEN}全新内置容器 (PostgreSQL 17)${RESET}"
    elif [[ "$db_mode" == "2" ]]; then echo -e "${GREEN}外部/远程 PostgreSQL 数据库${RESET}"
    else echo -e "${GREEN}超轻量级本地 SQLite 数据库${RESET}"; fi
    echo -e "${YELLOW}部署工作目录   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    if [[ -n "$token" ]]; then
        echo -e "${CYAN}🔑 成功捕获系统凭证：${RESET}"
        echo -e "${GREEN}${token}${RESET}"
    else
        echo -e "${RED}⚠️  捕获超时：未能在 30 秒内自日志中检索到 Super Token。${RESET}"
        echo -e "${YELLOW}提示: 请稍后在主菜单使用选项 7 (查看运行日志) 手动确认。${RESET}"
    fi
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_nodeget() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取 Nodeget 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}服务更新完成！${RESET}"
}

# 卸载 Nodeget
uninstall_nodeget() {
    echo -ne "${RED}确定要卸载并删除 Nodeget 服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}是否同时删除所有持久化本地数据及数据库文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                cd "$BASE_DIR" && docker compose down -v
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}所有数据文件及工作目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f nodeget-app nodeget-db 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

# 基础生命周期控制
start_ng() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}Nodeget 服务已启动${RESET}"; }
stop_ng() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}Nodeget 服务已停止${RESET}"; }
restart_ng() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}Nodeget 服务已重启${RESET}"; }
logs_ng() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

# 显示配置面板与检索当前 Token
show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态   : $status"
    if [ -f "$COMPOSE_FILE" ]; then
        local db_url=$(grep -E "NODEGET_DATABASE_URL:" "$COMPOSE_FILE" | awk -F ' ' '{print $2}' || echo "未找到")
        echo -e "${YELLOW}宿主机映射端口 : ${web_port}${RESET}"
        echo -e "${YELLOW}连接数据库地址 : ${db_url}${RESET}"
        echo -e "${GREEN}----------------------------------------------------${RESET}"
        echo -e "${YELLOW}实时检索系统凭证 :${RESET}"
        local current_token=$(docker logs nodeget-app 2>&1 | grep -E 'Super Token' | tail -n 1)
        if [[ -n "$current_token" ]]; then
            echo -e "${GREEN}${current_token}${RESET}"
        else
            echo -e "${RED}未在当前容器运行日志中匹配到 Super Token 记录。${RESET}"
        fi
    fi
    echo -e "${YELLOW}工作路径       : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 主菜单
menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}       ◈  Nodeget 管理面板  ◈        ${RESET}"
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
        1) install_nodeget ;;
        2) update_nodeget ;;
        3) uninstall_nodeget ;;
        4) start_ng ;;
        5) stop_ng ;;
        6) restart_ng ;;
        7) logs_ng ;;
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
