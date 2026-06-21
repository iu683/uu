#!/bin/bash
# =================================================================
# DDNS-Go 动态域名解析服务 Docker Compose 独立管理面板 (支持 Host 模式)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="ddns-go"
BASE_DIR="/opt/ddns-go"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态与网络/端口模式
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
        [[ -z "$img_version" ]] && img_version="jeessy/ddns-go:latest"
        
        # 检测是否为 host 网络模式
        local net_mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME" 2>/dev/null)
        if [ "$net_mode" = "host" ]; then
            port_display="Host 模式共享宿主机 (默认 9876)"
        else
            # 动态抓取映射到容器 9876 端口的宿主机实际端口
            webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "9876/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
            [[ -z "$webui_port" ]] && webui_port="9876"
            port_display="${webui_port} (Bridge 模式)"
        fi
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

# 部署 DDNS-Go
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 目录挂载自定义配置 ======${RESET}"
    echo -e "${YELLOW}提示: 直接回车将默认采用标准路径 $BASE_DIR 文件夹进行直挂。${RESET}"
    
    echo -ne "${YELLOW}请输入数据本地挂载路径 [默认: $BASE_DIR]: ${RESET}"
    read -r input_data
    local real_path_data="${input_data:-$BASE_DIR}"
    real_path_data=$(get_real_path "$real_path_data" "$BASE_DIR")

    # 预创建物理目录并穿透赋权
    mkdir -p "$real_path_data"
    chmod -R 777 "$real_path_data"

    echo -e "\n${CYAN}====== 2. 网络模式配置 (Host / Bridge) ======${RESET}"
    echo -e "${YELLOW}提示: 强烈推荐 Host 模式，能直通宿主机网络，完美获取本地 IPv6 地址。${RESET}"
    echo -ne "${GREEN}是否启用 Host 网络模式？(y/n) [默认: y]: ${RESET}"
    read -r net_choice
    [[ -z "$net_choice" ]] && net_choice="y"

    local net_block=""
    local port_block=""
    local final_port="9876"

    if [[ "$net_choice" == "y" || "$net_choice" == "Y" ]]; then
        # Host 模式配置
        net_block="network_mode: \"host\""
        port_block=""
        final_port="9876"
        echo -e "${GREEN}已选择 Host 网络模式（将直接使用宿主机 9876 端口）${RESET}"
    else
        # Bridge 模式配置，允许自定端口
        net_block=""
        echo -ne "${YELLOW}请输入 DDNS-Go 宿主机 WebUI 访问端口 [默认: 9876]: ${RESET}"
        read -r custom_port
        [[ -z "$custom_port" ]] && custom_port="9876"
        if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
            return
        fi
        port_block="ports:
      - \"${custom_port}:9876\""
        final_port="$custom_port"
        echo -e "${GREEN}已选择 Bridge 网络模式（映射端口: ${custom_port}）${RESET}"
    fi

    # 动态生成纯净版 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成原生直挂版 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  ddns-go:
    image: jeessy/ddns-go:latest
    container_name: ${CONTAINER_NAME}
    restart: always
    ${net_block}
    ${port_block}
    volumes:
      - ${real_path_data}:/root
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 DDNS-Go...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}         DDNS-Go 部署成功！       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WebUI 管理后台   : http://${DETECT_IP}:${final_port}${RESET}"
    echo -e "${YELLOW}本地配置挂载路径 : ${real_path_data}${RESET}"
    echo -e "${YELLOW}配置文件路径     : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 DDNS-Go 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 DDNS-Go 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 DDNS-Go
uninstall_utils() {
    echo -e "${RED}警告: 卸载如果清理数据，将永久丢失您配置的 DNS 服务商 Token 及域名同步列表！${RESET}"
    echo -ne "${YELLOW}确定要卸载并删除 DDNS-Go 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}【高风险】是否同时彻底删除本地全量挂载的域名解析配置？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有 DDNS-Go 配置文件已被彻底销毁。${RESET}"
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
    echo -e "${YELLOW}当前网络/端口  : ${port_display}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  DDNS-Go 管理面板  ◈     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}网络 :${RESET} ${YELLOW}${port_display}${RESET}"
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
