#!/bin/bash
# =================================================================
# 2FAuth 2FA双因素令牌管理器 Docker Compose 独立管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="2fauth"
BASE_DIR="/opt/2fauth"
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
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止/无限重启(检查权限)${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 动态抓取映射到容器 8000 端口的宿主机实际端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="无法获取"
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
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

# 部署 2FAuth
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 目录挂载自定义配置 ======${RESET}"
    echo -e "${YELLOW}提示: 直接回车将默认采用脚本同级路径下的 data 文件夹。${RESET}"
    
    echo -ne "${YELLOW}请输入数据(data)本地挂载路径 [默认: ./data]: ${RESET}"
    read -r input_data
    local path_data_raw="${input_data:-./data}"
    local real_path_data=$(get_real_path "$path_data_raw" "./data")

    # 预创建物理目录
    mkdir -p "$real_path_data"
    
    # 【核心修复】将挂载目录权限放开，防止 2FAuth 镜像内的非 root 用户遇到 Permission denied
    chmod -R 777 "$real_path_data"

    echo -e "\n${CYAN}====== 2. 网络端口与访问 URL 配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 2FAuth 访问端口 [默认: 8082]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8082"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入外部访问的完整 URL [默认: http://${DETECT_IP}:${custom_port}]: ${RESET}"
    read -r input_url
    local app_url="${input_url:-http://${DETECT_IP}:${custom_port}}"

    # 自动生成 32 位 APP_KEY
    echo -e "${YELLOW}正在自动生成高强度 32 位底层数据隔离 APP_KEY...${RESET}"
    local random_app_key=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 32)

    # 动态生成纯净版 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成直挂本地版 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  2fauth:
    image: 2fauth/2fauth:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    volumes:
      - ${path_data_raw}:/2fauth
    ports:
      - "${custom_port}:8000"
    environment:
      - APP_NAME=我的2FA安全令牌
      - APP_URL=${app_url}
      - APP_KEY=${random_app_key}
      - TZ=Asia/Shanghai
      - CONTENT_SECURITY_POLICY=true
      - LOGIN_THROTTLE=5
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 2FAuth...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}         2FAuth 部署成功！       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : ${app_url}${RESET}"
    echo -e "${YELLOW}数据直挂路径   : ${real_path_data}${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${RED}警告: 生成的 APP_KEY 已直接写在 docker-compose.yml 中，后续切勿随意修改它，否则已存数据将无法解密！${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 2FAuth 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 2FAuth 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 2FAuth
uninstall_utils() {
    echo -e "${RED}高危警告: 卸载如果清理数据，将永久丢失您存储的所有两步验证令牌！${RESET}"
    echo -ne "${YELLOW}确定要卸载并删除 2FAuth 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}【极高风险】是否同时彻底删除本地全量两步验证数据库及密钥配置？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有令牌数据已被彻底销毁。${RESET}"
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
    if [ -f "$COMPOSE_FILE" ]; then
        local current_url=$(grep -E "\- APP_URL=" "$COMPOSE_FILE" | cut -d'=' -f2)
        local current_key=$(grep -E "\- APP_KEY=" "$COMPOSE_FILE" | cut -d'=' -f2)
        echo -e "${YELLOW}配置访问地址   : ${current_url}${RESET}"
        echo -e "${YELLOW}当前安全密钥   : ${current_key}${RESET}"
    fi
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}       ◈  2FAuth 管理面板  ◈     ${RESET}"
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
