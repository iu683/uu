#!/bin/bash
# =================================================================
# ACG-FAKA 发卡系统 (支持外部 MySQL & 外部多分区 Redis) 自动化管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

APP_NAME="acg-faka-app"
BASE_DIR="/opt/acg-faka"
SRC_DIR="$BASE_DIR" 
REPO_URL="https://github.com/lizhipay/acg-faka.git"

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
    local container_id=$(docker ps -q -f "ancestor=acg-faka-app" -f "status=running" 2>/dev/null)
    [[ -z "$container_id" ]] && container_id=$(docker ps -q -f "name=app" -f "status=running" 2>/dev/null)

    if [[ -n "$container_id" ]]; then
        status="${GREEN}运行中${RESET}"
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$container_id" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8080"
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


# 动态分析当前组件环境状态
get_env_summary() {
    if [ -f "$SRC_DIR/docker-compose.yml" ]; then
        local has_mysql=$(grep "container_name: acg-faka-mysql" "$SRC_DIR/docker-compose.yml")
        local has_redis=$(grep "container_name: acg-faka-redis" "$SRC_DIR/docker-compose.yml")
        
        if [[ -n "$has_mysql" ]]; then mysql_info="${GREEN}内置容器${RESET}"; else mysql_info="${YELLOW}外部托管${RESET}"; fi
        if [[ -n "$has_redis" ]]; then redis_info="${GREEN}内置容器${RESET}"; else redis_info="${YELLOW}外部托管${RESET}"; fi
    else
        mysql_info="${RED}未部署${RESET}"
        redis_info="${RED}未部署${RESET}"
    fi
    echo -e "MySQL: $mysql_info | Redis: $redis_info"
}

# 部署核心逻辑
install_translate() {
    check_dependencies

    echo -e "${CYAN}====== 1. 端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 ACG-FAKA 映射端口 (对应 ACG_HTTP_PORT) [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"

    # MySQL 路由配置
    echo -e "\n${CYAN}====== 2. MySQL 数据库配置 ======${RESET}"
    echo -e "${YELLOW}请选择 MySQL 数据库类型:${RESET}"
    echo -e "  ${CYAN}1. 使用集群自带内置 MySQL 容器 (自动创建)${RESET}"
    echo -e "  ${CYAN}2. 使用外部独立/远程 MySQL 数据库${RESET}"
    echo -ne "${YELLOW}请选择 (1-2) [默认: 1]: ${RESET}"
    read -r db_choice

    local use_builtin_mysql="true"
    local tip_db_host="mysql"
    local tip_db_name="acg_faka"
    local tip_db_user="acg"
    local tip_db_pass="acg_password"

    if [[ "$db_choice" == "2" ]]; then
        use_builtin_mysql="false"
        echo -e "\n${CYAN}--- 远程 MySQL 数据库连接配置 ---${RESET}"
        echo -ne "${YELLOW}请输入远程 MySQL 主机IP/域名: ${RESET}"
        read -r remote_db_host
        while [[ -z "$remote_db_host" ]]; do echo -ne "${RED}不能为空，请重新输入: ${RESET}"; read -r remote_db_host; done
        
        echo -ne "${YELLOW}请输入远程 MySQL 端口 [默认: 3306]: ${RESET}"
        read -r remote_db_port
        [[ -z "$remote_db_port" ]] && remote_db_port="3306"

        echo -ne "${YELLOW}请输入远程 MySQL 用户名: ${RESET}"
        read -r remote_db_user
        while [[ -z "$remote_db_user" ]]; do echo -ne "${RED}不能为空，请重新输入: ${RESET}"; read -r remote_db_user; done

        echo -ne "${YELLOW}请输入远程 MySQL 密码: ${RESET}"
        read -r remote_db_pass
        while [[ -z "$remote_db_pass" ]]; do echo -ne "${RED}不能为空，请重新输入: ${RESET}"; read -r remote_db_pass; done

        echo -ne "${YELLOW}请输入远程 MySQL 数据库名: ${RESET}"
        read -r remote_db_name
        while [[ -z "$remote_db_name" ]]; do echo -ne "${RED}不能为空，请重新输入: ${RESET}"; read -r remote_db_name; done

        tip_db_host="${remote_db_host}:${remote_db_port}"
        tip_db_name="$remote_db_name"
        tip_db_user="$remote_db_user"
        tip_db_pass="$remote_db_pass"
    fi

    # Redis 路由配置
    echo -e "\n${CYAN}====== 3. Redis 缓存配置 ======${RESET}"
    echo -e "${YELLOW}请选择 Redis 缓存类型:${RESET}"
    echo -e "  ${CYAN}1. 使用集群自带内置 Redis 容器 (自动创建)${RESET}"
    echo -e "  ${CYAN}2. 使用外部独立/远程 Redis 缓存${RESET}"
    echo -ne "${YELLOW}请选择 (1-2) [默认: 1]: ${RESET}"
    read -r redis_choice

    local use_builtin_redis="true"
    local tip_redis_host="redis"
    local tip_redis_port="6379"
    local tip_redis_pass=""
    local tip_redis_db="0"

    if [[ "$redis_choice" == "2" ]]; then
        use_builtin_redis="false"
        echo -e "\n${CYAN}--- 远程 Redis 缓存连接配置 ---${RESET}"
        echo -ne "${YELLOW}请输入远程 Redis 主机IP/域名: ${RESET}"
        read -r remote_redis_host
        while [[ -z "$remote_redis_host" ]]; do echo -ne "${RED}不能为空，请重新输入: ${RESET}"; read -r remote_redis_host; done

        echo -ne "${YELLOW}请输入远程 Redis 端口 [默认: 6379]: ${RESET}"
        read -r remote_redis_port
        [[ -z "$remote_redis_port" ]] && remote_redis_port="6379"

        echo -ne "${YELLOW}请输入远程 Redis 密码 (如果没有请留空直接回车): ${RESET}"
        read -r remote_redis_pass

        echo -ne "${YELLOW}请输入 Redis 分区编号/DB ID (0-15) [默认: 0]: ${RESET}"
        read -r remote_redis_db
        [[ -z "$remote_redis_db" ]] && remote_redis_db="0"

        tip_redis_host="$remote_redis_host"
        tip_redis_port="$remote_redis_port"
        tip_redis_pass="$remote_redis_pass"
        tip_redis_db="$remote_redis_db"
    else
        # 即使选内置，也让用户选择指定分区，体验拉满
        echo -ne "${YELLOW}请输入内置 Redis 分区编号/DB ID (0-15) [默认: 0]: ${RESET}"
        read -r builtin_redis_db
        [[ -z "$builtin_redis_db" ]] && builtin_redis_db="0"
        tip_redis_db="$builtin_redis_db"
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

    cd "$SRC_DIR"

    echo -e "${YELLOW}正在预热修复官方提及的持久化目录写权限...${RESET}"
    mkdir -p assets/cache app/Plugin app/Pay app/View/User/Theme kernel/Install runtime
    chmod -R 777 assets/cache app/Plugin app/Pay app/View/User/Theme kernel/Install runtime

    # ======== 动态组装 docker-compose.yml ========
    cat <<EOF > "$SRC_DIR/docker-compose.yml"
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: acg-faka-app
    restart: unless-stopped
    ports:
      - "\${ACG_HTTP_PORT:-8080}:80"
    volumes:
      - acg_config:/var/www/html/config
      - acg_install:/var/www/html/kernel/Install
      - acg_runtime:/var/www/html/runtime
      - acg_assets_cache:/var/www/html/assets/cache
      - acg_plugins:/var/www/html/app/Plugin
      - acg_pay:/var/www/html/app/Pay
      - acg_themes:/var/www/html/app/View/User/Theme
EOF

    if [[ "$use_builtin_mysql" == "true" || "$use_builtin_redis" == "true" ]]; then
        cat <<EOF >> "$SRC_DIR/docker-compose.yml"
    depends_on:
EOF
        if [[ "$use_builtin_mysql" == "true" ]]; then
            cat <<EOF >> "$SRC_DIR/docker-compose.yml"
      mysql:
        condition: service_healthy
EOF
        fi
        if [[ "$use_builtin_redis" == "true" ]]; then
            cat <<EOF >> "$SRC_DIR/docker-compose.yml"
      redis:
        condition: service_started
EOF
        fi
    fi

    if [[ "$use_builtin_mysql" == "true" ]]; then
        cat <<EOF >> "$SRC_DIR/docker-compose.yml"

  mysql:
    image: mysql:8.0
    container_name: acg-faka-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD:-root_password}
      MYSQL_DATABASE: \${MYSQL_DATABASE:-acg_faka}
      MYSQL_USER: \${MYSQL_USER:-acg}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD:-acg_password}
      TZ: Asia/Shanghai
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --default-authentication-plugin=mysql_native_password
    volumes:
      - acg_mysql:/var/lib/mysql
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "mysqladmin ping -h 127.0.0.1 -uroot -p\$\${MYSQL_ROOT_PASSWORD} --silent",
        ]
      interval: 5s
      timeout: 3s
      retries: 30
EOF
    fi

    if [[ "$use_builtin_redis" == "true" ]]; then
        cat <<EOF >> "$SRC_DIR/docker-compose.yml"

  redis:
    image: redis:7-alpine
    container_name: acg-faka-redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - acg_redis:/data
EOF
    fi

    cat <<EOF >> "$SRC_DIR/docker-compose.yml"

volumes:
  acg_config:
  acg_install:
  acg_runtime:
  acg_assets_cache:
  acg_plugins:
  acg_pay:
  acg_themes:
EOF

    if [[ "$use_builtin_mysql" == "true" ]]; then
        echo "  acg_mysql:" >> "$SRC_DIR/docker-compose.yml"
    fi
    if [[ "$use_builtin_redis" == "true" ]]; then
        echo "  acg_redis:" >> "$SRC_DIR/docker-compose.yml"
    fi

    echo -e "\n${YELLOW}正在执行官方原生编译启动命令 (ACG_HTTP_PORT=$custom_port)...${RESET}"
    ACG_HTTP_PORT=$custom_port docker compose up -d --build

    echo -e "${YELLOW}正在等待容器集群 Build 编译并拉起服务...${RESET}"
    sleep 5

    chmod -R 777 assets/cache app/Plugin app/Pay app/View/User/Theme kernel/Install runtime 2>/dev/null

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}       ACG-FAKA 官方原生集群编译并启动成功！        ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}默认访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}后台管理地址 : http://${DETECT_IP}:${custom_port}/admin${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${CYAN}📝 首次安装向导页面填写指南（非常重要）：${RESET}"
    echo -e "   - 数据库地址 : ${GREEN}${tip_db_host}${RESET}"
    echo -e "   - 数据库名称 : ${GREEN}${tip_db_name}${RESET}"
    echo -e "   - 数据库账号 : ${GREEN}${tip_db_user}${RESET}"
    echo -e "   - 数据库密码 : ${GREEN}${tip_db_pass}${RESET}"
    echo -e "   - 数据库前缀 : ${GREEN}acg_${RESET}"
    echo -e "   - 缓存驱动   : ${GREEN}Redis${RESET}"
    echo -e "   - Redis地址  : ${GREEN}${tip_redis_host}${RESET}"
    echo -e "   - Redis端口  : ${GREEN}${tip_redis_port}${RESET}"
    if [[ -n "$tip_redis_pass" ]]; then
    echo -e "   - Redis密码  : ${GREEN}${tip_redis_pass}${RESET}"
    fi
    echo -e "   - Redis数据库: ${GREEN}${tip_redis_db}${RESET} (← 对应发卡系统网页端的数据库/分区编号)"
    echo -e "${GREEN}====================================================${RESET}"
}

# 原生更新：拉取代码 + 重新 Build
update_translate() {
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "${RED}错误: 未检测到克隆的仓库，请先执行选项 1！${RESET}"
        return
    fi
    get_status_info
    local current_port=$webui_port
    [[ "$current_port" == "N/A" ]] && current_port="8080"

    echo -e "${YELLOW}正在同步最新的远程官方代码...${RESET}"
    cd "$SRC_DIR" && git pull
    
    echo -e "${YELLOW}正在使用官方命令重编镜像并热更新...${RESET}"
    ACG_HTTP_PORT=$current_port docker compose up -d --build --remove-orphans
    echo -e "${GREEN}官方集群更新并重编完成！${RESET}"
}

# 彻底卸载
uninstall_translate() {
    echo -ne "${RED}确定要停止并卸载 ACG-FAKA 官方容器集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -d "$SRC_DIR/.git" ]; then
            cd "$SRC_DIR" && docker compose down
            echo -e "${GREEN}官方容器与网络已被安全停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同步连根拔除本地克隆的【全部源码、卡密、商品及内部数据库卷】？(y/n): ${RESET}"
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

# 容器管理生命周期
start_translate() { cd "$SRC_DIR" && docker compose start && echo -e "${GREEN}原生集群已全面启动${RESET}"; }
stop_translate() { cd "$SRC_DIR" && docker compose stop && echo -e "${YELLOW}原生集群已安全停止${RESET}"; }
restart_translate() { cd "$SRC_DIR" && docker compose restart && echo -e "${GREEN}原生集群已平滑重启${RESET}"; }
logs_translate() { cd "$SRC_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    local env_summary=$(get_env_summary)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}集群运行状态     : $status"
    echo -e "${YELLOW}当前底层依赖     : $env_summary"
    echo -e "${YELLOW}前端访问地址     : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}后台管理地址     : http://${DETECT_IP}:${webui_port}/admin${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    local env_summary=$(get_env_summary)
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}    ◈  ACG-FAKA 发卡管理面板  ◈   ${RESET}"
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
