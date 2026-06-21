#!/bin/bash
# =================================================================
# Baihu (白虎) 网关/应用服务 Docker Compose 独立管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="baihu"
BASE_DIR="/opt/baihu"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态与映射端口
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${GREEN}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="ghcr.io/engigu/baihu:latest"
        
        # 动态抓取映射到容器 8052 端口的宿主机实际端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8052/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8052"
        port_display="${webui_port}"
    else
        img_version="${RED}未安装${RESET}"
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


# 提取并显示初始密码
find_initial_password() {
    if [ ! "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        echo -e "${RED}错误: 容器未部署，无法获取密码。${RESET}"
        return
    fi
    echo -e "${CYAN}正在检索容器日志中的管理员初始化信息...${RESET}"
    local pwd_log=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -A 3 "管理员账号创建成功")
    if [[ -n "$pwd_log" ]]; then
        echo -e "${GREEN}===============================================${RESET}"
        echo -e "${GREEN}🎉 成功找到系统生成的管理员初始信息：${RESET}"
        echo -e "${YELLOW}${pwd_log}${RESET}"
        echo -e "${GREEN}默认用户名 : admin${RESET}"
        echo -e "${GREEN}===============================================${RESET}"
    else
        echo -e "${YELLOW}提示: 未在当前日志中捕获到初始密码信息。${RESET}"
        echo -e "${YELLOW}原因可能是：您已经不是首次启动，或者日志已被刷新轮转。${RESET}"
    fi
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

# 部署 Baihu
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 目录挂载自定义配置 ======${RESET}"
    echo -e "${YELLOW}提示: 直接回车将默认采用同级路径下的 data 和 envs 文件夹。${RESET}"
    
    echo -ne "${YELLOW}请输入数据根挂载路径 [默认: ./]: ${RESET}"
    read -r input_data
    local path_root_raw="${input_data:-./}"
    
    # 动态预计算物理绝对路径
    local real_path_data=$(get_real_path "${path_root_raw%/}/data" "./data")
    local real_path_envs=$(get_real_path "${path_root_raw%/}/envs" "./envs")

    # 预创建全量依赖目录并穿透赋权
    echo -e "${YELLOW}正在宿主机预构建并穿透赋权物理目录...${RESET}"
    mkdir -p "$real_path_data" "$real_path_envs"
    chmod -R 777 "$real_path_data" "$real_path_envs"

    echo -e "\n${CYAN}====== 2. 网络端口与访问配置 ======${RESET}"
    
    # 允许自定义宿主机端口
    echo -ne "${YELLOW}请输入 Baihu 宿主机外部访问端口 [默认: 8052]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8052"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 动态生成自定义端口的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成原生直挂版 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  baihu:
    image: ghcr.io/engigu/baihu:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${custom_port}:8052"
    volumes:
      - ${path_root_raw%/}/data:/app/data
      - ${path_root_raw%/}/envs:/app/envs
    environment:
      - TZ=Asia/Shanghai
      - BH_SERVER_PORT=8052
      - BH_SERVER_HOST=0.0.0.0
      - BH_DB_TYPE=sqlite
      - BH_DB_PATH=/app/data/baihu.db
      - BH_DB_TABLE_PREFIX=baihu_
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Baihu...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化并生成密码 (约5秒)...${RESET}"
    sleep 5

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}          Baihu 部署成功！       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问/API 地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}本地数据直挂路径 : ${real_path_data}${RESET}"
    echo -e "${YELLOW}配置文件路径     : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    
    # 首次部署成功直接在此处调用智提密码函数
    find_initial_password
    
    echo -e "${GREEN}================================${RESET}"
}

# 更新 Baihu 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Baihu 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！组件已处于最新状态。${RESET}"
}

# 卸载 Baihu
uninstall_utils() {
    echo -e "${RED}警告: 卸载如果清理数据，将永久丢失您的 SQLite 数据库内容及环境变动！${RESET}"
    echo -ne "${YELLOW}确定要卸载并删除 Baihu 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}【高风险】是否同时彻底删除本地全量挂载的数据库和环境配置文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有 Baihu 历史数据已被彻底销毁。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}访问地址       : http://${DETECT_IP}:${port_display}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      ◈  Baihu 管理面板  ◈     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${port_display}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置状态${RESET}"
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
