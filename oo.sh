#!/bin/bash
# =================================================================
# Backrest 备份服务 Docker Compose 独立管理面板 (高级自定义挂载版)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="backrest"
BASE_DIR="/opt/backrest"
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
        [[ -z "$img_version" ]] && img_version="garethgeorge/backrest:latest"
        
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "9898/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="9898"
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


# 部署 Backrest
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 基础核心目录初始化 ======${RESET}"
    # 自动预创建核心相对目录
    for dir in data config cache tmp rclone; do
        mkdir -p "$BASE_DIR/$dir"
        chmod -R 777 "$BASE_DIR/$dir"
    done
    echo -e "${GREEN}基础核心目录准备完毕。${RESET}"

    echo -e "\n${CYAN}====== 2. 自定义备份目录挂载 ======${RESET}"
    echo -e "${YELLOW}提示: 你可以挂载多个宿主机上的任意目录到 Backrest 容器中进行备份。${RESET}"
    echo -ne "${YELLOW}你需要挂载几个备份目录？(请输入数字，默认 1): ${RESET}"
    read -r dir_count
    [[ -z "$dir_count" ]] && dir_count=1
    if ! [[ "$dir_count" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 输入必须是数字！${RESET}"
        return
    fi

    # 循环收集用户输入的待备份路径
    local volume_mappings=""
    local info_mappings=""
    
    for ((i=1; i<=dir_count; i++)); do
        while true; do
            echo -e "\n${CYAN}--- 目录 #$i 配置 ---${RESET}"
            echo -ne "${YELLOW}请输入宿主机待备份的【绝对路径】(例如 /var/www 或 /home/data): ${RESET}"
            read -r host_path
            
            if [ -z "$host_path" ] || [[ "$host_path" != /* ]]; then
                echo -e "${RED}错误: 路径不能为空，且必须是以 / 开头的绝对路径！${RESET}"
                continue
            fi
            
            if [ ! -d "$host_path" ]; then
                echo -e "${YELLOW}警告: 宿主机中不存在目录 [$host_path]，是否自动创建？(y/n): ${RESET}"
                read -r create_dir
                if [[ "$create_dir" == "y" || "$create_dir" == "Y" ]]; then
                    mkdir -p "$host_path"
                else
                    echo -e "${RED}请重新输入存在的路径。${RESET}"
                    continue
                fi
            fi
            
            echo -ne "${YELLOW}请为该目录命名一个容器内的代号 (英文/数字，例如 www 或 media): ${RESET}"
            read -r container_slug
            if [[ ! "$container_slug" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                echo -e "${RED}错误: 代号只能包含英文、数字、下划线或中划线！${RESET}"
                continue
            fi
            
            echo -ne "${YELLOW}是否以只读(ro)模式挂载以保护源文件安全？(y/n，默认 y): ${RESET}"
            read -r is_ro
            local ro_flag=":ro"
            [[ "$is_ro" == "n" || "$is_ro" == "N" ]] && ro_flag=""

            # 拼接 compose 卷格式
            volume_mappings="${volume_mappings}\n      - ${host_path}:/backup/${container_slug}${ro_flag}"
            info_mappings="${info_mappings}\n${YELLOW} -> 映射成功: ${host_path}  -->  容器内路径: /backup/${container_slug} (${ro_flag#:})${RESET}"
            break
        done
    done

    echo -e "\n${CYAN}====== 3. 网络端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Backrest 宿主机访问端口 [默认: 9898]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="9898"

    local current_tz=$(cat /etc/timezone 2>/dev/null || echo "Asia/Shanghai")

    # 动态生成符合格式的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成高级自定义挂载版 docker-compose.yml...${RESET}"
    
    # 构建基础模板文本
    cat <<EOF > "$COMPOSE_FILE"
services:
  backrest:
    image: garethgeorge/backrest:latest
    container_name: ${CONTAINER_NAME}
    hostname: ${CONTAINER_NAME}
    restart: always
    ports:
      - "${custom_port}:9898"
    volumes:
      - ./data:/data
      - ./config:/config
      - ./cache:/cache
      - ./tmp:/tmp
      - ./rclone:/root/.config/rclone$(echo -e "$volume_mappings")
    environment:
      - BACKREST_DATA=/data
      - BACKREST_CONFIG=/config/config.json
      - XDG_CACHE_HOME=/cache
      - TMPDIR=/tmp
      - TZ=${current_tz}
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Backrest...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}              Backrest 部署成功！                    ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}WebUI 访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}提示             : 首次访问请按照网页提示设置账户密码${RESET}"
    echo -e "${CYAN}挂载的备份目录清单:$(echo -e "$info_mappings")${RESET}"
    echo -e "${YELLOW}提示             : 在 Backrest 网页端配置备份时，请直接填写对应的【容器内路径】。${RESET}"
    echo -e "${YELLOW}配置文件路径     : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新 Backrest 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Backrest 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！Backrest 已处于最新状态。${RESET}"
}

# 卸载 Backrest
uninstall_utils() {
    echo -e "${RED}警告: 卸载如果清理数据，将永久丢失您的备份计划及缓存（但不会损坏您宿主机上的源备份目录）！${RESET}"
    echo -ne "${YELLOW}确定要卸载并删除 Backrest 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}【高风险】是否彻底删除 Backrest 的配置、缓存与管理数据库？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}Backrest 核心管理数据已被彻底销毁。${RESET}"
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
    echo -e "${GREEN}    ◈  Backrest 备份管理面板  ◈  ${RESET}"
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
