#!/bin/bash
# =================================================================
# PPanel 聚合面板管理
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

APP_NAME="ppanel"
BASE_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
CONFIG_DIR="$BASE_DIR/config"
CONFIG_FILE="$CONFIG_DIR/ppanel.yaml"

# 检测依赖环境
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}错误: 未检测到 Docker Compose v2，请先安装！${RESET}"
        exit 1
    fi
}

# 端口占用检测
check_port(){
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}错误: 端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

# 动态获取容器整体状态和端口
get_status_info() {
    if [ -f "$COMPOSE_FILE" ]; then
        if [ "$(docker ps -q -f name=ppanel-service)" ]; then
            status="${GREEN}运行中${RESET}"
            web_port=$(docker ps -f name=ppanel-service --format "{{.Ports}}" | sed -E 's/.*:([0-9]+)->.*/\1/' | head -n 1)
            if ! [[ "$web_port" =~ ^[0-9]+$ ]]; then
                web_port=$(sed -n '/ppanel-service:/,/^[[:space:]]*[a-zA-Z]/p' "$COMPOSE_FILE" | grep -E '\-[[:space:]]*["'\'']?[0-9]+:' | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"''-')
            fi
        elif [ "$(docker ps -aq -f name=ppanel-service)" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' ppanel-service 2>/dev/null)
        else
            status="${RED}未部署${RESET}"
        fi
        [[ -z "$web_port" ]] && web_port="8080"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
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

# 1. 部署启动 (自适应本地集群/远程轻量化)
install_ppanel() {
    check_dependencies

    mkdir -p "$CONFIG_DIR"
    mkdir -p "$BASE_DIR/web"

    echo -e "${CYAN}====== 1. 基础映射配置 ======${RESET}"
    read -p "请输入宿主机映射访问端口 [默认: 8080]: " input_port
    PORT=${input_port:-8080}
    check_port "$PORT" || return

    echo -e "\n${CYAN}====== 2. 数据库与缓存运行模式 ======${RESET}"
    echo -e " 1) 经典内置全家桶 (自动拉起本地安全隔离的 MySQL8 + Redis7 容器)"
    echo -e " 2) 轻量化连接远程 (仅拉起 PPanel 容器，连接你自备的远程外部数据库)"
    read -p "请选择运行模式 [默认: 1]: " run_mode
    run_mode=${run_mode:-1}

    # 默认变量初始化
    local db_host="mysql"
    local db_port="3306"
    local db_user="ppanel"
    local db_pass="ppanel123"
    local db_name="ppanel"
    local redis_host="redis"
    local redis_port="6379"
    local redis_pass="redis123"
    local redis_db="0"

    if [[ "$run_mode" == "2" ]]; then
        echo -e "\n${YELLOW}>>> 请输入外部远程 MySQL 连接信息（确保已提前创建空数据库）：${RESET}"
        read -p "MySQL 主机地址 (IP/域名): " db_host
        read -p "MySQL 端口号 [默认: 3306]: " tmp_port
        db_port=${tmp_port:-3306}
        read -p "MySQL 用户名 [默认: ppanel]: " tmp_user
        db_user=${tmp_user:-ppanel}
        read -p "MySQL 密码 [默认: ppanel123]: " tmp_pass
        db_pass=${tmp_pass:-ppanel123}
        read -p "MySQL 数据库名 [默认: ppanel]: " tmp_name
        db_name=${tmp_name:-ppanel}

        # 针对本地 localhost 的网桥重定向
        if [[ "$db_host" == "127.0.0.1" || "$db_host" == "localhost" ]]; then
            db_host="172.17.0.1"
        fi

        echo -e "\n${YELLOW}>>> 请输入外部远程 Redis 连接信息：${RESET}"
        read -p "Redis 主机地址 (IP/域名): " redis_host
        read -p "Redis 端口号 [默认: 6379]: " tmp_rport
        redis_port=${tmp_rport:-6379}
        read -p "Redis 密码 (无密码请直接回车): " redis_pass
        read -p "Redis 分区编号 (DB Index) [0-15] [默认: 0]: " tmp_rdb
        redis_db=${tmp_rdb:-0}

        if [[ "$redis_host" == "127.0.0.1" || "$redis_host" == "localhost" ]]; then
            redis_host="172.17.0.1"
        fi
    fi

    # 生成安全密钥
    SECRET=$(openssl rand -hex 16)

    # ==========================================
    # 生成业务配置文件 ppanel.yaml
    # ==========================================
    cat << EOF > "$CONFIG_FILE"
Host: 0.0.0.0
Port: 8080

TLS:
  Enable: false
  CertFile: ""
  KeyFile: ""

Debug: false

Static:
  Admin:
    Enabled: true
    Prefix: /admin
    Path: ./static/admin
  User:
    Enabled: true
    Prefix: /
    Path: ./static/user

JwtAuth:
  AccessSecret: ${SECRET}
  AccessExpire: 604800

Logger:
  ServiceName: ApiService
  Mode: console
  Encoding: plain
  TimeFormat: "2006-01-02 15:04:05.000"
  Path: logs
  Level: info

MySQL:
  Addr: ${db_host}:${db_port}
  Username: ${db_user}
  Password: ${db_pass}
  Dbname: ${db_name}
  Config: charset=utf8mb4&parseTime=true&loc=Asia%2FShanghai
  MaxIdleConns: 10
  MaxOpenConns: 10

Redis:
  Host: ${redis_host}:${redis_port}
  Pass: ${redis_pass}
  DB: ${redis_db}
EOF

    # ==========================================
    # 动态构建 Docker Compose 编排拓扑
    # ==========================================
    if [[ "$run_mode" == "1" ]]; then
        # 模式一：完整内置拓扑
        cat << EOF > "$COMPOSE_FILE"
services:
  ppanel-service:
    image: ppanel/ppanel:latest
    container_name: ppanel-service
    restart: always
    ports:
      - "${PORT}:8080"
    volumes:
      - ./config:/app/etc:ro
      - ./web:/app/static
    networks:
      - ppanel-net
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_started
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  mysql:
    image: mysql:8
    container_name: ppanel-mysql
    restart: always
    environment:
      MYSQL_DATABASE: ppanel
      MYSQL_USER: ${db_user}
      MYSQL_PASSWORD: ${db_pass}
      MYSQL_ROOT_PASSWORD: ${db_pass}
    volumes:
      - ./mysql:/var/lib/mysql
    networks:
      - ppanel-net
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-p${db_pass}"]
      interval: 10s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7
    container_name: ppanel-redis
    restart: always
    command: redis-server --requirepass ${redis_pass}
    volumes:
      - ./redis:/data
    networks:
      - ppanel-net

networks:
  ppanel-net:
    driver: bridge
EOF
    else
        # 模式二：纯远程 PPanel 瘦容器拓扑
        cat << EOF > "$COMPOSE_FILE"
services:
  ppanel-service:
    image: ppanel/ppanel:latest
    container_name: ppanel-service
    restart: always
    ports:
      - "${PORT}:8080"
    volumes:
      - ./config:/app/etc:ro
      - ./web:/app/static
    networks:
      - ppanel-net
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

networks:
  ppanel-net:
    driver: bridge
EOF
    fi

    echo -e "\n${YELLOW}正在执行容器构建拉起，请稍候...${RESET}"
    cd "$BASE_DIR"
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 容器拉起失败！请检查系统配置。${RESET}"
        return
    fi

    SERVER_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}         PPanel 系统架构部署成功！                   ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}前台访问地址   : http://${SERVER_IP}:${PORT}${RESET}"
    echo -e "${YELLOW}后台管理地址   : http://${SERVER_IP}:${PORT}/admin/${RESET}"
    echo -e "${YELLOW}默认账号       : admin@ppanel.dev${RESET}"
    echo -e "${YELLOW}默认密码       : password${RESET}"
    echo -e "----------------------------------------------------"
    echo -e "${CYAN}[运行配置连接审计]${RESET}"
    if [[ "$run_mode" == "1" ]]; then
        echo -e "${YELLOW}部署模式       : 全能本地集群版${RESET}"
    else
        echo -e "${YELLOW}部署模式       : 远程分离轻量版${RESET}"
    fi
    echo -e "${YELLOW}MySQL 地址     : ${db_host}:${db_port} (${db_name})${RESET}"
    echo -e "${YELLOW}Redis 地址     : ${redis_host}:${redis_port} [分区: DB ${redis_db}]${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 2. 更新容器
update_ppanel() {
    check_dependencies
    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}正在拉取最新 PPanel 核心镜像...${RESET}"
        cd "$BASE_DIR"
        docker compose pull
        docker compose up -d
        echo -e "${GREEN}✅ PPanel 镜像版本更新完成！${RESET}"
    else
        echo -e "${RED}错误: 未检测到编排环境，请先选择 1 进行部署。${RESET}"
    fi
}

# 3. 卸载容器
uninstall_ppanel() {
    echo -ne "${YELLOW}确定要卸载并删除 PPanel 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            echo -e "${YELLOW}正在停止并安全移除相关容器及网络...${RESET}"
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            
            # 二次提示：是否保留宝贵的数据和配置文件
            echo -ne "${RED}是否同时删除本地所有配置文件、持久化数据库和缓存数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                cd /opt && rm -rf "$BASE_DIR"
                echo -e "${GREEN}数据目录已彻底清理。${RESET}"
            else
                echo -e "${GREEN}提示：已为您保留 $BASE_DIR 目录下的数据包。${RESET}"
            fi
        else
            # 如果 compose 文件没了，直接尝试强制清理可能残留的三个核心容器
            echo -e "${YELLOW}未检测到编排配置文件，正在尝试强制清理容器残余...${RESET}"
            docker rm -f ppanel-service ppanel-mysql ppanel-redis 2>/dev/null
        fi
        echo -e "${GREEN}卸载流程执行完毕！${RESET}"
    fi
}

# 4. 启动容器 / 5. 停止容器 / 6. 重启容器
start_ppanel() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}✅ 服务已整体拉起运行${RESET}"; }
stop_ppanel() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}🛑 服务已整体停止运行${RESET}"; }
restart_ppanel() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}✅ 服务已整体成功重启${RESET}"; }

# 7. 查看日志
logs_ppanel() { docker logs -f ppanel-service; }

# 8. 查看配置
show_info() {
    get_status_info
    local detect_ip=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态   : $status"
    echo -e "${YELLOW}环境落脚路径   : ${BASE_DIR}${RESET}"
    echo -e "${YELLOW}前台访问地址   : http://${detect_ip}:${web_port}${RESET}"
    echo -e "${YELLOW}后台管理地址   : http://${detect_ip}:${web_port}/admin/${RESET}"
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}业务配置文件   : ${CONFIG_FILE}${RESET}"
    fi
    echo -e "${GREEN}====================================================${RESET}"
}

# 主菜单管理
menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}        ◈ PPanel 管理面板 ◈          ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN} 当前状态 :${RESET} $status"
    echo -e "${GREEN} 映射端口 :${RESET} ${YELLOW}${web_port}${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN} 1. 部署启动${RESET}"
    echo -e "${GREEN} 2. 更新容器${RESET}"
    echo -e "${GREEN} 3. 卸载容器${RESET}"
    echo -e "${GREEN} 4. 启动容器${RESET}"
    echo -e "${GREEN} 5. 停止容器${RESET}"
    echo -e "${GREEN} 6. 重启容器${RESET}"
    echo -e "${GREEN} 7. 查看日志${RESET}"
    echo -e "${GREEN} 8. 查看配置${RESET}"
    echo -e "${GREEN} 9.${RESET} ${YELLOW}节点管理${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_ppanel ;;
        2) update_ppanel ;;
        3) uninstall_ppanel ;;
        4) start_ppanel ;;
        5) stop_ppanel ;;
        6) restart_ppanel ;;
        7) logs_ppanel ;;
        8) show_info ;;
        9) 
            # 1. 下载到本地临时文件
            wget -qO /tmp/ppanel_node_install.sh https://raw.githubusercontent.com/perfect-panel/ppanel-node/master/scripts/install.sh
            
            # 2. 检查是否下载成功
            if [ $? -eq 0 ]; then
                chmod +x /tmp/ppanel_node_install.sh
                # 3. 正常执行本地脚本
                /tmp/ppanel_node_install.sh
                # 4. 执行完后清理现场
                rm -f /tmp/ppanel_node_install.sh
            else
                echo -e "${RED}下载失败，请检查网络！${RESET}"
            fi
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "\n${YELLOW}按回车键继续...${RESET}"
    read -r
done
