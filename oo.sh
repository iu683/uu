#!/bin/bash
# =================================================================
# Vaultwarden (Bitwarden) 密码管理器 Docker Compose 独立管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="vaultwarden"
BASE_DIR="/opt/vaultwarden"
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
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="11001"
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

# 部署 Vaultwarden
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 安全与域名配置 ======${RESET}"
    echo -e "${YELLOW}提示: Vaultwarden 必须搭配 HTTPS（如通过 Nginx/Lucky 反代）才能在浏览器扩展和 App 中正常填充！${RESET}"
    
    # 1. 配置外部反代域名
    echo -ne "${YELLOW}请输入准备使用的反向代理域名 (例如 https://pwd.example.com) [若暂无请直接回车]: ${RESET}"
    read -r custom_domain

    # 2. 是否允许注册开关
    echo -ne "${YELLOW}当前是否允许新用户注册账户？(y/n) [默认: y]: ${RESET}"
    read -r signup_choice
    local signups_allowed="true"
    if [[ "$signup_choice" == "n" || "$signup_choice" == "N" ]]; then
        signups_allowed="false"
    fi

    echo -e "\n${CYAN}====== 2. 目录与网络端口配置 ======${RESET}"
    # 3. 数据持久化路径
    echo -ne "${YELLOW}请输入密码数据库(vw-data)本地挂载路径 [默认: ./vw-data]: ${RESET}"
    read -r input_data
    local path_data_raw="${input_data:-./vw-data}"
    local real_path_data=$(get_real_path "$path_data_raw" "./vw-data")

    # 预创建目录防权限错乱
    mkdir -p "$real_path_data"

    # 4. 端口配置
    echo -ne "${YELLOW}请输入 Vaultwarden 访问端口 [默认: 11001]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="11001"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 组装环境变量部分
    local env_strings="      - SIGNUPS_ALLOWED=${signups_allowed}"
    if [[ -n "$custom_domain" ]]; then
        env_strings="${env_strings}
      - DOMAIN=${custom_domain}"
    fi

    # 动态生成规范的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成规范的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: ${CONTAINER_NAME}
    restart: always
    environment:
${env_strings}
    volumes:
      - ${path_data_raw}:/data
    ports:
      - "${custom_port}:80"
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Vaultwarden...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}        Vaultwarden 部署成功！    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}本地局域网地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    if [[ -n "$custom_domain" ]]; then
        echo -e "${YELLOW}配置外部域名   : ${custom_domain}${RESET}"
    fi
    echo -e "${YELLOW}公共注册开关   : ${signups_allowed} (自己注册完后记得选1或改配置关掉注册)${RESET}"
    echo -e "${YELLOW}数据库挂载路径 : ${real_path_data}${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 Vaultwarden 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Vaultwarden 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 Vaultwarden
uninstall_utils() {
    echo -e "${RED}高危警告: 卸载如果清理数据，将永久丢失您存储的所有账号密码！${RESET}"
    echo -ne "${YELLOW}确定要卸载并删除 Vaultwarden 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            
            # 密码数据二次确认安全锁
            echo -ne "${RED}【极高风险】是否同时彻底删除本地全部密码数据库及附件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                echo -ne "${RED}请再次输入大写 'DELETE' 以确认销毁密码库: ${RESET}"
                read -r final_check
                if [ "$final_check" = "DELETE" ]; then
                    rm -rf "$BASE_DIR"
                    echo -e "${GREEN}本地密码数据已被彻底销毁。${RESET}"
                else
                    echo -e "${YELLOW}操作取消，保留了本地密码库数据。${RESET}"
                fi
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
    echo -e "${YELLOW}内部映射端口   : ${webui_port}${RESET}"
    if [ -f "$COMPOSE_FILE" ]; then
        local current_signup=$(grep -E "SIGNUPS_ALLOWED=" "$COMPOSE_FILE" | cut -d'=' -f2)
        echo -e "${YELLOW}当前公共注册   : ${current_signup}${RESET}"
    fi
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Vaultwarden 管理面板  ◈   ${RESET}"
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
