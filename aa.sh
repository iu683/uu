#!/bin/bash
# =================================================================
# Paymenter 自动化管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# 定义核心容器名
CONTAINER_NAME="paymenter-web"
BASE_DIR="/opt/paymenter"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

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

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="80"
    else
        img_version="${RED}未安装${RESET}"
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

# 生成随机密码
generate_password() {
    if command -v openssl &> /dev/null; then
        openssl rand -hex 12
    else
        echo "pay_pass_$(date +%s)"
    fi
}



# 部署 Paymenter 主函数
install_paymenter() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 基础环境配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Paymenter 访问端口 [默认: 80]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="80"

    echo -e "\n${CYAN}====== 2. 数据库类型选择 ======${RESET}"
    echo -e "${GREEN}1) 部署全新的本地 MariaDB 数据库 (数据挂载在本地 ./database)${RESET}"
    echo -e "${GREEN}2) 连接已有的远程/外部 MySQL/MariaDB 数据库${RESET}"
    echo -ne "${YELLOW}请选择数据库部署模式 [默认 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    if [[ "$db_mode" == "1" ]]; then
        db_host="paymenter-db"
        db_port="3306"
        db_connection="mariadb"
        db_name="paymenter"
        db_user="paymenter"
        
        echo -ne "${YELLOW}请输入本地数据库用户密码 (留空则随机生成): ${RESET}"
        read -r db_password
        [[ -z "$db_password" ]] && db_password=$(generate_password)

        echo -ne "${YELLOW}请输入本地数据库 Root 密码 (留空则随机生成): ${RESET}"
        read -r db_root_password
        [[ -z "$db_root_password" ]] && db_root_password=$(generate_password)

    elif [[ "$db_mode" == "2" ]]; then
        echo -ne "${YELLOW}请输入远程数据库驱动类型 (mysql / mariadb) [默认 mariadb]: ${RESET}"
        read -r db_connection
        [[ -z "$db_connection" ]] && db_connection="mariadb"

        echo -ne "${YELLOW}请输入远程数据库地址 (Host): ${RESET}"
        read -r db_host
        while [[ -z "$db_host" ]]; do
            echo -e "${RED}错误: 数据库地址不能为空！${RESET}"
            echo -ne "${YELLOW}请输入远程数据库地址 (Host): ${RESET}"
            read -r db_host
        done

        echo -ne "${YELLOW}请输入远程数据库端口 [默认: 3306]: ${RESET}"
        read -r db_port
        [[ -z "$db_port" ]] && db_port="3306"

        echo -ne "${YELLOW}请输入远程数据库名称 [默认: paymenter]: ${RESET}"
        read -r db_name
        [[ -z "$db_name" ]] && db_name="paymenter"

        echo -ne "${YELLOW}请输入远程数据库用户名 [默认: paymenter]: ${RESET}"
        read -r db_user
        [[ -z "$db_user" ]] && db_user="paymenter"

        echo -ne "${YELLOW}请输入远程数据库密码: ${RESET}"
        read -r db_password
    else
        echo -e "${RED}输入有误，取消部署。${RESET}"
        return
    fi

    # 创建本地所需要的持久化目录并放开权限
    echo -e "\n${YELLOW}正在初始化本地挂载目录权限...${RESET}"
    mkdir -p "$BASE_DIR/storage/logs" "$BASE_DIR/storage/public" "$BASE_DIR/themes" "$BASE_DIR/extensions" "$BASE_DIR/database"
    chmod -R 777 "$BASE_DIR"

    # 3. 写入环境配置文件 .env
    cat <<EOF > "$ENV_FILE"
DB_CONNECTION=${db_connection}
DB_HOST=${db_host}
DB_PORT=${db_port}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_password}
EOF

    # 4. 根据模式动态生成纯绝对路径挂载的 docker-compose.yml
    echo -e "${YELLOW}正在生成对应的 docker-compose.yml 配置文件...${RESET}"
    
    # 基础公共 Service：包含 web, cache 和 asset-builder
    if [[ "$db_mode" == "1" ]]; then
        # 带有本地 MariaDB 的模板
        cat <<EOF > "$COMPOSE_FILE"
services:
  database:
    container_name: paymenter-db
    image: mariadb:lts
    restart: always
    command: --default-authentication-plugin=mysql_native_password --max_allowed_packet=64M --wait_timeout=28800
    volumes:
      - "./database:/var/lib/mysql"
    environment:
      MYSQL_ROOT_PASSWORD: "${db_root_password}"
      MYSQL_DATABASE: "${db_name}"
      MYSQL_USER: "${db_user}"
      MYSQL_PASSWORD: "${db_password}"
    networks:
      - paymenter_nw

  cache:
    container_name: paymenter-cache
    image: redis:alpine
    restart: always
    networks:
      - paymenter_nw

  paymenter:
    container_name: ${CONTAINER_NAME}
    image: ghcr.io/paymenter/paymenter:latest
    restart: always
    ports:
      - "${custom_port}:80"
    volumes:
      - "./:/app/var/"
      - "./storage/logs:/app/storage/logs"
      - "./storage/public:/app/storage/app/public"
      - "./themes:/app/themes"
      - "./extensions:/app/extensions"
      - "app_volume:/app"
    environment:
      DB_CONNECTION: "\${DB_CONNECTION}"
      DB_HOST: "\${DB_HOST}"
      DB_PORT: "\${DB_PORT}"
      DB_DATABASE: "\${DB_NAME}"
      DB_USERNAME: "\${DB_USER}"
      DB_PASSWORD: "\${DB_PASSWORD}"
      APP_ENV: "production"
      CACHE_STORE: "redis"
      REDIS_HOST: "paymenter-cache"
      PAYMENTER_SKIP_DEFAULT: "false"
    depends_on:
      - database
      - cache
    networks:
      - paymenter_nw

  asset-builder:
    container_name: paymenter-asset-builder
    image: node:22-alpine
    profiles: ["build"]
    working_dir: /app
    volumes:
      - "./themes:/app/themes"
      - "./extensions:/app/extensions"
      - "./:/app/var"
      - "app_volume:/app"
    command: >
      sh -c "tail -f /dev/null"
    networks:
      - paymenter_nw

networks:
  paymenter_nw:
    driver: bridge

volumes:
  app_volume:
EOF
    else
        # 不带本地数据库的纯 Web 容器模板
        cat <<EOF > "$COMPOSE_FILE"
services:
  cache:
    container_name: paymenter-cache
    image: redis:alpine
    restart: always
    networks:
      - paymenter_nw

  paymenter:
    container_name: ${CONTAINER_NAME}
    image: ghcr.io/paymenter/paymenter:latest
    restart: always
    ports:
      - "${custom_port}:80"
    volumes:
      - "./:/app/var/"
      - "./storage/logs:/app/storage/logs"
      - "./storage/public:/app/storage/app/public"
      - "./themes:/app/themes"
      - "./extensions:/app/extensions"
      - "app_volume:/app"
    environment:
      DB_CONNECTION: "\${DB_CONNECTION}"
      DB_HOST: "\${DB_HOST}"
      DB_PORT: "\${DB_PORT}"
      DB_DATABASE: "\${DB_NAME}"
      DB_USERNAME: "\${DB_USER}"
      DB_PASSWORD: "\${DB_PASSWORD}"
      APP_ENV: "production"
      CACHE_STORE: "redis"
      REDIS_HOST: "paymenter-cache"
      PAYMENTER_SKIP_DEFAULT: "false"
    depends_on:
      - cache
    networks:
      - paymenter_nw

  asset-builder:
    container_name: paymenter-asset-builder
    image: node:22-alpine
    profiles: ["build"]
    working_dir: /app
    volumes:
      - "./themes:/app/themes"
      - "./extensions:/app/extensions"
      - "./:/app/var"
      - "app_volume:/app"
    command: >
      sh -c "tail -f /dev/null"
    networks:
      - paymenter_nw

networks:
  paymenter_nw:
    driver: bridge

volumes:
  app_volume:
EOF
    fi

    echo -e "${YELLOW}正在通过 Docker Compose 启动容器服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务及依赖初始化 (约 10 秒)...${RESET}"
    sleep 10

    # 5. 执行官方要求的初始化命令
    echo -e "\n${CYAN}====== 3. 开始执行 Paymenter 官方初始化命令行 ======${RESET}"
    
    echo -e "${YELLOW}[1/3] 正在配置系统应用 URL...${RESET}"
    docker compose exec -it paymenter php artisan app:init

    echo -e "${YELLOW}[2/3] 正在为数据库添加初始属性...${RESET}"
    docker compose exec -it paymenter php artisan db:seed --class=CustomPropertySeeder

    echo -e "${YELLOW}[3/3] 正在创建初始管理员用户...${RESET}"
    docker compose exec -it paymenter php artisan app:user:create

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN}     Paymenter 部署与初始化全部完成！            ${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW}面板访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}面板安装根目录: ${BASE_DIR}${RESET}"
    echo -e "${YELLOW}数据库主机   : ${db_host}${RESET}"
    echo -e "${YELLOW}数据库名称   : ${db_name}${RESET}"
    echo -e "${YELLOW}数据库用户   : ${db_user}${RESET}"
    echo -e "${YELLOW}数据库密码   : ${db_password}${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}DB Root 密码 : ${db_root_password}${RESET}"
    fi
    echo -e "${GREEN}------------------------------------------------${RESET}"
    echo -e "${CYAN}提示：如果你在代理(Nginx/CDN)后运行，请进入 管理员 -> 设置 -> 安全设置${RESET}"
    echo -e "${CYAN}配置可信代理（如 172.23.0.0/16），否则文件上传会失败。${RESET}"
    echo -e "${GREEN}================================================${RESET}"
}

# 编译资产编译器的前端静态文件 (主题/扩展)
build_assets() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在启动 asset-builder 编译前端资源...${RESET}"
    cd "$BASE_DIR"
    docker compose run --rm asset-builder npm install
    docker compose run --rm asset-builder npm run build
    echo -e "${GREEN}前端资源 (Themes & Extensions) 编译成功并已应用！${RESET}"
}

# 更新 Paymenter 镜像
update_paymenter() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 Paymenter 镜像并升级...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 Paymenter
uninstall_paymenter() {
    echo -ne "${YELLOW}确定要卸载并删除 Paymenter 堆栈容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否删除本地所有下载的代码、扩展、主题及数据库文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有数据已彻底清理。${RESET}"
            else
                echo -e "${YELLOW}已保留本地挂载数据，目录位于: $BASE_DIR${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" paymenter-db paymenter-cache 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_paymenter() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_paymenter() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_paymenter() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_paymenter() { cd "$BASE_DIR" && docker compose logs -f; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}面板安装目录   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Paymenter 管理面板  ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动 (包含自动化初始化)${RESET}"
    echo -e "${GREEN}2. 编译前端 (安装/修改主题和扩展后执行)${RESET}"
    echo -e "${GREEN}3. 更新服务${RESET}"
    echo -e "${GREEN}4. 卸载服务${RESET}"
    echo -e "${GREEN}5. 启动服务${RESET}"
    echo -e "${GREEN}6. 停止服务${RESET}"
    echo -e "${GREEN}7. 重启服务${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_paymenter ;;
        2) build_assets ;;
        3) update_paymenter ;;
        4) uninstall_paymenter ;;
        5) start_paymenter ;;
        6) stop_paymenter ;;
        7) restart_paymenter ;;
        8) logs_paymenter ;;
        9) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
