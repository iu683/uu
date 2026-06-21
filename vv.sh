#!/bin/bash
# =================================================================
# ShadowSSH (前后端分离版) Docker Compose 独立管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

FRONTEND_CONTAINER="shadowssh-frontend"
BACKEND_CONTAINER="shadowssh-backend"
BASE_DIR="/opt/shadowssh"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取服务状态（双容器组合校验）
get_status_info() {
    local front_running=$(docker ps -q -f name=^/${FRONTEND_CONTAINER}$)
    local back_running=$(docker ps -q -f name=^/${BACKEND_CONTAINER}$)
    
    if [[ -n "$front_running" && -n "$back_running" ]]; then
        status="${GREEN}运行中 (前后端均就绪)${RESET}"
    elif [[ -z "$front_running" && -z "$back_running" ]]; then
        if [ "$(docker ps -aq -f name=^/${FRONTEND_CONTAINER}$)" ]; then
            status="${RED}已停止${RESET}"
        else
            status="${RED}未部署${RESET}"
        fi
    else
        status="${YELLOW}部分运行 (请检查日志)${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${FRONTEND_CONTAINER}$)" ]; then
        # 动态抓取映射到前端 80 端口的宿主机实际端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$FRONTEND_CONTAINER" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="18111"
        port_display="${webui_port}"
    else
        port_display="N/A"
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


# 处理绝对路径与相对路径转换
get_real_path() {
    local input_path="$1"
    local default_path="$2"
    [[ -z "$input_path" ]] && input_path="$default_path"

    if [[ "$input_path" == "./"* ]]; then
        echo "$BASE_DIR/${input_path#./}"
    else
        echo "$input_path"
    fi
}

# 一键部署 ShadowSSH
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 后端数据持久化路径 ======${RESET}"
    echo -e "${YELLOW}提示: 直接回车将默认采用脚本同级路径下的 data 文件夹。${RESET}"
    
    echo -ne "${YELLOW}请输入后端数据(data)挂载路径 [默认: ./data]: ${RESET}"
    read -r input_data
    local path_data_raw="${input_data:-./data}"
    local real_path_data=$(get_real_path "$path_data_raw" "./data")

    # 预创建本地目录并赋权
    echo -e "${YELLOW}正在宿主机预构建后端物理存储目录...${RESET}"
    mkdir -p "$real_path_data"
    chmod -R 777 "$real_path_data"

    echo -e "\n${CYAN}====== 2. Web 前端网络访问端口 ======${RESET}"
    
    # 允许自定义宿主机端口
    echo -ne "${YELLOW}请输入 ShadowSSH 宿主机外部访问端口 [默认: 18111]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="18111"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 动态生成完备的双服务含 IPv6 栈的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在构建原生直挂版双服务复合 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  frontend:
    image: ceocok/shadowssh-frontend:latest
    pull_policy: always
    container_name: ${FRONTEND_CONTAINER}
    restart: unless-stopped
    ports:
      - "${custom_port}:80"
    depends_on:
      - backend
    networks:
      - shadowssh-network

  backend:
    image: ceocok/shadowssh-backend:latest
    pull_policy: always
    container_name: ${BACKEND_CONTAINER}
    restart: unless-stopped
    environment:
      NODE_ENV: production
      PORT: 3001
    volumes:
      - ${path_data_raw}:/app/data
    networks:
      - shadowssh-network

networks:
  shadowssh-network:
    driver: bridge
    name: shadowssh-network
    enable_ipv6: true
    ipam:
      config:
        - subnet: fd01::/80
          gateway: fd01::1
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 协同拉起前后端服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务联调及容器初始化 (约4秒)...${RESET}"
    sleep 4

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}         ShadowSSH 架构群落部署成功！                 ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}Web 访问后台     : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}后端数据库路径   : ${real_path_data}${RESET}"
    echo -e "${YELLOW}IPv6 独立网络栈  : fd01::/80 (已就绪)${RESET}"
    echo -e "${YELLOW}配置文件路径     : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${CYAN}💡 提示: 系统采用了 always 策略强制拉取最新镜像，以后重启将自动检测最新演进。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新整个应用群镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取前后端双系统最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！前后端架构均已切换至最新生产状态。${RESET}"
}

# 卸载整个群落
uninstall_utils() {
    echo -e "${RED}警告: 卸载如果清理数据，将永久丢失您的网络节点配置及后端全量流水账单！${RESET}"
    echo -ne "${YELLOW}确定要卸载并销毁整个 ShadowSSH 容器集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}服务群落已优雅停止，独立网络栈已安全注销。${RESET}"
            echo -ne "${RED}【高风险】是否同时彻底删除本地挂载的后端核心 data 文件夹？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有历史核心数据已被彻底清除。${RESET}"
            fi
        else
            docker rm -f "$FRONTEND_CONTAINER" "$BACKEND_CONTAINER" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}架构服务群已全面启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}架构服务群已安全挂起${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}架构服务群已完成链式重启${RESET}"; }

# 引导式日志查看
logs_utils() {
    echo -e "${CYAN}请选择要查看日志的服务组件:${RESET}"
    echo -e "1) Web 前端 (${FRONTEND_CONTAINER})"
    echo -e "2) 核心后端 (${BACKEND_CONTAINER})"
    echo -ne "请输入序号 [默认 1]: "
    read -r log_choice
    if [[ "$log_choice" == "2" ]]; then
        docker logs -f "$BACKEND_CONTAINER"
    else
        docker logs -f "$FRONTEND_CONTAINER"
    fi
}

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前群落状态   : $status"
    echo -e "${YELLOW}服务映射地址   : http://${DETECT_IP}:${port_display}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  ShadowSSH 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${port_display}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动集群${RESET}"
    echo -e "${GREEN}5. 停止集群${RESET}"
    echo -e "${GREEN}6. 重启集群${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_utils ;;
        2) update_utils ;;
        3) uninstall_utils ;;
        4) start_utils ;;
        5) stop_utils ;;
        6) restart_utils ;;
        7) logs_utils ;;
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
