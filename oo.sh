#!/bin/bash
# =================================================================
# Cloudreve Docker Compose 管理面板 (本地/远程双模 + 高精端口版)
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/cloudreve"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
DEFAULT_IMAGE="cloudreve/cloudreve:latest"

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

# 动态获取容器整体状态和端口 (采用原生 Docker Inspect 技术)
get_status_info() {
    if [ -f "$COMPOSE_FILE" ]; then
        if [ "$(docker ps -q -f name=cloudreve-backend)" ]; then
            status="${GREEN}运行中${RESET}"
            web_port=$(docker inspect --format='{{(index (index .NetworkSettings.Ports "5212/tcp") 0).HostPort}}' cloudreve-backend 2>/dev/null)
        elif [ "$(docker ps -aq -f name=cloudreve-backend)" ]; then
            status="${YELLOW}已停止${RESET}"
            web_port=""
        else
            status="${RED}未部署${RESET}"
            web_port=""
        fi
        
        if [ -z "$web_port" ]; then
            web_port=$(grep -A 5 "cloudreve:" "$COMPOSE_FILE" 2>/dev/null | grep -E '\-[[:space:]]*["'\'']?.*:5212' | head -n 1 | grep -oE '[0-9]+:5212' | cut -d':' -f1)
            [[ -z "$web_port" ]] && web_port="5212"
        fi
    else
        status="${RED}未初始化${RESET}"
        web_port="N/A"
    fi
}

# 部署 Cloudreve
install_cloudreve() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 数据库/缓存运行模式选择 ======${RESET}"
    echo -e " 1. 直接部署全新完整环境 (包含全新的本地 PostgreSQL 和 Redis 容器)"
    echo -e " 2. 连接外部/远程已有的数据库与 Redis (需提前手动创建好 PostgreSQL 数据库)"
    echo -ne "${YELLOW}请选择运行模式 [默认: 1]: ${RESET}"
    read -r db_mode
    [[ -z "$db_mode" ]] && db_mode="1"

    echo -e "${CYAN}====== 基础参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Cloudreve Web 访问端口 [默认: 5212]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="5212"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # === 核心新增：本地挂载目录自定义路径机制 ===
    echo -e "${CYAN}====== 持久化数据挂载路径配置 ======${RESET}"
    echo -ne "${YELLOW}请输入网盘主体文件数据挂载目录 [默认: ${BASE_DIR}/uploads]: ${RESET}"
    read -r mount_uploads_dir
    [[ -z "$mount_uploads_dir" ]] && mount_uploads_dir="${BASE_DIR}/uploads"
    mkdir -p "$mount_uploads_dir"

    # ------------------ 模式 1：全套本地内置容器化 ------------------
    if [[ "$db_mode" == "1" ]]; then
        echo -ne "${YELLOW}请输入内置 PostgreSQL 数据库数据挂载目录 [默认: ${BASE_DIR}/postgres_db]: ${RESET}"
        read -r mount_db_dir
        [[ -z "$mount_db_dir" ]] && mount_db_dir="${BASE_DIR}/postgres_db"
        mkdir -p "$mount_db_dir"

        echo -ne "${YELLOW}请输入内置 Redis 缓存数据挂载目录 [默认: ${BASE_DIR}/redis_db]: ${RESET}"
        read -r mount_rd_dir
        [[ -z "$mount_rd_dir" ]] && mount_rd_dir="${BASE_DIR}/redis_db"
        mkdir -p "$mount_rd_dir"

        echo -e "${YELLOW}正在配置全套本地内置容器环境...${RESET}"
        local rand_db_pass=$(openssl rand -hex 16)
        local db_user="cloudreve"
        local db_name="cloudreve"

        cat << EOF > "$COMPOSE_FILE"
services:
  cloudreve:
    container_name: cloudreve-backend
    image: ${DEFAULT_IMAGE}
    depends_on:
      - postgresql
      - redis
    restart: unless-stopped
    ports:
      - "${custom_port}:5212"
      - "6888:6888"
      - "6888:6888/udp"
    environment:
      - CR_CONF_Database.Type=postgres
      - CR_CONF_Database.Host=postgresql
      - CR_CONF_Database.User=${db_user}
      - CR_CONF_Database.Password=${rand_db_pass}
      - CR_CONF_Database.Name=${db_name}
      - CR_CONF_Database.Port=5432
      - CR_CONF_Redis.Server=redis:6379
      - CR_CONF_Redis.DB=0
    volumes:
      - ${mount_uploads_dir}:/cloudreve/data

  postgresql:
    container_name: postgresql
    image: postgres:17-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${db_user}
      - POSTGRES_PASSWORD=${rand_db_pass}
      - POSTGRES_DB=${db_name}
    volumes:
      - ${mount_db_dir}:/var/lib/postgresql/data

  redis:
    container_name: redis
    image: redis:alpine
    restart: unless-stopped
    volumes:
      - ${mount_rd_dir}:/data
EOF

    # ------------------ 模式 2：连接外部/远程已有的 PostgreSQL + Redis ------------------
    else
        echo -e "${CYAN}====== 远程/外部 PostgreSQL 信息输入 ======${RESET}"
        echo -ne "${YELLOW}请输入外部 PostgreSQL 的 IP 或域名 [默认: 127.0.0.1]: ${RESET}"
        read -r ext_db_host
        [[ -z "$ext_db_host" ]] && ext_db_host="127.0.0.1"
        
        echo -ne "${YELLOW}请输入 PostgreSQL 端口 [默认: 5432]: ${RESET}"
        read -r ext_db_port
        [[ -z "$ext_db_port" ]] && ext_db_port="5432"
        
        echo -ne "${YELLOW}请输入数据库用户名 [默认: cloudreve]: ${RESET}"
        read -r ext_db_user
        [[ -z "$ext_db_user" ]] && ext_db_user="cloudreve"
        
        echo -ne "${YELLOW}请输入数据库密码: ${RESET}"
        read -r ext_db_pass
        
        echo -ne "${YELLOW}请输入目标数据库名 [默认: cloudreve]: ${RESET}"
        read -r ext_db_name
        [[ -z "$ext_db_name" ]] && ext_db_name="cloudreve"

        echo -e "${CYAN}====== 远程/外部 Redis 信息输入 ======${RESET}"
        echo -ne "${YELLOW}请输入外部 Redis 的 IP 或域名 [默认: 127.0.0.1]: ${RESET}"
        read -r ext_rd_host
        [[ -z "$ext_rd_host" ]] && ext_rd_host="127.0.0.1"
        
        echo -ne "${YELLOW}请输入 Redis 端口 [默认: 6379]: ${RESET}"
        read -r ext_rd_port
        [[ -z "$ext_rd_port" ]] && ext_rd_port="6379"

        echo -ne "${YELLOW}请输入 Redis 密码 (若无密码请直接回车): ${RESET}"
        read -r ext_rd_pass

        # 外部 Redis 数据库号配置
        echo -ne "${YELLOW}请输入远程 Redis 数据库号 (DB ID) [默认: 0]: ${RESET}"
        read -r redis_db_cfg
        [[ -z "$redis_db_cfg" ]] && redis_db_cfg="0"

        # 突破 Docker 宿主机回环地址限制
        [[ "$ext_db_host" == "127.0.0.1" || "$ext_db_host" == "localhost" ]] && ext_db_host="172.17.0.1"
        [[ "$ext_rd_host" == "127.0.0.1" || "$ext_rd_host" == "localhost" ]] && ext_rd_host="172.17.0.1"

        cat << EOF > "$COMPOSE_FILE"
services:
  cloudreve:
    container_name: cloudreve-backend
    image: ${DEFAULT_IMAGE}
    restart: unless-stopped
    ports:
      - "${custom_port}:5212"
      - "6888:6888"
      - "6888:6888/udp"
    environment:
      - CR_CONF_Database.Type=postgres
      - CR_CONF_Database.Host=${ext_db_host}
      - CR_CONF_Database.User=${ext_db_user}
      - CR_CONF_Database.Password=${ext_db_pass}
      - CR_CONF_Database.Name=${ext_db_name}
      - CR_CONF_Database.Port=${ext_db_port}
      - CR_CONF_Redis.Server=${ext_rd_host}:${ext_rd_port}
      - CR_CONF_Redis.DB=${redis_db_cfg}
    volumes:
      - ${mount_uploads_dir}:/cloudreve/data
EOF

        # 仅当外部 Redis 设置了密码时，才追加独立密码环境变量
        if [[ -n "$ext_rd_pass" ]]; then
            echo "      - CR_CONF_Redis.Password=${ext_rd_pass}" >> "$COMPOSE_FILE"
        fi
    fi

    # ------------------ 启动集群 ------------------
    echo -e "${YELLOW}正在通过 Docker Compose 启动 Cloudreve 服务中...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    if [ $? -ne 0 ]; then
        echo -e "${RED}部署失败，请检查 Docker 日志。${RESET}"
        return
    fi

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}              Cloudreve 部署成功！                    ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}访问端点(URL) : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}映射宿主机端口 : ${custom_port}${RESET}"
    echo -e "${YELLOW}离线下载端口   : 6888 (TCP/UDP已开启)${RESET}"
    echo -e "${CYAN}主体存储路径   : ${mount_uploads_dir}${RESET}"
    if [[ "$db_mode" == "1" ]]; then
        echo -e "${YELLOW}内置库密码凭证 : 用户:${db_user} | 密码:${rand_db_pass} | 库名:${db_name}${RESET}"
        echo -e "${CYAN}DB持久化路径   : ${mount_db_dir}${RESET}"
        echo -e "${CYAN}Redis持久化路径: ${mount_rd_dir}${RESET}"
    else
        echo -e "${YELLOW}连接外部数据库 : ${ext_db_host}:${ext_db_port} -> 库名:${ext_db_name}${RESET}"
        echo -e "${YELLOW}连接外部缓存库 : Redis -> ${ext_rd_host}:${ext_rd_port} (DB ID: ${redis_db_cfg})${RESET}"
    fi
    echo -e "${YELLOW}面板工作路径   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新服务
update_cloudreve() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取 Cloudreve 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}服务已升级并拉升至最新状态！${RESET}"
}

# 卸载集群
uninstall_cloudreve() {
    echo -ne "${RED}确定要注销并删除 Cloudreve 服务集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            # 解析原挂载目录以便在完全清理时提供一键删除
            local old_uploads=$(grep -A 10 "cloudreve:" "$COMPOSE_FILE" 2>/dev/null | grep -E '\-[[:space:]]*/.*/.*:/cloudreve/data' | awk -F ':' '{print $1}' | tr -d '[:space:]-')
            
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已全部终止并移除。${RESET}"
            echo -ne "${RED}是否同步清理掉本地所有【自定义挂载目录的数据】和环境？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                # 如果从配置文件中拿到了真实路径，就予以彻底清理
                [[ -n "$old_uploads" && -d "$old_uploads" ]] && rm -rf "$old_uploads" && echo -e "${YELLOW}已清除核心网盘文件:${old_uploads}${RESET}"
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}工作目录及所有自定义挂载数据已被彻底清除。${RESET}"
            fi
        else
            docker rm -f cloudreve-backend postgresql redis 2>/dev/null
        fi
        echo -e "${GREEN}完全卸载完毕！${RESET}"
    fi
}

# 周期控制
start_cr() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已正常启动${RESET}"; }
stop_cr() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已安全暂停${RESET}"; }
restart_cr() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已完成软重启${RESET}"; }
logs_cr() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

# 配置显示
show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态   : $status"
    echo -e "${YELLOW}实际映射端口   : ${web_port}${RESET}"
    echo -e "${YELLOW}本地项目路径   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 主菜单
menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}     ◈  Cloudreve 管理面板  ◈      ${RESET}"
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
        1) install_cloudreve ;;
        2) update_cloudreve ;;
        3) uninstall_cloudreve ;;
        4) start_cr ;;
        5) stop_cr ;;
        6) restart_cr ;;
        7) logs_cr ;;
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
