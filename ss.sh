#!/bin/bash
# =================================================================
# ghproxy & Smart-Git 独立/伴生服务 Docker Compose 独立管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/github-proxy"
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
    # 检查 ghproxy
    if [ "$(docker ps -q -f name=^/ghproxy$)" ]; then
        gh_status="${GREEN}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/ghproxy$)" ]; then
        gh_status="${RED}已停止${RESET}"
    else
        gh_status="${RED}未部署${RESET}"
    fi

    # 检查 smart-git
    if [ "$(docker ps -q -f name=^/smart-git$)" ]; then
        git_status="${GREEN}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/smart-git$)" ]; then
        git_status="${RED}已停止${RESET}"
    else
        git_status="${RED}未部署${RESET}"
    fi

    # 动态抓取 ghproxy 映射到容器 8080 端口的宿主机实际端口
    if [ "$(docker ps -aq -f name=^/ghproxy$)" ]; then
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "ghproxy" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="7210"
        port_display="${webui_port}"
    else
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

# 部署服务
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 目录挂载自定义配置 ======${RESET}"
    echo -e "${YELLOW}提示: 直接回车将默认采用脚本同级路径下的文件夹(即 ./ghproxy/ 和 ./smart-git/)。${RESET}"
    
    echo -ne "${YELLOW}请输入数据根挂载路径 [默认: ./]: ${RESET}"
    read -r input_data
    local path_root_raw="${input_data:-./}"
    
    # 动态预计算物理绝对路径
    local real_gh_log=$(get_real_path "${path_root_raw%/}/ghproxy/log" "./ghproxy/log")
    local real_gh_conf=$(get_real_path "${path_root_raw%/}/ghproxy/config" "./ghproxy/config")

    echo -e "${YELLOW}正在宿主机预构建并穿透赋权 ghproxy 物理目录...${RESET}"
    mkdir -p "$real_gh_log" "$real_gh_conf"
    chmod -R 777 "$real_gh_log" "$real_gh_conf"

    echo -e "\n${CYAN}====== 2. 可选伴生组件配置 ======${RESET}"
    echo -ne "${GREEN}是否需要同时安装 Smart-Git 服务？(y/n) [默认: n]: ${RESET}"
    read -r install_git
    [[ -z "$install_git" ]] && install_git="n"

    # 如果需要安装 smart-git，为其预创建目录
    local real_git_log="" real_git_conf="" real_git_repos="" real_git_db=""
    if [[ "$install_git" == "y" || "$install_git" == "Y" ]]; then
        real_git_log=$(get_real_path "${path_root_raw%/}/smart-git/log" "./smart-git/log")
        real_git_conf=$(get_real_path "${path_root_raw%/}/smart-git/config" "./smart-git/config")
        real_git_repos=$(get_real_path "${path_root_raw%/}/smart-git/repos" "./smart-git/repos")
        real_git_db=$(get_real_path "${path_root_raw%/}/smart-git/db" "./smart-git/db")

        echo -e "${YELLOW}正在宿主机预构建并穿透赋权 Smart-Git 物理目录...${RESET}"
        mkdir -p "$real_git_log" "$real_git_conf" "$real_git_repos" "$real_git_db"
        chmod -R 777 "$real_git_log" "$real_git_conf" "$real_git_repos" "$real_git_db"
    fi

    echo -e "\n${CYAN}====== 3. 网络端口与访问配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 ghproxy 宿主机外部访问端口 [默认: 7210]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="7210"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 动态组装 docker-compose.yml 文本
    echo -e "${YELLOW}正在生成高阶分流版 docker-compose.yml...${RESET}"
    
    # 基础 ghproxy 模块
    cat <<EOF > "$COMPOSE_FILE"
services:
  ghproxy:
    image: wjqserver/ghproxy:latest
    container_name: ghproxy
    restart: always
    ports:
      - "${custom_port}:8080"
    volumes:
      - ${path_root_raw%/}/ghproxy/log:/data/ghproxy/log
      - ${path_root_raw%/}/ghproxy/config:/data/ghproxy/config
EOF

    # 伴生可选 smart-git 模块追加
    if [[ "$install_git" == "y" || "$install_git" == "Y" ]]; then
        cat <<EOF >> "$COMPOSE_FILE"
  smart-git:
    image: wjqserver/smart-git:latest
    container_name: smart-git
    restart: always
    volumes:
      - ${path_root_raw%/}/smart-git/log:/data/smart-git/log
      - ${path_root_raw%/}/smart-git/config:/data/smart-git/config
      - ${path_root_raw%/}/smart-git/repos:/data/smart-git/repos
      - ${path_root_raw%/}/smart-git/db:/data/smart-git/db
EOF
    fi

    echo -e "${YELLOW}正在通过 Docker Compose 启动容器服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器群组初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}         服务集群部署成功！       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}ghproxy 加速访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    if [[ "$install_git" == "y" || "$install_git" == "Y" ]]; then
        echo -e "${GREEN}Smart-Git 伴生组件   : [已成功捆绑启动并挂载挂载点]${RESET}"
    else
        echo -e "${RED}Smart-Git 伴生组件   : [已跳过安装，保持环境纯净]${RESET}"
    fi
    echo -e "${YELLOW}配置文件路径         : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像群
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像群组...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！所有已安装的组件都已处于最新状态。${RESET}"
}

# 卸载集群
uninstall_utils() {
    echo -e "${RED}警告: 卸载如果清理数据，将永久丢失你拉取同步的所有本地仓库和日志配置！${RESET}"
    echo -ne "${YELLOW}确定要下线并彻底删除此集群内的所有容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}所有相关容器已安全下线。${RESET}"
            echo -ne "${RED}【高风险】是否同时彻底删除本地全量挂载的仓库、配置与日志数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地物理全量数据及缓存已被彻底销毁。${RESET}"
            fi
        else
            docker rm -f ghproxy smart-git 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}群组内已安装容器已全部拉起${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}群组内已安装容器已全部挂起停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}群组内已安装容器已全部完成重启${RESET}"; }
logs_utils() {
    echo -e "${CYAN}1. 查看 ghproxy 日志${RESET}"
    echo -e "${CYAN}2. 查看 smart-git 日志${RESET}"
    echo -ne "${GREEN}请输入想要查看日志的容器编号: ${RESET}"
    read -r log_choice
    if [ "$log_choice" = "1" ]; then
        docker logs -f ghproxy
    elif [ "$log_choice" = "2" ]; then
        docker logs -f smart-git
    else
        echo -e "${RED}无效输入，返回主菜单。${RESET}"
    fi
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===============================================${RESET}"
    echo -e "${GREEN}     ◈  ghproxy & Smart-Git 管理面板  ◈     ${RESET}"
    echo -e "${GREEN}===============================================${RESET}"
    echo -e "${GREEN}ghproxy 状态   :${RESET} $gh_status"
    echo -e "${GREEN}Smart-Git 状态 :${RESET} $git_status"
    echo -e "${GREEN}ghproxy 映射口 :${RESET} ${YELLOW}${port_display}${RESET}"
    echo -e "${GREEN}===============================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}===============================================${RESET}"
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
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
