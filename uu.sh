#!/bin/bash
# =================================================================
# Vertex 刷流自动化管理工具 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="vertex"
BASE_DIR="/opt/vertex"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口和数据目录
get_status_info() {
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
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 提取 WebUI 映射出来的宿主机端口 (内部默认 3000)
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3000"

        # 提取宿主机配置路径
        data_dir=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/vertex"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$data_dir" ]] && data_dir="$BASE_DIR/vertex"
        # 自动读取容器生成的密码文件
        pwd_file="$data_dir/data/password"
        if [ -f "$pwd_file" ]; then
            v_password=$(cat "$pwd_file" | tr -d '\n\r ')
        else
            v_password="[ 容器尚未完全初始化，请刷新或稍等片刻 ]"
        fi
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        data_dir="N/A"
        v_password="N/A"
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

    echo -e "${CYAN}====== Vertex 参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入后台 WebUI 访问映射端口 (宿主机) [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"

    echo -ne "${YELLOW}请输入数据持久化目录 [默认: $BASE_DIR/vertex]: ${RESET}"
    read -r path_config
    [[ -z "$path_config" ]] && path_config="$BASE_DIR/vertex"

    # 创建宿主机目录并赋权
    mkdir -p "$path_config"
    chmod -R 777 "$BASE_DIR" "$path_config"

    # 【关键要求】第一步：先拉取一次底包
    echo -e "\n${YELLOW}=================================================${RESET}"
    echo -e "${YELLOW}>> 正在拉取 Vertex 底包镜像 (lswl/vertex-base)...${RESET}"
    echo -e "${YELLOW}=================================================${RESET}"
    docker pull lswl/vertex-base:latest

    # 第二步：生成规范化 docker-compose.yml 配置文件
    echo -e "\n${YELLOW}正在生成符合标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  vertex:
    container_name: ${CONTAINER_NAME}
    volumes:
      - '${path_config}:/vertex'
    ports:
      - '${custom_port}:3000'
    environment:
      - TZ=Asia/Shanghai
    restart: unless-stopped
    image: lswl/vertex:stable
EOF

    # 第三步：启动主容器
    echo -e "\n${YELLOW}正在启动 Vertex 主服务容器...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务初始化 (约 3 秒)...${RESET}"
    sleep 3

    echo -e "${YELLOW}等待服务生成初始密码 (约 5 秒)...${RESET}"
    sleep 5

    # 重新抓取状态以读取新生成的密码
    get_status_info

    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     Vertex 部署成功！     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WEB 访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}默认用户名     : admin${RESET}"
    echo -e "${YELLOW}系统初始密码   : ${CYAN}${v_password}${RESET}"
    echo -e "${YELLOW}持久化配置路径 : ${path_config}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在更新底包镜像...${RESET}"
    docker pull lswl/vertex-base:latest
    echo -e "${YELLOW}正在拉取最新 Vertex 主程序镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！主容器已安全重启并保持最新状态。${RESET}"
}

# 卸载 Vertex
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 Vertex 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地配置和所有刷流数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}Vertex 主配置与全部数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_translate() { docker logs -f --tail=100 "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}核心镜像       : ${img_version}${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}默认用户名     : admin${RESET}"
    echo -e "${YELLOW}系统初始密码   : ${CYAN}${v_password}${RESET}"
    echo -e "${YELLOW}宿主机配置路径 : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}◈  Vertex  自动化刷流管理面板  ◈ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态    :${RESET} $status"
    echo -e "${GREEN}Web端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
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
