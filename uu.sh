#!/bin/bash
# =================================================================
# magic-resume 简历生成器 (源码克隆 + 端口定制 + 现场 Build) 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

APP_NAME="magic-resume-web"
BASE_DIR="/opt/magic-resume"
SRC_DIR="$BASE_DIR"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
# 使用 HTTPS 链接克隆，比 SSH (git@github.com...) 兼容性更好，免去配置 SSH Key 的麻烦
REPO_URL="https://github.com/JOYCEQL/magic-resume.git"

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

# 动态获取服务端口与运行状态
get_status_info() {
    local container_id=$(docker ps -q -f "name=web" -f "status=running" 2>/dev/null)
    [[ -z "$container_id" ]] && container_id=$(docker ps -q -f "ancestor=magic-resume-web" -f "status=running" 2>/dev/null)

    if [[ -n "$container_id" ]]; then
        status="${GREEN}运行中 (容器已就绪)${RESET}"
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "$container_id" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3000"
    else
        if [ -d "$SRC_DIR/.git" ]; then
            status="${RED}已停止${RESET}"
        else
            status="${RED}未部署${RESET}"
        fi
        webui_port="N/A"
    fi
}

get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
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


# 部署与现场编译
install_resume() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 magic-resume 网页端访问映射端口 [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"

    # 克隆官方仓库到当前工作目录
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "\n${YELLOW}正在从 GitHub 远程仓库克隆官方最新源码...${RESET}"
        git clone "$REPO_URL" "$SRC_DIR/tmp_repo"
        if [ $? -eq 0 ]; then
            mv "$SRC_DIR/tmp_repo/"* "$SRC_DIR/" 2>/dev/null
            mv "$SRC_DIR/tmp_repo/."* "$SRC_DIR/" 2>/dev/null
            rm -rf "$SRC_DIR/tmp_repo"
        else
            echo -e "${RED}错误: 仓库克隆失败，请检查网络！${RESET}"
            exit 1
        fi
    else
        echo -e "\n${GREEN}检测到本地已存在官方仓库，正在同步最新代码...${RESET}"
        cd "$SRC_DIR" && git pull
    fi

    # 回到仓库根目录
    cd "$SRC_DIR"

    # 动态注入并覆盖生成带自定义端口的 docker-compose.yml
    echo -e "${YELLOW}正在注入端口参数并生成配置...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  web:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: ${APP_NAME}
    ports:
      - "${custom_port}:3000"
    environment:
      - NODE_ENV=production
    restart: always
EOF

    # 完美对齐官方启动命令并开始 build
    echo -e "\n${YELLOW}正在拉起 Docker 现场编译 (Node.js 编译较慢，请耐心等待)...${RESET}"
    docker compose up -d --build

    echo -e "${YELLOW}正在等待容器集群 Build 编译完成 (约 5 秒)...${RESET}"
    sleep 5

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}        magic-resume 官方源码编译并启动成功！        ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}默认访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}源码及工作区 : ${SRC_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新代码并重新 Build
update_resume() {
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "${RED}错误: 未检测到克隆的仓库，请先执行选项 1！${RESET}"
        return
    fi
    get_status_info
    local current_port=$webui_port
    [[ "$current_port" == "N/A" ]] && current_port="3000"

    echo -e "${YELLOW}正在同步最新的远程官方代码...${RESET}"
    cd "$SRC_DIR" && git pull
    
    echo -e "${YELLOW}正在重新编译前端镜像并热更新...${RESET}"
    docker compose up -d --build --remove-orphans
    echo -e "${GREEN}集群源码更新并重编完成！${RESET}"
}

# 彻底卸载
uninstall_resume() {
    echo -ne "${RED}确定要停止并卸载 magic-resume 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -d "$SRC_DIR/.git" ]; then
            cd "$SRC_DIR" && docker compose down --rmi local
            echo -e "${GREEN}容器与临时编译镜像已被安全移除。${RESET}"
            echo -ne "${YELLOW}是否同步清理本地克隆的【全部源码和配置文件】？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有源码已被彻底清除！${RESET}"
                exit 0
            fi
        else
            echo -e "${YELLOW}未检测到运行中的 compose 环境，跳过物理删除。${RESET}"
        fi
    fi
}

# 控制逻辑
start_resume() { cd "$SRC_DIR" && docker compose start && echo -e "${GREEN}服务已全面启动${RESET}"; }
stop_resume() { cd "$SRC_DIR" && docker compose stop && echo -e "${YELLOW}服务已安全停止${RESET}"; }
restart_resume() { cd "$SRC_DIR" && docker compose restart && echo -e "${GREEN}服务已平滑重启${RESET}"; }
logs_resume() { cd "$SRC_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}服务运行状态     : $status"
    echo -e "${YELLOW}前端访问地址     : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}部署管理模式     : 源码 Clone + 本地 Dockerfile 编译${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}   ◈  magic-resume 简历面板  ◈    ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}服务状态 :${RESET} $status"
    echo -e "${GREEN}服务端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_resume ;;
        2) update_resume ;;
        3) uninstall_resume ;;
        4) start_resume ;;
        5) stop_resume ;;
        6) restart_resume ;;
        7) logs_resume ;;
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
