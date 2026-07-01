#!/bin/bash
# =================================================================
# Lucky 网络工具箱 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="lucky"
BASE_DIR="/opt/lucky"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、网络模式和映射端口
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        data_dir="N/A"
        return 0
    fi
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取镜像名称/版本
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 检查是否为 Host 网络模式
        net_mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME" 2>/dev/null)
        if [[ "$net_mode" == "host" ]]; then
            webui_port="16601 (Host模式)"
        else
            # 提取映射端口（默认 16601）
            webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "16601/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
            [[ -z "$webui_port" ]] && webui_port="16601"
        fi

        # 提取数据挂载路径
        data_dir=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/conf"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$data_dir" ]] && data_dir="$BASE_DIR/conf"
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        data_dir="N/A"
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

# 部署 Lucky
install_lucky() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -e "${YELLOW}请选择 Lucky 的网络运行模式:${RESET}"
    echo -e "  ${GREEN}1. Host 模式${RESET} (推荐，拥有最佳的 IPv6 及网络管理兼容性)"
    echo -e "  ${GREEN}2. Port 映射模式${RESET} (传统端口映射，安全性好)"
    echo -ne "${YELLOW}请输入选项 [默认: 1]: ${RESET}"
    read -r net_choice
    [[ -z "$net_choice" ]] && net_choice="1"

    echo -ne "${YELLOW}请输入配置挂载绝对路径 [默认: $BASE_DIR/conf]: ${RESET}"
    read -r custom_data
    [[ -z "$custom_data" ]] && custom_data="$BASE_DIR/conf"

    # 创建目录并赋权
    mkdir -p "$custom_data"
    chmod -R 777 "$BASE_DIR" "$custom_data"

    # 根据选择生成不同的 Compose 配置
    if [[ "$net_choice" == "2" ]]; then
        echo -ne "${YELLOW}请输入 Lucky 访问端口 (宿主机端口) [默认: 16601]: ${RESET}"
        read -r custom_port
        [[ -z "$custom_port" ]] && custom_port="16601"
        if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
            return
        fi
        
        display_port="$custom_port"
        
        echo -e "${YELLOW}正在生成 [Port映射模式] 的 docker-compose.yml 配置文件...${RESET}"
        cat <<EOF > "$COMPOSE_FILE"
services:
  lucky:
    image: gdy666/lucky:v2
    container_name: ${CONTAINER_NAME}
    restart: always
    ports:
      - "${custom_port}:16601"
    volumes:
      - ${custom_data}:/app/conf
      - /var/run/docker.sock:/var/run/docker.sock
EOF
    else
        display_port="16601"
        echo -e "${YELLOW}正在生成 [Host网络模式] 的 docker-compose.yml 配置文件...${RESET}"
        cat <<EOF > "$COMPOSE_FILE"
services:
  lucky:
    image: gdy666/lucky:v2
    container_name: ${CONTAINER_NAME}
    restart: always
    network_mode: host
    volumes:
      - ${custom_data}:/app/conf
      - /var/run/docker.sock:/var/run/docker.sock
EOF
    fi

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Lucky 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}        Lucky 部署成功！        ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${display_port}${RESET}"
    echo -e "${YELLOW}宿主机配置路径 : $custom_data${RESET}"
    echo -e "${RED}提示: 默认初始登录用户名: 666  初始密码: 666${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 Lucky 镜像
update_lucky() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Lucky 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 Lucky
uninstall_lucky() {
    echo -ne "${YELLOW}确定要卸载并删除 Lucky 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件和缓存数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

# 容器开关管理控制（增加文件校验）
check_compose_exist() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return 1
    fi
    return 0
}

start_lucky() { 
    check_compose_exist && cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"
}

stop_lucky() { 
    check_compose_exist && cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"
}

restart_lucky() { 
    check_compose_exist && cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"
}

logs_lucky() { 
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        docker logs -f "$CONTAINER_NAME"
    else
        echo -e "${RED}错误: 容器未创建，无法查看日志！${RESET}"
    fi
}

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}宿主机配置路径 : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈    Lucky   反向代理   ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
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
        1) install_lucky ;;
        2) update_lucky ;;
        3) uninstall_lucky ;;
        4) start_lucky ;;
        5) stop_lucky ;;
        6) restart_lucky ;;
        7) logs_lucky ;;
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
