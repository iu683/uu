#!/bin/bash
# =================================================================
# Dnsmgr Docker Compose 管理面板 (内置自动建库 / 远程手动建库双模版)
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/dnsmgr"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
DEFAULT_IMAGE="netcccyun/dnsmgr"

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

# 动态获取容器整体状态和端口（实时从运行状态提取）
get_status_info() {
    if [ -f "$COMPOSE_FILE" ]; then
        if [ "$(docker ps -q -f name=dnsmgr-web)" ]; then
            status="${GREEN}运行中${RESET}"
            # 实时从正在运行的容器中提取宿主机映射的端口
            web_port=$(docker ps -f name=dnsmgr-web --format "{{.Ports}}" | sed -E 's/.*0.0.0.0:([0-9]+)->.*/\1/' | head -n 1)
            # 如果提取失败（例如网络模式特殊），再尝试 fallback 到配置文件
            if ! [[ "$web_port" =~ ^[0-9]+$ ]]; then
                web_port=$(sed -n '/dnsmgr-web:/,/^[[:space:]]*[a-zA-Z]/p' "$COMPOSE_FILE" | grep -E '\-[[:space:]]*["'\'']?[0-9]+:' | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"''-')
            fi
        elif [ "$(docker ps -aq -f name=dnsmgr-web)" ]; then
            status="${YELLOW}已停止${RESET}"
            # 容器停止时，通过 inspect 获取原本绑定的宿主机端口
            web_port=$(docker inspect --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' dnsmgr-web 2>/dev/null)
        else
            status="${RED}未部署${RESET}"
        fi
        
        # 兜底：如果以上方法都没拿到端口，默认显示 8081
        [[ -z "$web_port" ]] && web_port="8081"
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署 Dnsmgr
install_dnsmgr() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 数据库模式选择 ======${RESET}"
    echo -e " 1. 直接部署全新的 MySQL 5.7 (Docker 容器化 + 智能自动建库)"
    echo -e " 2. 使用已有的外部/远程 MySQL (自建/云数据库 RDS - 需提前手动建库)"
    echo -ne "${YELLOW}请选择数据库模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Dnsmgr Web 访问端口 [默认: 8081]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8081"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # ------------------ 模式 1：全新 Docker 部署 MySQL 5.7 ------------------
    if [[ "$db_mode" == "1" ]]; then
        echo -ne "${YELLOW}请为全新 MySQL 设置 root 密码 [默认: 123456]: ${RESET}"
        read -r db_pass
        [[ -z "$db_pass" ]] && db_pass="123456"

        echo -e "${YELLOW}正在配置全新容器化 MySQL 5.7 数据库环境...${RESET}"
        
        mkdir -p "$BASE_DIR/mysql/conf" "$BASE_DIR/mysql/logs" "$BASE_DIR/mysql/data" "$BASE_DIR/web"
        
        if [ ! -f "$BASE_DIR/mysql/conf/my.cnf" ]; then
            cat << EOF > "$BASE_DIR/mysql/conf/my.cnf"
[mysqld]
user=mysql
default-storage-engine=INNODB
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
EOF
        fi

        cat << EOF > "$COMPOSE_FILE"
services:
  dnsmgr-web:
    container_name: dnsmgr-web
    image: ${DEFAULT_IMAGE}
    restart: unless-stopped
    stdin_open: true
    tty: true
    ports:
      - "${custom_port}:80"
    volumes:
      - ${BASE_DIR}/web:/app/www
    depends_on:
      dnsmgr-mysql:
        condition: service_healthy
    networks:
      - dnsmgr-network

  dnsmgr-mysql:
    container_name: dnsmgr-mysql
    image: mysql:5.7
    restart: always
    ports:
      - "3306:3306"
    volumes:
      - ${BASE_DIR}/mysql/conf/my.cnf:/etc/mysql/my.cnf
      - ${BASE_DIR}/mysql/logs:/logs
      - ${BASE_DIR}/mysql/data:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=${db_pass}
      - TZ=Asia/Shanghai
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h localhost -u root -p${db_pass}"]
      interval: 5s
      timeout: 5s
      retries: 10
    networks:
      - dnsmgr-network

networks:
  dnsmgr-network:
    driver: bridge
EOF

        echo -e "${YELLOW}正在通过 Docker Compose 启动 Dnsmgr 容器集群...${RESET}"
        cd "$BASE_DIR" && docker compose up -d --force-recreate

        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: 容器集群启动失败。${RESET}"
            return
        fi

        # 循环等待检测，直到内置 MySQL 真正内部初始化完毕、完全能够应答
        echo -e "${YELLOW}正在等待内置 MySQL 容器完全就绪 (首次启动可能需要些时间)...${RESET}"
        for i in {1..20}; do
            if docker exec -i dnsmgr-mysql mysqladmin ping -h localhost -u root -p"${db_pass}" &>/dev/null; then
                break
            fi
            sleep 3
        done

        # 此时再执行自动创建 dnsmgr 数据库
        echo -e "${YELLOW}正在内置 MySQL 容器中自动创建 'dnsmgr' 数据库...${RESET}"
        docker exec -i dnsmgr-mysql mysql -uroot -p"${db_pass}" -e "CREATE DATABASE IF NOT EXISTS dnsmgr CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
        echo -e "${GREEN}数据库 dnsmgr 创建/检查成功！${RESET}"

    # ------------------ 模式 2：连接外部/远程已有 MySQL ------------------
    else
        echo -e "${CYAN}====== 远程/外部 MySQL 信息确认 ======${RESET}"
        echo -ne "${YELLOW}请输入外部 MySQL 的 IP 或域名 [默认: 127.0.0.1]: ${RESET}"
        read -r ext_host
        [[ -z "$ext_host" ]] && ext_host="127.0.0.1"
        
        echo -ne "${YELLOW}请输入 MySQL 端口 [默认: 3306]: ${RESET}"
        read -r ext_port
        [[ -z "$ext_port" ]] && ext_port="3306"

        # 处理本地回环外连突破提示
        if [[ "$ext_host" == "127.0.0.1" || "$ext_host" == "localhost" ]]; then
            ext_host="172.17.0.1"
            echo -e "${YELLOW}提示: 检测到本地回环地址，网页配置时请填写宿主机网关 IP: 172.17.0.1${RESET}"
        fi

        echo -e "${YELLOW}提示: 请确保远程 MySQL (${ext_host}:${ext_port}) 中已手动创建好名为 'dnsmgr' 的数据库。${RESET}"

        mkdir -p "$BASE_DIR/web"

        cat << EOF > "$COMPOSE_FILE"
services:
  dnsmgr-web:
    container_name: dnsmgr-web
    image: ${DEFAULT_IMAGE}
    restart: unless-stopped
    stdin_open: true
    tty: true
    ports:
      - "${custom_port}:80"
    volumes:
      - ${BASE_DIR}/web:/app/www
EOF

        echo -e "${YELLOW}正在通过 Docker Compose 启动 Dnsmgr Web 服务...${RESET}"
        cd "$BASE_DIR" && docker compose up -d --force-recreate
    fi

    if [ $? -ne 0 ]; then
        echo -e "${RED}====================================================${RESET}"
        echo -e "${RED} 错误: 容器启动失败。请检查网络环境。               ${RESET}"
        echo -e "${RED}====================================================${RESET}"
        return
    fi

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             Dnsmgr 部署成功！                      ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}应用访问地址   : http://${DETECT_IP}:${custom_port}/install${RESET}"
    echo -e "${YELLOW}宿主机映射端口 : ${custom_port}${RESET}"
    echo -ne "${YELLOW}数据库运行模式 : ${RESET}"
    if [[ "$db_mode" == "1" ]]; then 
        echo -e "${GREEN}全新内置容器 (MySQL 5.7)${RESET}"
        echo -e "${YELLOW}自动配置数据库 : dnsmgr${RESET}"
        echo -e "${YELLOW}数据库内部地址 : dnsmgr-mysql:3306${RESET}"
        echo -e "${YELLOW}数据库初始凭证 : root / ${db_pass}${RESET}"
    else 
        echo -e "${GREEN}连接外部/远程已有的 MySQL 数据库${RESET}"
        echo -e "${YELLOW}网页安装建议目标 : ${ext_host}:${ext_port}${RESET}"
        echo -e "${YELLOW}请在下一步网页安装时，手动填写您的远程库账号和密码${RESET}"
    fi
    echo -e "${YELLOW}部署工作目录   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_dnsmgr() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取 Dnsmgr 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}服务更新完成！${RESET}"
}

# 卸载 Dnsmgr
uninstall_dnsmgr() {
    echo -ne "${RED}确定要卸载并删除 Dnsmgr 服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}是否同时删除所有网站程序源码、日志及数据库文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                cd "$BASE_DIR" && docker compose down -v
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}所有相关数据文件及工作目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f dnsmgr-web dnsmgr-mysql 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

# 基础生命周期控制
start_dm() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}Dnsmgr 服务已启动${RESET}"; }
stop_dm() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}Dnsmgr 服务已停止${RESET}"; }
restart_dm() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}Dnsmgr 服务已重启${RESET}"; }
logs_dm() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

# 显示配置面板
show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态   : $status"
    echo -e "${YELLOW}宿主机映射端口 : ${web_port}${RESET}"
    echo -e "${YELLOW}工作路径       : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 主菜单
menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}       ◈  Dnsmgr 管理面板  ◈        ${RESET}"
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
        1) install_dnsmgr ;;
        2) update_dnsmgr ;;
        3) uninstall_dnsmgr ;;
        4) start_dm ;;
        5) stop_dm ;;
        6) restart_dm ;;
        7) logs_dm ;;
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
