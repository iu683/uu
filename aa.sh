#!/bin/bash
# =================================================================
# Mediary Scout (Media-Track) 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

APP_NAME="mediary-scout-web"
BASE_DIR="/opt/mediatrack"
SRC_DIR="$BASE_DIR" 
REPO_URL="https://github.com/fancydirty/mediary-scout.git"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! command -v git &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Git，请先安装 Git！${RESET}"
        exit 1
    fi
}

# 动态获取服务端口与运行状态
get_status_info() {
    local container_id=$(docker ps -q -f "name=web" -f "status=running" 2>/dev/null)
    [[ -z "$container_id" ]] && container_id=$(docker ps -q -f "ancestor=mediary-scout-web" -f "status=running" 2>/dev/null)

    if [[ -n "$container_id" ]]; then
        status="${GREEN}运行中${RESET}"
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "$container_id" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3000"
    else
        if [ -d "$SRC_DIR/.git" ]; then
            status="${RED}已停止${RESET}"
        else
            status="${RED}未部署${RESET}"
        fi
        webui_port="N/A"
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
# 部署核心逻辑
install_translate() {
    check_dependencies

    echo -e "${CYAN}====== 1. 端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Media-Track 映射端口 (WEB_PORT) [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"

    echo -e "\n${CYAN}====== 2. PostgreSQL 数据库配置 ======${RESET}"
    echo -e "${YELLOW}请选择你要使用的 PostgreSQL 数据库类型:${RESET}"
    echo -e "  ${CYAN}1.${RESET} 使用集群自带内置数据库容器 (自动创建)"
    echo -e "  ${CYAN}2.${RESET} 使用外部独立/远程 PostgreSQL 数据库"
    echo -ne "${YELLOW}请选择 (1-2) [默认: 1]: ${RESET}"
    read -r db_choice

    local db_url="postgres://mediatrack:mediatrack@postgres:5432/mediatrack"
    local use_builtin_db="true"

    if [[ "$db_choice" == "2" ]]; then
        use_builtin_db="false"
        
        echo -e "\n${CYAN}--- 远程 PostgreSQL 数据库连接配置 ---${RESET}"
        echo -ne "${YELLOW}请输入远程数据库 主机IP/域名: ${RESET}"
        read -r remote_host
        while [[ -z "$remote_host" ]]; do
            echo -ne "${RED}错误: 主机IP/域名不能为空，请重新输入: ${RESET}"
            read -r remote_host
        done

        echo -ne "${YELLOW}请输入远程数据库 端口 [默认: 5432]: ${RESET}"
        read -r remote_port
        [[ -z "$remote_port" ]] && remote_port="5432"

        echo -ne "${YELLOW}请输入远程数据库 用户名: ${RESET}"
        read -r remote_user
        while [[ -z "$remote_user" ]]; do
            echo -ne "${RED}错误: 用户名不能为空，请重新输入: ${RESET}"
            read -r remote_user
        done

        echo -ne "${YELLOW}请输入远程数据库 密码: ${RESET}"
        read -r remote_pass
        while [[ -z "$remote_pass" ]]; do
            echo -ne "${RED}错误: 密码不能为空，请重新输入: ${RESET}"
            read -r remote_pass
        done

        echo -ne "${YELLOW}请输入远程数据库 数据库名: ${RESET}"
        read -r remote_dbname
        while [[ -z "$remote_dbname" ]]; do
            echo -ne "${RED}错误: 数据库名不能为空，请重新输入: ${RESET}"
            read -r remote_dbname
        done

        # 底层完美封装为通用标准的 Postgres 连接 URL
        db_url="postgres://${remote_user}:${remote_pass}@${remote_host}:${remote_port}/${remote_dbname}"
        echo -e "${GREEN}提示: 外部数据库参数组装成功！${RESET}"
    else
        echo -e "${GREEN}提示: 已选择内置容器数据库模式。${RESET}"
    fi

    # 克隆官方仓库到当前工作目录
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "\n${YELLOW}正在克隆官方 GitHub 仓库...${RESET}"
        mkdir -p "$SRC_DIR"
        git clone "$REPO_URL" "$SRC_DIR/tmp_repo"
        if [ $? -eq 0 ]; then
            mv "$SRC_DIR/tmp_repo/"* "$SRC_DIR/" 2>/dev/null
            mv "$SRC_DIR/tmp_repo/."* "$SRC_DIR/" 2>/dev/null
            rm -rf "$SRC_DIR/tmp_repo"
        else
            echo -e "${RED}错误: 仓库克隆失败，请检查网络！${RESET}"
            exit 1
        fi
    else
        echo -e "\n${GREEN}检测到本地已存在官方仓库，正在同步最新代码...${RESET}"
        cd "$SRC_DIR" && git pull
    fi

    # 回到仓库根目录
    cd "$SRC_DIR"

    # 动态组装完美对齐原厂环境的 .env 文件
    cat <<EOF > "$SRC_DIR/.env"
# Required runtime configuration
WEB_PORT=${custom_port}
MEDIA_TRACK_POSTGRES_URL=${db_url}
TMDB_READ_TOKEN=
MEDIA_TRACK_SEARCH_PROVIDER=tmdb
MEDIA_TRACK_DEMO_SEED=0
MEDIA_TRACK_DEFAULT_QUALITY=4K
MEDIA_TRACK_DEFAULT_TV_STORAGE_DIRECTORY_ID=
MEDIA_TRACK_TV_PARENT_CID=
MEDIA_TRACK_WORKFLOW_ADAPTER=pansou
MEDIA_TRACK_AGENT_ADAPTER=vercel-ai
MEDIA_TRACK_STORAGE_ADAPTER=115
PANSOU_BASE_URL=http://pansou
PAN115_COOKIE=""
MEDIA_TRACK_115_TEST_ROOT_CID=
MEDIA_TRACK_115_WRITE_SCOPE_CIDS=
MEDIA_TRACK_115_PROTECTED_CIDS=
TUNNEL_TOKEN=
TUNNEL_TRANSPORT_PROTOCOL=
XIAOMI_MIMO_API_KEY=
XIAOMI_MIMO_BASE_URL=https://token-plan-sgp.xiaomimimo.com/v1
XIAOMI_MIMO_MODEL_ID=mimo-v2.5-pro
CLAWD_MEDIA_ROOT_CID=
MOVIES_CID=
TV_SHOWS_CID=
ANIME_CID=
EOF

    # 动态裁剪和组装原生的 docker-compose.yml 
    if [[ "$use_builtin_db" == "true" ]]; then
        cat <<EOF > "$SRC_DIR/docker-compose.yml"
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: mediatrack
      POSTGRES_USER: mediatrack
      POSTGRES_PASSWORD: mediatrack
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mediatrack -d mediatrack"]
      interval: 5s
      timeout: 3s
      retries: 12
    restart: unless-stopped

  pansou:
    image: ghcr.io/fish2018/pansou-web:latest
    restart: unless-stopped

  web:
    build: .
    depends_on:
      postgres:
        condition: service_healthy
      pansou:
        condition: service_started
    environment:
      MEDIA_TRACK_POSTGRES_URL: ${db_url}
      PANSOU_BASE_URL: http://pansou
      MEDIA_TRACK_SEARCH_PROVIDER: tmdb
      MEDIA_TRACK_WORKFLOW_ADAPTER: pansou
      MEDIA_TRACK_STORAGE_ADAPTER: "115"
      MEDIA_TRACK_AGENT_ADAPTER: vercel-ai
      MEDIA_TRACK_DEMO_SEED: "0"
    env_file:
      - path: .env
        required: false
    ports:
      - "\${WEB_PORT:-3000}:3000"
    restart: unless-stopped

volumes:
  pgdata:
EOF
    else
        cat <<EOF > "$SRC_DIR/docker-compose.yml"
services:
  pansou:
    image: ghcr.io/fish2018/pansou-web:latest
    restart: unless-stopped

  web:
    build: .
    depends_on:
      pansou:
        condition: service_started
    environment:
      MEDIA_TRACK_POSTGRES_URL: ${db_url}
      PANSOU_BASE_URL: http://pansou
      MEDIA_TRACK_SEARCH_PROVIDER: tmdb
      MEDIA_TRACK_WORKFLOW_ADAPTER: pansou
      MEDIA_TRACK_STORAGE_ADAPTER: "115"
      MEDIA_TRACK_AGENT_ADAPTER: vercel-ai
      MEDIA_TRACK_DEMO_SEED: "0"
    env_file:
      - path: .env
        required: false
    ports:
      - "\${WEB_PORT:-3000}:3000"
    restart: unless-stopped
EOF
    fi

    echo -e "\n${YELLOW}正在执行独立编译启动命令 (WEB_PORT=${custom_port} docker compose up -d --build)...${RESET}"
    WEB_PORT=$custom_port docker compose up -d --build

    echo -e "${YELLOW}正在等待容器集群 Build 编译并拉起服务...${RESET}"
    sleep 5

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}       Media-Track 官方原生集群编译并启动成功！        ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}默认访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}当前存储后端 : 外部 PostgreSQL 托管中${RESET}"
    echo -e "${YELLOW}仓库所在路径 : ${SRC_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 原生更新
update_translate() {
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "${RED}错误: 未检测到克隆的仓库，请先执行选项 1！${RESET}"
        return
    fi
    get_status_info
    local current_port=$webui_port
    [[ "$current_port" == "N/A" ]] && current_port="3000"

    echo -e "${YELLOW}正在同步最新的远程官方代码...${RESET}"
    cd "$SRC_DIR" && git pull
    
    echo -e "${YELLOW}正在使用原厂命令重编镜像并热更新...${RESET}"
    WEB_PORT=$current_port docker compose up -d --build --remove-orphans
    echo -e "${GREEN}官方集群更新并重编完成！${RESET}"
}

# 彻底卸载
uninstall_translate() {
    echo -ne "${RED}确定要停止并卸载 Media-Track 官方容器集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -d "$SRC_DIR/.git" ]; then
            cd "$SRC_DIR" && docker compose down
            echo -e "${GREEN}官方业务容器已被安全停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同步连根拔除本地克隆的【全部源码及本地缓存卷】？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有源码与持久化数据已被彻底清除！${RESET}"
            fi
        else
            echo -e "${YELLOW}未检测到运行中的 compose 环境，跳过物理删除。${RESET}"
        fi
    fi
}

start_translate() { cd "$SRC_DIR" && docker compose start && echo -e "${GREEN}原生集群已全面启动${RESET}"; }
stop_translate() { cd "$SRC_DIR" && docker compose stop && echo -e "${YELLOW}原生集群已安全停止${RESET}"; }
restart_translate() { cd "$SRC_DIR" && docker compose restart && echo -e "${GREEN}原生集群已平滑重启${RESET}"; }
logs_translate() { cd "$SRC_DIR" && docker compose logs -f web --tail=100; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}集群运行状态     : $status"
    echo -e "${YELLOW}前端访问地址     : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}源码绝对路径     : ${SRC_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}    ◈  Media-Track 管理面板  ◈   ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}集群状态 :${RESET} $status"
    echo -e "${GREEN}服务端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}===================================${RESET}"
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
