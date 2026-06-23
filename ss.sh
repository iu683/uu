#!/bin/bash
# =================================================================
# FOSSBilling 自动化管理面板 (支持本地新装/远程连接可选)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# 定义核心容器名
CONTAINER_NAME="fossbilling-web"
BASE_DIR="/opt/fossbilling"
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

        data_dir=$(docker inspect -f '{{range .Mounts}}{{.Source}}{{break}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$data_dir" ]] && data_dir="/opt/fossbilling"
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        data_dir="N/A"
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
        echo "foss_pass_$(date +%s)"
    fi
}

# 部署 FOSSBilling 主函数
install_fossbilling() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 基础环境配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 FOSSBilling 访问端口 [默认: 80]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="80"

    echo -e "\n${CYAN}====== 2. 数据库类型选择 ======${RESET}"
    echo -e "${GREEN}1) 部署全新的本地 MySQL 数据库 (自动容器化构建)${RESET}"
    echo -e "${GREEN}2) 连接已有的远程/外部 MySQL 数据库 (不创建本地库)${RESET}"
    echo -ne "${YELLOW}请选择数据库部署模式 [默认 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    if [[ "$db_mode" == "1" ]]; then
        # 本地数据库配置
        db_host="fossbilling-db"
        db_port="3306"
        echo -ne "${YELLOW}请输入本地数据库名称 [默认: fossbilling]: ${RESET}"
        read -r db_name
        [[ -z "$db_name" ]] && db_name="fossbilling"

        echo -ne "${YELLOW}请输入本地数据库用户名 [默认: foss_user]: ${RESET}"
        read -r db_user
        [[ -z "$db_user" ]] && db_user="foss_user"

        echo -ne "${YELLOW}请输入本地数据库密码 (留空则随机生成): ${RESET}"
        read -r db_password
        [[ -z "$db_password" ]] && db_password=$(generate_password)

    elif [[ "$db_mode" == "2" ]]; then
        # 远程数据库配置
        echo -ne "${YELLOW}请输入远程数据库地址 (Host) [例如 192.168.1.100]: ${RESET}"
        read -r db_host
        while [[ -z "$db_host" ]]; do
            echo -e "${RED}错误: 远程数据库地址不能为空！${RESET}"
            echo -ne "${YELLOW}请输入远程数据库地址 (Host): ${RESET}"
            read -r db_host
        done

        echo -ne "${YELLOW}请输入远程数据库端口 [默认: 3306]: ${RESET}"
        read -r db_port
        [[ -z "$db_port" ]] && db_port="3306"

        echo -ne "${YELLOW}请输入远程数据库名称 [默认: fossbilling]: ${RESET}"
        read -r db_name
        [[ -z "$db_name" ]] && db_name="fossbilling"

        echo -ne "${YELLOW}请输入远程数据库用户名 [默认: foss_user]: ${RESET}"
        read -r db_user
        [[ -z "$db_user" ]] && db_user="foss_user"

        echo -ne "${YELLOW}请输入远程数据库密码: ${RESET}"
        read -r db_password
    else
        echo -e "${RED}输入有误，取消部署。${RESET}"
        return
    fi

    # 3. 写入环境配置文件 .env
    chmod -R 777 "$BASE_DIR"
    cat <<EOF > "$ENV_FILE"
DB_HOST=${db_host}
DB_PORT=${db_port}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_password}
EOF

    # 4. 根据模式动态生成 docker-compose.yml
    echo -e "\n${YELLOW}正在生成对应的 docker-compose.yml 配置文件...${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        # 包含本地 MySQL 的 Compose 模板
        cat <<EOF > "$COMPOSE_FILE"
services:
  fossbilling:
    container_name: ${CONTAINER_NAME}
    image: fossbilling/fossbilling:latest
    restart: always
    ports:
      - "${custom_port}:80"
    environment:
      - DB_HOST=\${DB_HOST}
      - DB_NAME=\${DB_NAME}
      - DB_USER=\${DB_USER}
      - DB_PASSWORD=\${DB_PASSWORD}
    volumes:
      - fossbilling_web:/var/www/html
    depends_on:
      - mysql

  mysql:
    container_name: fossbilling-db
    image: mysql:8.2
    restart: always
    environment:
      MYSQL_DATABASE: \${DB_NAME}
      MYSQL_USER: \${DB_USER}
      MYSQL_PASSWORD: \${DB_PASSWORD}
      MYSQL_RANDOM_ROOT_PASSWORD: '1'
    volumes:
      - fossbilling_db:/var/lib/mysql

volumes:
  fossbilling_web:
  fossbilling_db:
EOF
    else
        # 纯 Web 容器不带库的 Compose 模板
        cat <<EOF > "$COMPOSE_FILE"
services:
  fossbilling:
    container_name: ${CONTAINER_NAME}
    image: fossbilling/fossbilling:latest
    restart: always
    ports:
      - "${custom_port}:80"
    volumes:
      - fossbilling_web:/var/www/html

volumes:
  fossbilling_web:
EOF
    fi

    echo -e "${YELLOW}正在通过 Docker Compose 启动服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    # 动态等待时间（本地库初始化慢一些）
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}等待本地容器和数据库初始化 (约5秒)...${RESET}"
        sleep 5
    else
        echo -e "${YELLOW}等待网页容器初始化 (约2秒)...${RESET}"
        sleep 2
    fi

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================================${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${GREEN}     FOSSBilling 部署成功 (本地数据库模式)      ${RESET}"
    else
        echo -e "${GREEN}     FOSSBilling 部署成功 (远程数据库模式)      ${RESET}"
    fi
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}数据库主机   : ${db_host}${RESET}"
    if [[ "$db_mode" == "2" ]]; then
         echo -e "${YELLOW}数据库端口   : ${db_port}${RESET}"
    fi
    echo -e "${YELLOW}数据库名称   : ${db_name}${RESET}"
    echo -e "${YELLOW}数据库用户   : ${db_user}${RESET}"
    echo -e "${YELLOW}数据库密码   : ${db_password}${RESET}"
    echo -e "${GREEN}------------------------------------------------${RESET}"
    echo -e "${CYAN}提示: 请通过上述网页地址进入安装向导。${RESET}"
    echo -e "${CYAN}在向导的 Database 环节，准确填入上方打印的各项数据库参数。${RESET}"
    echo -e "${GREEN}================================================${RESET}"
}

# 更新 FOSSBilling 镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新镜像并平滑升级...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 FOSSBilling
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 FOSSBilling 堆栈容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            echo -e "${GREEN}容器与关联的本地 Docker 卷已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地脚本安装目录（包括 .env 配置文件）？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" fossbilling-db 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_translate() { cd "$BASE_DIR" && docker compose logs -f; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}Web端镜像      : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}面板主控目录   : ${BASE_DIR}${RESET}"
    if [[ -f "$ENV_FILE" ]]; then
        echo -e "${GREEN}--------------------------------${RESET}"
        echo -e "${CYAN}当前所配数据库参数 (来自 .env):${RESET}"
        cat "$ENV_FILE" | sed 's/^/  /'
    fi
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈  FOSSBilling 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
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
        1) install_fossbilling ;;
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
