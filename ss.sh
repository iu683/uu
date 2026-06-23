#!/bin/bash
# =================================================================
# octopus Docker Compose 管理面板 (智能防冲突版)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="octopus"
BASE_DIR="/opt/octopus"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

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
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8080"
        
        data_dir=$(docker inspect -f '{{range .Mounts}}{{.Source}}{{break}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$data_dir" ]] && data_dir="$BASE_DIR/data"
    else
        webui_port="N/A"
        data_dir="N/A"
    fi
}

# 部署 octopus
install_octopus() {
    check_dependencies
    
    # 先建立脚本工作目录
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 端口配置
    echo -ne "${YELLOW}请输入服务访问端口 (宿主机端口) [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"

    # 2. 路径配置
    echo -ne "${YELLOW}请输入数据存放绝对路径 [默认: /opt/octopus/data]: ${RESET}"
    read -r custom_data
    [[ -z "$custom_data" ]] && custom_data="/opt/octopus/data"

    # 【核心修复】检查如果目标路径是个残留的“坏文件”，直接扬了它，防止 Docker 挂载报错
    if [ -e "$custom_data" ] && [ ! -d "$custom_data" ]; then
        echo -e "${RED}警告: 检测到路径 $custom_data 被普通文件占用，正在强行清理...${RESET}"
        rm -rf "$custom_data"
    fi

    # 递归创建真正的文件夹，并赋予权限
    mkdir -p "$custom_data"
    chmod -R 777 "$custom_data" 2>/dev/null

    echo -e "${YELLOW}正在生成标准完美的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  octopus:
    image: bestrui/octopus
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${custom_port}:8080"
    volumes:      
      - ${custom_data}:/app/data
EOF

    echo -e "${YELLOW}正在启动 octopus 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务初始化 (约5秒)...${RESET}"
    sleep 5

    local current_ip
    current_ip=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}         octopus 部署成功！       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${current_ip}:${custom_port}${RESET}"
    echo -e "${YELLOW}默认账号密码   : admin/admin${RESET}"
    echo -e "${YELLOW}宿主机数据路径 : $custom_data${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_octopus() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载容器
uninstall_octopus() {
    echo -ne "${YELLOW}确定要卸载并删除 octopus 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件和挂载的数据数据？(y/n): ${RESET}"
            read -r clean_data
            if [[ "$clean_data" == "y" || "$clean_data" == "Y" ]]; then
                rm -rf "$BASE_DIR"
                if [ "$data_dir" != "N/A" ] && [ -d "$data_dir" ]; then
                    rm -rf "$data_dir"
                fi
                echo -e "${GREEN}数据与配置文件已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
            echo -e "${GREEN}独立容器已强行移除。${RESET}"
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_octopus() { 
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"
    else
        echo -e "${RED}错误: 未检测到配置文件，无法启动。${RESET}"
    fi
}

stop_octopus() { 
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"
    else
        echo -e "${RED}错误: 未检测到配置文件，无法停止。${RESET}"
    fi
}

restart_octopus() { 
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"
    else
        echo -e "${RED}错误: 未检测到配置文件，无法重启。${RESET}"
    fi
}

logs_octopus() { 
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        docker logs -f "$CONTAINER_NAME"
    else
        echo -e "${RED}错误: 容器不存在，无法查看日志。${RESET}"
    fi
}

show_info() {
    get_status_info
    local current_ip
    current_ip=$(get_public_ip)
    
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}服务访问地址   : http://${current_ip}:${webui_port}${RESET}"
    echo -e "${YELLOW}宿主机数据路径 : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  octopus 管理面板  ◈     ${RESET}"
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
        1) install_octopus ;;
        2) update_octopus ;;
        3) uninstall_octopus ;;
        4) start_octopus ;;
        5) stop_octopus ;;
        6) restart_octopus ;;
        7) logs_octopus ;;
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
