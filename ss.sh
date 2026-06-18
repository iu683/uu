#!/bin/bash
# =================================================================
# Halo 2.x Docker Compose 管理面板 (远程多库支持 + 状态端口双模版)
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/halo"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
DEFAULT_IMAGE="registry.fit2cloud.com/halo/halo-pro:2.25"

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

# 动态获取容器整体状态和端口 (实时从运行状态提取)
get_status_info() {
    if [ -f "$COMPOSE_FILE" ]; then
        if [ "$(docker ps -q -f name=halo-app)" ]; then
            status="${GREEN}运行中${RESET}"
            # 实时从正在运行的容器中提取宿主机映射的端口
            web_port=$(docker ps -f name=halo-app --format "{{.Ports}}" | sed -E 's/.*0.0.0.0:([0-9]+)->.*/\1/' | head -n 1)
            # 如果提取失败（例如网络模式特殊），再尝试 fallback 到配置文件
            if ! [[ "$web_port" =~ ^[0-9]+$ ]]; then
                web_port=$(sed -n '/halo:/,/^[[:space:]]*[a-zA-Z]/p' "$COMPOSE_FILE" | grep -E '\-[[:space:]]*["'\'']?[0-9]+:' | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"''-')
            fi
        elif [ "$(docker ps -aq -f name=halo-app)" ]; then
            status="${YELLOW}已停止${RESET}"
            # 容器停止时，通过 inspect 获取原本绑定的宿主机端口
            web_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' halo-app 2>/dev/null)
        else
            status="${RED}未部署${RESET}"
        fi
        
        # 兜底：如果以上方法都没拿到端口，默认显示 8090
        [[ -z "$web_port" ]] && web_port="8090"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署 Halo
install_halo() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 数据库运行模式选择 ======${RESET}"
    echo -e " 1. 直接部署全新环境 (包含全新 PostgreSQL 15 容器)"
    echo -e " 2. 使用已有的外部/远程数据库 (支持外部 MySQL 或 PostgreSQL - 需提前建库)"
    echo -e " 3. 使用轻量级嵌入式 H2 数据库 (无需额外数据库，适合低配服务器)"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Halo 宿主机映射访问端口 [默认: 8090]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8090"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入站点外部访问域名或公网IP (形如 http://12.34.56.78:${custom_port}/): ${RESET}"
    read -r ext_url
    [[ -z "$ext_url" ]] && ext_url="http://localhost:${custom_port}/"
    [[ "${ext_url}" != */ ]] && ext_url="${ext_url}/"

    mkdir -p "$BASE_DIR/halo2"

    # ------------------ 模式 1：全套本地内置容器化 PostgreSQL ------------------
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}正在自动计算生成数据库高强度防破解随机密码...${RESET}"
        local rand_pass=$(openssl rand -hex 12)
        mkdir -p "$BASE_DIR/db"

        cat << EOF > "$COMPOSE_FILE"
services:
  halo:
    image: ${DEFAULT_IMAGE}
    container_name: halo-app
    restart: on-failure:3
    depends_on:
      halodb:
        condition: service_healthy
    networks:
      - halo_network
    volumes:
      - ${BASE_DIR}/halo2:/root/.halo2
    ports:
      - "${custom_port}:8090"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8090/actuator/health/readiness"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
    environment:
      - JVM_OPTS=-Xmx256m -Xms256m
    command:
      - --spring.r2dbc.url=r2dbc:pool:postgresql://halodb/halo
      - --spring.r2dbc.username=halo
      - --spring.r2dbc.password=${rand_pass}
      - --spring.sql.init.platform=postgresql
      - --halo.external-url=${ext_url}

  halodb:
    image: postgres:15.4
    container_name: halo-db
    restart: on-failure:3
    networks:
      - halo_network
    volumes:
      - ${BASE_DIR}/db:/var/lib/postgresql/data
    healthcheck:
      test: [ "CMD", "pg_isready" ]
      interval: 10s
      timeout: 5s
      retries: 5
    environment:
      - POSTGRES_PASSWORD=${rand_pass}
      - POSTGRES_USER=halo
      - POSTGRES_DB=halo
      - PGUSER=halo

networks:
  halo_network:
    driver: bridge
EOF

    # ------------------ 模式 2：连接外部/远程已有的 MySQL / PostgreSQL ------------------
    elif [[ "$db_mode" == "2" ]]; then
        echo -e "${CYAN}====== 远程/外部数据库类型选择 ======${RESET}"
        echo -e " 1) MySQL (5.7 或 8.0+)"
        echo -e " 2) PostgreSQL"
        echo -ne "${YELLOW}请选择远程数据库类型 [默认: 1]: ${RESET}"
        read -r ext_db_type
        [[ -z "$ext_db_type" ]] && ext_db_type="1"

        echo -e "${CYAN}====== 远程/外部数据库信息输入 ======${RESET}"
        echo -ne "${YELLOW}请输入外部数据库的 IP 或域名 [默认: 127.0.0.1]: ${RESET}"
        read -r ext_host
        [[ -z "$ext_host" ]] && ext_host="127.0.0.1"
        
        # 根据数据库类型设定默认端口和驱动名称
        local default_port="3306"
        local r2dbc_proto="mysql"
        local sql_platform="mysql"
        if [[ "$ext_db_type" == "2" ]]; then
            default_port="5432"
            r2dbc_proto="postgresql"
            sql_platform="postgresql"
        fi

        echo -ne "${YELLOW}请输入数据库端口 [默认: ${default_port}]: ${RESET}"
        read -r ext_port
        [[ -z "$ext_port" ]] && ext_port="$default_port"
        
        echo -ne "${YELLOW}请输入数据库用户名 [默认: root/halo]: ${RESET}"
        read -r ext_user
        if [[ -z "$ext_user" ]]; then
            [[ "$ext_db_type" == "1" ]] && ext_user="root" || ext_user="halo"
        fi
        
        echo -ne "${YELLOW}请输入数据库密码: ${RESET}"
        read -r ext_pass
        
        echo -ne "${YELLOW}请输入已存在的远程数据库名 [默认: halo]: ${RESET}"
        read -r ext_dbname
        [[ -z "$ext_dbname" ]] && ext_dbname="halo"

        # 破壁 Docker 宿主机回环地址限制
        if [[ "$ext_host" == "127.0.0.1" || "$ext_host" == "localhost" ]]; then
            ext_host="172.17.0.1"
            echo -e "${YELLOW}提示: 检测到本地回环地址，内部网络配置已自动适配宿主机网关 IP: 172.17.0.1${RESET}"
        fi

        echo -e "${YELLOW}提示: 请确保远程数据库 (${ext_host}:${ext_port}) 中已手动创建好名为 '${ext_dbname}' 的空白库。${RESET}"

        cat << EOF > "$COMPOSE_FILE"
services:
  halo:
    image: ${DEFAULT_IMAGE}
    container_name: halo-app
    restart: on-failure:3
    ports:
      - "${custom_port}:8090"
    volumes:
      - ${BASE_DIR}/halo2:/root/.halo2
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8090/actuator/health/readiness"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
    environment:
      - JVM_OPTS=-Xmx256m -Xms256m
    command:
      - --spring.r2dbc.url=r2dbc:pool:${r2dbc_proto}://${ext_host}:${ext_port}/${ext_dbname}
      - --spring.r2dbc.username=${ext_user}
      - --spring.r2dbc.password=${ext_pass}
      - --spring.sql.init.platform=${sql_platform}
      - --halo.external-url=${ext_url}
EOF

    # ------------------ 模式 3：使用本地轻量级嵌入式 H2 数据库 ------------------
    else
        echo -e "${YELLOW}正在配置嵌入式 H2 数据库环境（无需外部独立关系型数据库）...${RESET}"
        cat << EOF > "$COMPOSE_FILE"
services:
  halo:
    image: ${DEFAULT_IMAGE}
    container_name: halo-app
    restart: on-failure:3
    ports:
      - "${custom_port}:8090"
    volumes:
      - ${BASE_DIR}/halo2:/root/.halo2
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8090/actuator/health/readiness"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
    environment:
      - JVM_OPTS=-Xmx256m -Xms256m
    command:
      - --halo.external-url=${ext_url}
EOF
    fi

    # ------------------ 启动集群 ------------------
    echo -e "${YELLOW}正在通过 Docker Compose 启动 Halo 服务中...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    if [ $? -ne 0 ]; then
        echo -e "${RED}====================================================${RESET}"
        echo -e "${RED} 错误: 容器启动失败，请排查端口占用或日志报错。   ${RESET}"
        echo -e "${RED}====================================================${RESET}"
        return
    fi

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             Halo 部署成功！                        ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}后台初始Url   : http://${DETECT_IP}:${custom_port}/console${RESET}"
    echo -e "${YELLOW}绑定的外部Url : ${ext_url}${RESET}"
    echo -e "${YELLOW}宿主机映射端口: ${custom_port}${RESET}"
    echo -ne "${YELLOW}数据库运行模式: ${RESET}"
    if [[ "$db_mode" == "1" ]]; then 
        echo -e "${GREEN}全新内置容器 (PostgreSQL 15)${RESET}"
        echo -e "${YELLOW}内置库高强密码: ${rand_pass}${RESET}"
    elif [[ "$db_mode" == "2" ]]; then 
        echo -e "${GREEN}外部连接模式 (目标数据库平台: ${sql_platform^^})${RESET}"
        echo -e "${YELLOW}连通目标地址  : ${ext_host}:${ext_port}${RESET}"
        echo -e "${YELLOW}指定目标库名  : ${ext_dbname}${RESET}"
    else 
        echo -e "${GREEN}超轻量级本地嵌入式 H2 数据库${RESET}"
    fi
    echo -e "${YELLOW}部署工作路径  : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_halo() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取 Halo 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}服务更新完成！${RESET}"
}

# 卸载 Halo
uninstall_halo() {
    echo -ne "${RED}确定要卸载并删除 Halo 服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}是否同时删除所有建站源码、主题插件及数据库文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                cd "$BASE_DIR" && docker compose down -v
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}所有持久化数据及工作目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f halo-app halo-db 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

# 基础生命周期控制
start_hl() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}Halo 服务已启动${RESET}"; }
stop_hl() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}Halo 服务已停止${RESET}"; }
restart_hl() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}Halo 服务已重启${RESET}"; }
logs_hl() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

# 显示配置面板
show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态   : $status"
    echo -e "${YELLOW}实际映射端口   : ${web_port}${RESET}"
    echo -e "${YELLOW}工作路径       : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 主菜单
menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}        ◈  Halo 管理面板  ◈          ${RESET}"
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
        1) install_halo ;;
        2) update_halo ;;
        3) uninstall_halo ;;
        4) start_hl ;;
        5) stop_hl ;;
        6) restart_hl ;;
        7) logs_hl ;;
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
