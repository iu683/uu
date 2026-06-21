#!/bin/bash
# =================================================================
# SiYuan Note 思源笔记 Docker Compose 独立管理面板 (增强镜像选择版)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="siyuan"
BASE_DIR="/opt/siyuan"
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
        [[ -z "$img_version" ]] && img_version="b3log/siyuan:latest"
        
        # 动态抓取映射到容器 6806 端口的宿主机实际端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "6806/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="6806"
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
        for url in "https://api64.ipify.org" "https://6.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.sb"; do
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

# 部署 SiYuan Note
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 镜像源版本选择 ======${RESET}"
    echo -e "${GREEN}1). 官方原版镜像 (b3log/siyuan:latest)${RESET}"
    echo -e "${GREEN}2). 开心解锁版镜像 (apkdv/siyuan-unlock:latest)${RESET}"
    echo -ne "${YELLOW}请选择要部署的镜像版本 [默认 1]: ${RESET}"
    read -r img_choice
    [[ -z "$img_choice" ]] && img_choice="1"

    local selected_image="b3log/siyuan:latest"
    if [[ "$img_choice" == "2" ]]; then
        selected_image="apkdv/siyuan-unlock:latest"
        echo -e "${GREEN}已选择: 开心解锁版镜像${RESET}\n"
    else
        echo -e "${GREEN}已选择: 官方原版镜像${RESET}\n"
    fi

    echo -e "${CYAN}====== 2. 知识库挂载自定义配置 ======${RESET}"
    echo -e "${YELLOW}提示: 直接回车将默认采用主程序同级路径下的 workspace 文件夹。${RESET}"
    
    echo -ne "${YELLOW}请输入笔记数据(workspace)本地挂载路径 [默认: ./workspace]: ${RESET}"
    read -r input_data
    local path_data_raw="${input_data:-./workspace}"
    local real_path_data=$(get_real_path "$path_data_raw" "./workspace")

    # 预创建目录并赋予标准权限
    mkdir -p "$real_path_data"
    chmod -R 777 "$real_path_data"

    echo -e "\n${CYAN}====== 3. 安全与访问配置 ======${RESET}"
    
    # 允许自定义宿主机端口
    echo -ne "${YELLOW}请输入思源笔记宿主机访问端口 [默认: 6806]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="6806"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 自定义访问授权码 AuthCode
    echo -ne "${YELLOW}请设置您的笔记访问授权码(Access Auth Code) [默认: SiyuanPass123]: ${RESET}"
    read -r auth_code
    [[ -z "$auth_code" ]] && auth_code="SiyuanPass123"

    # 时区与权限 ID 设定 (从系统环境获取默认值)
    local current_tz=$(cat /etc/timezone 2>/dev/null || echo "Asia/Shanghai")
    local current_uid=$(id -u)
    local current_gid=$(id -g)

    # 动态生成配置文件
    echo -e "${YELLOW}正在生成思源笔记专用 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  main:
    image: ${selected_image}
    container_name: ${CONTAINER_NAME}
    command: ['--workspace=/siyuan/workspace/', '--accessAuthCode=${auth_code}']
    ports:
      - "${custom_port}:6806"
    volumes:
      - ${real_path_data}:/siyuan/workspace
      - ./workspace/.dummy_home:/home/siyuan
    restart: unless-stopped
    environment:
      - TZ=${current_tz}
      - PUID=${current_uid}
      - PGID=${current_gid}
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 SiYuan...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化并建立工作区 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}        思源笔记 部署成功！      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}所用镜像源     : ${selected_image}${RESET}"
    echo -e "${YELLOW}笔记访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}访问授权码     : ${auth_code}${RESET}"
    echo -e "${YELLOW}数据直挂路径   : ${real_path_data}${RESET}"
    echo -e "${YELLOW}运行用户身份   : PUID=${current_uid} / PGID=${current_gid}${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 思源笔记 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取思源笔记最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！思源笔记已处于最新版本。${RESET}"
}

# 卸载 思源笔记
uninstall_utils() {
    echo -e "${RED}警告: 卸载如果清理数据，将永久丢失您的所有笔记、资产文件以及知识库架构！${RESET}"
    echo -ne "${YELLOW}确定要卸载并删除思源笔记容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}【超高风险】是否同时彻底删除本地全量笔记数据 (workspace 目录)？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有思源笔记历史数据已被彻底销毁。${RESET}"
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
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}当前活动端口   : ${port_display}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  思源笔记 管理面板  ◈   ${RESET}"
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
