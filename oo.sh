#!/bin/bash
# =================================================================
# Remio Home 个人主页服务 Docker Compose 独立管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="remio-home"
BASE_DIR="/opt/remio-home"
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
        [[ -z "$img_version" ]] && img_version="kasuie/remio-home:latest"
        
        # 动态抓取映射到容器 3000 端口的宿主机实际端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3000"
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

# 部署 Remio Home
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 基础持久化目录初始化 ======${RESET}"
    echo -e "${YELLOW}正在自动创建必要的挂载目录 (config / icons)...${RESET}"
    
    # 自动预创建配置和图标目录，并赋予满权限防止容器内读写失败
    mkdir -p "$BASE_DIR/config" "$BASE_DIR/icons"
    chmod -R 777 "$BASE_DIR/config" "$BASE_DIR/icons"
    echo -e "${GREEN}目录初始化完成。${RESET}"

    echo -e "\n${CYAN}====== 2. 网络端口与安全配置 ======${RESET}"
    
    # 允许自定义宿主机端口
    echo -ne "${YELLOW}请输入 Remio Home 宿主机访问端口 [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 自动生成强随机管理密码
    local default_pass=$(date +%s | sha256sum | base64 | head -c 16)
    echo -ne "${YELLOW}请设置您的后台管理密码 [默认随机生成]: ${RESET}"
    read -r admin_password
    [[ -z "$admin_password" ]] && admin_password="$default_pass"

    # 获取系统时区
    local current_tz=$(cat /etc/timezone 2>/dev/null || echo "Asia/Shanghai")

    # 动态生成符合规范的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成直挂版 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  remio-home:
    image: kasuie/remio-home:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${custom_port}:3000"
    environment:
      - TZ=${current_tz}
      - PASSWORD=${admin_password}
    volumes:
      - ./config:/remio-home/config
      - ./icons:/remio-home/public/icons
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Remio Home...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}            Remio Home 部署成功！                    ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}主页访问地址     : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}后台管理密码     : ${admin_password}${RESET}"
    echo -e "${YELLOW}自定义图标存放区 : $BASE_DIR/icons/${RESET}"
    echo -e "${YELLOW}配置文件存放区   : $BASE_DIR/config/${RESET}"
    echo -e "${YELLOW}配置文件路径     : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新 Remio Home 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Remio Home 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！Remio Home 已处于最新状态。${RESET}"
}

# 卸载 Remio Home
uninstall_utils() {
    echo -e "${RED}警告: 卸载如果清理数据，将永久丢失您的导航布局、配置及自定义图标！${RESET}"
    echo -ne "${YELLOW}确定要卸载并删除 Remio Home 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}【高风险】是否同时彻底删除本地全量配置与图标文件夹？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有 Remio Home 数据已被彻底销毁。${RESET}"
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
    # 从 docker-compose 提取出当前的密码以供健忘时查阅
    local saved_pass=$(grep 'PASSWORD=' "$COMPOSE_FILE" 2>/dev/null | cut -d'=' -f2)
    [[ -n "$saved_pass" ]] && echo -e "${YELLOW}配置的密码     : ${saved_pass}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}◈  Remio Home 个人主页管理面板 ◈  ${RESET}"
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
