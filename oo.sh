#!/bin/bash
# =================================================================
# Conflux (Mihomo) 工具箱 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="Mihomo"
BASE_DIR="/opt/conflux"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 生成随机字符串 (用于 JWT_SECRET 兜底)
generate_secret() {
    if command -v openssl &> /dev/null; then
        openssl rand -hex 16
    else
        echo "conflux_secret_$(date +%s)"
    fi
}

# 动态获取容器状态、映射端口
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

        # 提取 WebUI 端口 (容器内 80 端口映射到宿主机的端口)
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="未映射"

        # 提取 Proxy 端口 (容器内 7890 端口映射到宿主机的端口)
        proxy_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "7890/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$proxy_port" ]] && proxy_port="未映射"
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        proxy_port="N/A"
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

# 部署 Conflux
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 配置 WEB 端口
    echo -ne "${YELLOW}请输入 Web 面板访问端口 [默认: 8080]: ${RESET}"
    read -r custom_web_port
    [[ -z "$custom_web_port" ]] && custom_web_port="8080"
    if ! [[ "$custom_web_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 配置 PROXY 端口
    echo -ne "${YELLOW}请输入 Proxy 代理服务端口 [默认: 7890]: ${RESET}"
    read -r custom_proxy_port
    [[ -z "$custom_proxy_port" ]] && custom_proxy_port="7890"
    if ! [[ "$custom_proxy_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 配置管理员密码
    echo -ne "${YELLOW}请输入 Web 面板管理员密码 [默认: admin123]: ${RESET}"
    read -r admin_pass
    [[ -z "$admin_pass" ]] && admin_pass="admin123"

    # 生成 JWT 密钥
    jwt_secret=$(generate_secret)

    # 1. 动态生成 .env 配置文件
    echo -e "${YELLOW}正在写入环境变量配置文件 (.env)...${RESET}"
    cat <<EOF > "$ENV_FILE"
WEB_PORT=${custom_web_port}
PROXY_PORT=${custom_proxy_port}
JWT_SECRET=${jwt_secret}
ADMIN_PASS=${admin_pass}
EOF

    # 2. 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  conflux:
    image: veildawn/conflux:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "\${WEB_PORT}:80"
      - "\${PROXY_PORT}:7890"
    environment:
      - JWT_SECRET=\${JWT_SECRET}
      - ADMIN_PASSWORD=\${ADMIN_PASS}
    volumes:
      - conflux-config:/app/mihomo/config
      - conflux-data:/app/backend/data

volumes:
  conflux-config:
  conflux-data:
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Conflux 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN}             Conflux 部署成功！                 ${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW}Web 面板地址   : http://${DETECT_IP}:${custom_web_port}${RESET}"
    echo -e "${YELLOW}管理账号       : admin${RESET}"
    echo -e "${YELLOW}管理密码       : ${admin_pass}${RESET}"
    echo -e "${YELLOW}Proxy 代理端口  : ${custom_proxy_port}${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================================${RESET}"
}

# 更新 Conflux 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Conflux 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 Conflux
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 Conflux 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地配置文件与持久化数据卷？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                # 下线并清除关联的命名卷
                cd "$BASE_DIR" && docker compose down -v
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置目录及数据卷已彻底清理。${RESET}"
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
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}Web 面板地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}Proxy 代理端口 : ${proxy_port}${RESET}"
    echo -e "${YELLOW}管理账号       : admin${RESET}"
    echo -e "${YELLOW}管理密码       : ${admin_pass}${RESET}"
    echo -e "${GREEN}================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Conflux 管理面板  ◈     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}WebUI:${RESET} ${YELLOW}${webui_port}${RESET}"  
    echo -e "${GREEN}Proxy:${RESET} ${YELLOW}${proxy_port}${RESET}"
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
