#!/bin/bash
# =================================================================
# codeg Docker Compose 管理面板 
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="codeg"
BASE_DIR="/opt/codeg"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
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

# 动态获取容器状态
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取宿主机映射到容器内部 3080 的真实外部端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3080/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3080"
    else
        webui_port="N/A"
    fi
}

# 部署与安装服务
install_codeg() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 安全 Token 配置 (回车默认纯随机)
    echo -ne "${YELLOW}请输入访问 Token (CODEG_TOKEN) [直接回车自动生成随机Token]: ${RESET}"
    read -r custom_token
    if [[ -z "$custom_token" ]]; then
        custom_token="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)"
        echo -e "${GREEN} -> 已自动生成访问 Token: $custom_token${RESET}"
    fi

    # 2. 宿主机主访问端口
    echo -ne "${YELLOW}请输入服务对外访问端口 [默认: 3080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3080"

    # 3. 项目代码挂载绝对路径
    echo -ne "${YELLOW}请输入宿主机项目代码存放绝对路径 [默认: /opt/codeg/projects]: ${RESET}"
    read -r custom_projects_path
    [[ -z "$custom_projects_path" ]] && custom_projects_path="/opt/codeg/projects"

    # 严格清理项目代码路径的残留非目录文件
    if [ -e "$custom_projects_path" ] && [ ! -d "$custom_projects_path" ]; then
        rm -rf "$custom_projects_path"
    fi
    mkdir -p "$custom_projects_path"
    chmod -R 777 "$custom_projects_path" 2>/dev/null

    # 组织生成环境配置文件 .env
    cat <<EOF > "$ENV_FILE"
CODEG_TOKEN=${custom_token}
EOF

    # 生成绝对端口解耦的 docker-compose.yml 文件
    echo -e "${YELLOW}正在生成符合标准的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  codeg:
    image: xintaofei/codeg:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${custom_port}:3080"
    volumes:
      - codeg-data:/data
      - ${custom_projects_path}:/projects
    environment:
      - CODEG_TOKEN=\${CODEG_TOKEN:-}
      - CODEG_PORT=3080
      - CODEG_HOST=0.0.0.0
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  codeg-data:
EOF

    echo -e "${YELLOW}正在安全清理旧集群与发生迁移锁死的命名卷...${RESET}"
    cd "$BASE_DIR"
    # -v 参数会强行把残留的旧数据卷一同冲刷掉，彻底解决 duplicate column 崩溃 Bug
    docker compose down -v --remove-orphans 2>/dev/null

    echo -e "${YELLOW}正在从零拉起干净的服务容器...${RESET}"
    docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务初始化...${RESET}"
    sleep 4

    local current_ip
    current_ip=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}          codeg 部署成功！       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${current_ip}:${custom_port}${RESET}"
    echo -e "${YELLOW}安全访问 Token : ${custom_token}${RESET}"
    echo -e "${YELLOW}代码挂载路径   : $custom_projects_path${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_codeg() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}服务更新完成！${RESET}"
}

# 卸载服务
uninstall_codeg() {
    echo -ne "${YELLOW}确定要卸载并删除 codeg 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            echo -e "${GREEN}容器及命名卷已安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地项目配置目录？(y/n): ${RESET}"
            read -r clean_data
            if [[ "$clean_data" == "y" || "$clean_data" == "Y" ]]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地配置文件已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
            echo -e "${GREEN}独立容器已强行清除。${RESET}"
        fi
    fi
}

start_codeg() { 
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已拉起启动${RESET}"
    fi
}

stop_codeg() { 
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已安全停止${RESET}"
    fi
}

restart_codeg() { 
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已成功完成重启${RESET}"
    fi
}

logs_codeg() { 
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        docker logs -f "$CONTAINER_NAME"
    else
        echo -e "${RED}错误: 容器不存在，无法追踪日志。${RESET}"
    fi
}

show_info() {
    get_status_info
    local current_ip
    current_ip=$(get_public_ip)
    
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前服务状态   : $status"
    if [[ "$webui_port" == "N/A" ]]; then
        echo -e "${YELLOW}访问地址       : N/A${RESET}"
    else
        echo -e "${YELLOW}访问地址       : http://${current_ip}:${webui_port}${RESET}"
    fi
    echo -e "${CYAN}--------------------------------${RESET}"
     echo -e "${YELLOW}安全访问 Token : ${custom_token}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}       ◈  codeg 管理面板  ◈      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}服务状态 :${RESET} $status"
    echo -e "${GREEN}当前端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_codeg ;;
        2) update_codeg ;;
        3) uninstall_codeg ;;
        4) start_codeg ;;
        5) stop_codeg ;;
        6) restart_codeg ;;
        7) logs_codeg ;;
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
