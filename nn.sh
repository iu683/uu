#!/bin/bash
# =================================================================
# DecoTV (Core + Kvrocks) 双容器集群自动化集成与全生命周期管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CORE_NAME="decotv-core"
DB_NAME="decotv-kvrocks"
BASE_DIR="/opt/decotv"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取双容器集群运行状态
get_status_info() {
    local core_run=$(docker ps -q -f name=^/${CORE_NAME}$)
    local db_run=$(docker ps -q -f name=^/${DB_NAME}$)
    local core_exist=$(docker ps -aq -f name=^/${CORE_NAME}$)
    local db_exist=$(docker ps -aq -f name=^/${DB_NAME}$)

    # 集群状态综合判定
    if [[ -n "$core_run" && -n "$db_run" ]]; then
        status="${GREEN}集群健康 (双容器运行中)${RESET}"
    elif [[ -n "$core_run" || -n "$db_run" ]]; then
        status="${YELLOW}集群异常 (部分容器停止)${RESET}"
    elif [[ -n "$core_exist" || -n "$db_exist" ]]; then
        status="${RED}集群已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 提取实时端口
    if [[ -n "$core_exist" ]]; then
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "$CORE_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3000"
        
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CORE_NAME" 2>/dev/null)
    else
        webui_port="N/A"
        img_version="N/A"
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

# 部署核心逻辑
install_translate() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 网络访问端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 DecoTV 网页端访问映射端口 (宿主机) [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"

    echo -e "\n${CYAN}====== 2. 安全鉴权账户配置 ======${RESET}"
    echo -ne "${YELLOW}1. 请输入后台管理【用户名】 [默认: admin]: ${RESET}"
    read -r custom_user
    [[ -z "$custom_user" ]] && custom_user="admin"

    echo -ne "${YELLOW}2. 请输入后台管理【密  码】 [默认: admin_password]: ${RESET}"
    read -r custom_pass
    [[ -z "$custom_pass" ]] && custom_pass="admin_password"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "\n${YELLOW}正在构建多容器网络拓扑并生成 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  decotv-core:
    image: ghcr.io/decohererk/decotv:latest
    container_name: ${CORE_NAME}
    restart: on-failure
    ports:
      - "${custom_port}:3000"
    environment:
      - USERNAME=${custom_user}
      - PASSWORD=${custom_pass}
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://${DB_NAME}:6666
    networks:
      - decotv-network
    depends_on:
      - decotv-kvrocks

  decotv-kvrocks:
    image: apache/kvrocks
    container_name: ${DB_NAME}
    restart: unless-stopped
    volumes:
      - kvrocks-data:/var/lib/kvrocks
    networks:
      - decotv-network

networks:
  decotv-network:
    driver: bridge

volumes:
  kvrocks-data:
EOF

    # 启动集群
    echo -e "\n${YELLOW}正在通过 Docker Compose 同步编排双容器集群...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待 Kvrocks 数据库持久化层及核心初始化 (约 5 秒)...${RESET}"
    sleep 5

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}            DecoTV 集群全套部署成功！                ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}Web 后台访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}配置管理用户名   : ${custom_user}${RESET}"
    echo -e "${YELLOW}配置管理登录密码 : ${custom_pass}${RESET}"
    echo -e "${YELLOW}后端数据库持久化 : Docker 内嵌独立卷 (kvrocks-data)${RESET}"
    echo -e "${CYAN}💡 架构提示：已自动创建高隔离专属网卡 [decotv-network]${RESET}"
    echo -e "${CYAN}   Core 与 Kvrocks 数据库通过内网 6666 端口加密联动，确保公网数据绝对安全。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新整个集群
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在同步拉取 Core 核心与 Apache/Kvrocks 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}整个 DecoTV 矩阵集群更新完毕并平滑重启。${RESET}"
}

# 卸载集群
uninstall_translate() {
    echo -ne "${RED}⚠️ 确定要彻底卸载并删除 DecoTV 双容器集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            rm -rf "$BASE_DIR"
            echo -e "${GREEN}双容器、专属网卡及内嵌 Kvrocks 数据库大容量数据卷已安全彻底清理！${RESET}"
        else
            docker rm -f "$CORE_NAME" "$DB_NAME" 2>/dev/null
            docker volume rm kvrocks-data 2>/dev/null
            docker network rm decotv-network 2>/dev/null
        fi
        echo -e "${GREEN}集群卸载完成！${RESET}"
    fi
}

# 集群级联动控制
start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}DecoTV 集群已全面启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}DecoTV 集群已安全停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}DecoTV 集群已平滑重启${RESET}"; }

# 查看双容器合并日志
logs_translate() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}集群运行状态     : $status"
    echo -e "${YELLOW}Core 核心映像    : ${img_version}${RESET}"
    echo -e "${YELLOW}Web 映射访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}持久化数据库类型 : Apache Kvrocks (NoSQL 高性能引擎)${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}    ◈  DecoTV 管理面板  ◈     ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}集群状态 :${RESET} $status"
    echo -e "${GREEN}服务端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新集群镜像${RESET}"
    echo -e "${GREEN}3. 卸载集群服务${RESET}"
    echo -e "${GREEN}4. 启动集群容器${RESET}"
    echo -e "${GREEN}5. 停止集群容器${RESET}"
    echo -e "${GREEN}6. 重启集群容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
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
