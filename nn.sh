#!/bin/bash
# =================================================================
# OpenList 聚合网盘/文件列表工具 Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="openlist"
BASE_DIR="/opt/openlist"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取当前系统用户的 UID 和 GID 作为默认安全权限
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)

# 动态获取容器状态、映射端口和各数据目录
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中精准提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 提取 WebUI 映射出来的宿主机端口 (内部默认 5244)
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "5244/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="5244"

        # 提取宿主机数据保存目录
        path_data_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/opt/openlist/data"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$path_data_show" ]] && path_data_show="$BASE_DIR/data"

        # 【核心优化】自动从日志中实时过滤提取初始密码
        init_password=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -i "initial password is:" | awk -F': ' '{print $2}' | tr -d '\r\n ')
        [[ -z "$init_password" ]] && init_password="[ 未在日志中匹配到初始密码，可能你已修改 ]"
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        path_data_show="N/A"
        init_password="N/A"
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

    echo -e "${CYAN}====== OpenList 参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 WebUI 访问映射端口 (宿主机) [默认: 5244]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="5244"

    echo -e "\n${CYAN}--- 运行权限配置 (User ID : Group ID) ---${RESET}"
    echo -ne "${YELLOW}请输入运行容器的用户 UID [默认当前用户: ${CURRENT_UID}]: ${RESET}"
    read -r custom_uid
    [[ -z "$custom_uid" ]] && custom_uid="${CURRENT_UID}"

    echo -ne "${YELLOW}请输入运行容器的用户组 GID [默认当前用户组: ${CURRENT_GID}]: ${RESET}"
    read -r custom_gid
    [[ -z "$custom_gid" ]] && custom_gid="${CURRENT_GID}"

    echo -e "\n${CYAN}--- 宿主机目录自定义 (建议填写绝对路径) ---${RESET}"
    echo -ne "${YELLOW}请输入数据持久化保存路径 [默认: $BASE_DIR/data]: ${RESET}"
    read -r path_data
    [[ -z "$path_data" ]] && path_data="$BASE_DIR/data"

    # 自动创建所需目录并授权
    echo -e "\n${YELLOW}正在初始化并检查宿主机目录权限...${RESET}"
    mkdir -p "$path_data"
    # 如果指定非 root 用户运行，确保该用户对挂载目录有所有权
    if [ "$custom_uid" != "0" ]; then
        chown -R "$custom_uid":"$custom_gid" "$path_data"
    fi
    chmod -R 755 "$BASE_DIR" "$path_data"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  openlist:
    image: 'openlistteam/openlist:latest'
    container_name: ${CONTAINER_NAME}
    user: '${custom_uid}:${custom_gid}'
    volumes:
      - '${path_data}:/opt/openlist/data'
    ports:
      - '${custom_port}:5244'
    environment:
      - UMASK=022
    restart: unless-stopped
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 启动 OpenList 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务初始化 (约 3 秒)...${RESET}"
    sleep 3


    echo -e "${YELLOW}等待服务容器初始化完成并输出密码 (约 5 秒)...${RESET}"
    sleep 5

    # 刷新状态从而提取密码
    get_status_info
    DETECT_IP=$(get_public_ip)
    
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             OpenList 部署成功！        ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}WEB 访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}默认用户名     : admin${RESET}"
    echo -e "${YELLOW}系统初始密码   : ${CYAN}${init_password}${RESET}"
    echo -e "${YELLOW}数据保存路径   : ${path_data}${RESET}"
    echo -e "${YELLOW}提示: 建议首次登录后立即前往后台修改此初始密码。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 OpenList 官方镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已成功安全重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 OpenList 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地保存的数据及配置文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$path_data_show" != "$BASE_DIR"* && -d "$path_data_show" ]] && rm -rf "$path_data_show"
                echo -e "${GREEN}所有相关的网盘配置和缓存数据已彻底清理。${RESET}"
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
    echo -e "${YELLOW}数据保存路径   : ${path_data_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}◈OpenList 聚合网盘自动化管理面板◈ ${RESET}"
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
