#!/bin/bash
# =================================================================
# Xboard Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="xboard"
BASE_DIR="/opt/xboard"
COMPOSE_FILE="$BASE_DIR/docker-compose.yaml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! command -v git &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Git，请先安装 Git！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态
get_status_info() {
    if [ "$(docker ps -q -f name=xboard)" ]; then
        status="${YELLOW}运行中${RESET}"
        REAL_CONTAINER=$(docker ps --format "{{.Names}}" -f name=xboard | head -n 1)
    elif [ "$(docker ps -aq -f name=xboard)" ]; then
        status="${RED}已停止${RESET}"
        REAL_CONTAINER=$(docker ps -a --format "{{.Names}}" -f name=xboard | head -n 1)
    else
        status="${RED}未部署${RESET}"
        REAL_CONTAINER=""
    fi

    if [ -n "$REAL_CONTAINER" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$REAL_CONTAINER" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "7001/tcp") 0).HostPort}}' "$REAL_CONTAINER" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$REAL_CONTAINER" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="7001"
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

# 部署 Xboard（带模式选择）
install_utils() {
    check_dependencies
    
    if [ -d "$BASE_DIR" ] && [ -f "$COMPOSE_FILE" ]; then
        echo -e "${RED}提示: 检测到目录 $BASE_DIR 已存在配置文件！${RESET}"
        echo -ne "${YELLOW}是否覆盖重新部署？(y/n): ${RESET}"
        read -r re_confirm
        if [[ "$re_confirm" != "y" && "$re_confirm" != "Y" ]]; then
            return
        fi
    fi

    # 选择安装模式
    echo -e "${CYAN}====== 请选择 Xboard 安装模式 ======${RESET}"
    echo -e "${GREEN}1. 快速安装模式 (推荐：自动配置内置 SQLite + Redis)${RESET}"
    echo -e "${GREEN}2. 高级自定义安装 (高级用户：手动配置外部 MySQL/PostgreSQL 等)${RESET}"
    echo -ne "${YELLOW}请输入模式编号 [默认: 1]: ${RESET}"
    read -r install_mode
    [[ -z "$install_mode" ]] && install_mode="1"

    if [[ "$install_mode" != "1" && "$install_mode" != "2" ]]; then
        echo -e "${RED}错误: 无效的选择，退出安装。${RESET}"
        return
    fi

    # 1. 克隆代码库
    echo -e "${YELLOW}正在从远端克隆 Xboard (compose 分支)...${RESET}"
    rm -rf "$BASE_DIR" 
    git clone -b compose --depth 1 https://github.com/cedar2025/Xboard "$BASE_DIR"
    
    if [ ! -d "$BASE_DIR" ]; then
        echo -e "${RED}错误: 克隆 Xboard 仓库失败，请检查网络！${RESET}"
        return
    fi

    # 2. 准备配置文件
    cd "$BASE_DIR" || return
    if [ -f "compose.yaml" ]; then
        mv compose.yaml docker-compose.yaml
    elif [ -f "docker-compose.yml" ]; then
        mv docker-compose.yml docker-compose.yaml
    elif [ -f "compose.sample.yaml" ]; then
        cp compose.sample.yaml docker-compose.yaml
    elif [ -f "docker-compose.sample.yml" ]; then
        cp docker-compose.sample.yml docker-compose.yaml
    else
        echo -e "${RED}错误: 未找到任何 Docker Compose 模板文件！${RESET}"
        return
    fi

    # 3. 根据选择执行不同的安装向导
    if [[ "$install_mode" == "1" ]]; then
        # 快速模式
        echo -e "${CYAN}====== 快速模式参数配置 ======${RESET}"
        echo -ne "${YELLOW}请输入 Xboard 管理员邮箱 [默认: admin@demo.com]: ${RESET}"
        read -r admin_email
        [[ -z "$admin_email" ]] && admin_email="admin@demo.com"

        echo -e "${YELLOW}正在执行快速初始化安装...${RESET}"
        docker compose -f docker-compose.yaml run -it --rm \
            -e ENABLE_SQLITE=true \
            -e ENABLE_REDIS=true \
            -e ADMIN_ACCOUNT="$admin_email" \
            xboard php artisan xboard:install
    else
        # 高级自定义模式
        echo -e "${YELLOW}正在启动高级自定义安装向导...${RESET}"
        echo -e "${RED}注意：您需要在接下来的交互提示中，逐项手动输入您的数据库类型、地址及账号密码！${RESET}"
        sleep 2
        
        docker compose -f docker-compose.yaml run -it --rm \
            xboard php artisan xboard:install
    fi

    # 4. 启动核心服务
    echo -e "${YELLOW}正在通过 Docker Compose 启动 Xboard 服务...${RESET}"
    docker compose -f docker-compose.yaml up -d

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Xboard 部署成功！         ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:7001${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 Xboard 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Xboard 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose -f docker-compose.yaml pull
    docker compose -f docker-compose.yaml up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 Xboard
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 Xboard 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose -f docker-compose.yaml down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地配置文件与数据目录？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}整个 Xboard 工作目录已彻底清理。${RESET}"
            fi
        else
            REAL_CONTAINER=$(docker ps -a --format "{{.Names}}" -f name=xboard | head -n 1)
            [[ -n "$REAL_CONTAINER" ]] && docker rm -f "$REAL_CONTAINER" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose -f docker-compose.yaml start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose -f docker-compose.yaml stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose -f docker-compose.yaml restart && echo -e "${GREEN}容器已重启${RESET}"; }

logs_utils() { 
    REAL_CONTAINER=$(docker ps -a --format "{{.Names}}" -f name=xboard | head -n 1)
    if [ -n "$REAL_CONTAINER" ]; then
        docker logs -f "$REAL_CONTAINER"
    else
        echo -e "${RED}未找到相关容器！${RESET}"
    fi
}

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:7001${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Xboard  管理面板  ◈     ${RESET}"
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
