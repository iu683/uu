#!/bin/bash
# =================================================================
# Antigravity Manager Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="antigravity-manager"
BASE_DIR="/opt/antigravity-manager"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
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
        # 提取镜像名称/版本
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 从容器状态提取 WebUI 端口（容器内部监听的是 8045 端口）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8045/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        # 兜底获取第一个绑定的端口
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8045"

        # 从容器状态提取数据目录（挂载路径）
        data_dir=$(docker inspect -f '{{range .Mounts}}{{.Source}}{{break}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$data_dir" ]] && data_dir="~/.antigravity_tools"
    else
        # 容器未安装/未部署时的返回值
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        data_dir="N/A"
    fi
}

# 部署 Antigravity Manager
install_antigravity() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入服务访问端口 (宿主机端口) [默认: 8045]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8045"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入宿主机数据存储绝对路径 [默认: ~/.antigravity_tools]: ${RESET}"
    read -r custom_data
    [[ -z "$custom_data" ]] && custom_data="$HOME/.antigravity_tools"

    # WEB密码配置（非空）
    echo -ne "${YELLOW}请输入 WEB 管理密码 (WEB_PASSWORD): ${RESET}"
    read -r custom_password
    while [[ -z "$custom_password" ]]; do
        echo -e "${RED}错误: 密码不能为空，请重新输入！${RESET}"
        echo -ne "${YELLOW}请输入 WEB 管理密码 (WEB_PASSWORD): ${RESET}"
        read -r custom_password
    done

    # API_KEY 配置（支持高级随机生成，不随机则强制手动输入）
    echo -ne "${YELLOW}是否随机生成 sk- 格式的 API_KEY 密钥？(y/n) [默认: y]: ${RESET}"
    read -r gen_api_choice
    [[ -z "$gen_api_choice" ]] && gen_api_choice="y"

    if [[ "$gen_api_choice" == "y" || "$gen_api_choice" == "Y" ]]; then
        # 生成 sk-$(date +%s%N | sha256sum | head -c 15) 格式的高级随机密钥
        local random_hash
        random_hash=$(date +%s%N | sha256sum | head -c 15)
        local random_key="sk-${random_hash}"
        api_key_line="API_KEY=${random_key}"
        display_api_key="$random_key"
    else
        # 手动输入 API_KEY 并强校验非空
        echo -ne "${YELLOW}请输入您自定义的 API 调用密钥 (API_KEY): ${RESET}"
        read -r custom_api_key
        while [[ -z "$custom_api_key" ]]; do
            echo -e "${RED}错误: API 密钥不能为空，请重新输入！${RESET}"
            echo -ne "${YELLOW}请输入您自定义的 API 调用密钥 (API_KEY): ${RESET}"
            read -r custom_api_key
        done
        api_key_line="API_KEY=${custom_api_key}"
        display_api_key="$custom_api_key"
    fi

    # 1. 创建所需的宿主机目录
    mkdir -p "$custom_data"
    chmod -R 777 "$BASE_DIR" "$custom_data" 2>/dev/null

    # 2. 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  antigravity-manager:
    image: lbjlaq/antigravity-manager
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${custom_port}:8045"
    volumes:
      - ${custom_data}:/root/.antigravity_tools
    environment:
      - LOG_LEVEL=\${LOG_LEVEL:-info}
      - WEB_PASSWORD=${custom_password}
      - ${api_key_line}
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Antigravity Manager...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    local current_ip
    current_ip=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   Antigravity Manager 部署成功！  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${current_ip}:${custom_port}${RESET}"
    echo -e "${YELLOW}宿主机数据路径 : $custom_data${RESET}"
    echo -e "${YELLOW}Web 管理密码   : $custom_password${RESET}"
    echo -e "${YELLOW}当前 API KEY   : $display_api_key${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${CYAN}🔒 权限隔离安全提示：${RESET}"
    echo -e "${CYAN}1. Web 登录：必须使用 WEB_PASSWORD。输入 API Key 将被拒绝。${RESET}"
    echo -e "${CYAN}2. API 调用：请继续使用上面确定的 API KEY，确保管理与调用权限隔离。${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_antigravity() {
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
uninstall_antigravity() {
    echo -ne "${YELLOW}确定要卸载并删除 Antigravity Manager 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件和缓存数据？(y/n): ${RESET}"
            read -r clean_data
            if [[ "$clean_data" == "y" || "$clean_data" == "Y" ]]; then
                rm -rf "$BASE_DIR"
                # 兼容带有波浪号的路径解析
                eval local real_data_dir="$data_dir"
                if [ "$real_data_dir" != "N/A" ] && [ -d "$real_data_dir" ]; then
                    rm -rf "$real_data_dir"
                fi
                echo -e "${GREEN}数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
            echo -e "${GREEN}独立容器已强行移除。${RESET}"
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_antigravity() { 
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"
    else
        echo -e "${RED}错误: 未检测到配置文件，无法启动。${RESET}"
    fi
}

stop_antigravity() { 
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"
    else
        echo -e "${RED}错误: 未检测到配置文件，无法停止。${RESET}"
    fi
}

restart_antigravity() { 
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"
    else
        echo -e "${RED}错误: 未检测到配置文件，无法重启。${RESET}"
    fi
}

logs_antigravity() { 
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
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    if [[ "$webui_port" == "N/A" ]]; then
        echo -e "${YELLOW}服务访问地址   : N/A${RESET}"
    else
        echo -e "${YELLOW}服务访问地址   : http://${current_ip}:${webui_port}${RESET}"
    fi
    echo -e "${YELLOW}宿主机数据路径 : ${data_dir}${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${CYAN}🔒 权限隔离说明：${RESET}"
    echo -e "${CYAN}Web 登录专享 => $custom_password${RESET}"
    echo -e "${CYAN}API 调用专享 => $display_api_key${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈  Antigravity  管理面板  ◈    ${RESET}"
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
        1) install_antigravity ;;
        2) update_antigravity ;;
        3) uninstall_antigravity ;;
        4) start_antigravity ;;
        5) stop_antigravity ;;
        6) restart_antigravity ;;
        7) logs_antigravity ;;
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
