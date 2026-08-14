#!/bin/bash
# =================================================================
# codex-helper Docker Compose 管理
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

APP_NAME="codex-helper"
BASE_DIR="/opt/codex-helper"
REPO_URL="git@github.com:zhoujun0601/codex-helper.git"

# 依赖检测
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

# 获取服务状态与映射端口
get_status_info() {
    local container_id
    container_id=$(docker ps -q -f "name=${APP_NAME}" -f "status=running" 2>/dev/null)

    if [[ -n "$container_id" ]]; then
        status="${GREEN}运行中${RESET}"
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$container_id" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8180"
    else
        if [ -d "$BASE_DIR/.git" ]; then
            status="${RED}已停止${RESET}"
        else
            status="${RED}未部署${RESET}"
        fi
        webui_port="N/A"
    fi
}

# 获取公网 IP (兼容 curl 与 wget)
get_public_ip() {
    local mode=${1:-"auto"}
    local ip=""

    fetch_url() {
        local url="$1"
        if command -v wget &>/dev/null; then
            wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null
        elif command -v curl &>/dev/null; then
            curl -s --max-time 3 -k "$url" 2>/dev/null
        fi
    }

    if [[ "$mode" == "v4" ]]; then
        for url in "[https://api.ipify.org](https://api.ipify.org)" "[https://4.ip.sb](https://4.ip.sb)" "[https://checkip.amazonaws.com](https://checkip.amazonaws.com)"; do
            ip=$(fetch_url "$url") && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "[https://api64.ipify.org](https://api64.ipify.org)" "[https://6.ip.sb](https://6.ip.sb)"; do
            ip=$(fetch_url "$url") && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "[https://api.ipify.org](https://api.ipify.org)" "[https://4.ip.sb](https://4.ip.sb)"; do
            ip=$(fetch_url "$url") && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "[https://api64.ipify.org](https://api64.ipify.org)" "[https://6.ip.sb](https://6.ip.sb)"; do
            ip=$(fetch_url "$url") && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
}

# 生成 docker-compose.yml 配置文件
generate_compose_file() {
    local port="$1"
    cat <<EOF> "$BASE_DIR/docker-compose.yml"
services:
  ${APP_NAME}:
    build: .
    image: ${APP_NAME}:latest
    container_name: ${APP_NAME}
    restart: unless-stopped
    ports:
      - "${port}:8080"
    volumes:
      - codex-helper-data:/data
    environment:
      LISTEN_ADDR: ":8080"

volumes:
  codex-helper-data:
EOF
}

# 部署启动逻辑
install_translate() {
    check_dependencies
    mkdir -p "$(dirname "$BASE_DIR")"

    echo -e "${CYAN}====== 1. 端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入映射端口 [默认: 8180]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8180"

    # 1. 克隆代码库
    if [ ! -d "$BASE_DIR/.git" ]; then
        echo -e "\n${YELLOW}正在克隆 GitHub 仓库 (${REPO_URL})...${RESET}"
        git clone "$REPO_URL" "$BASE_DIR"
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: 仓库克隆失败，请检查 SSH Key 或网络连接！${RESET}"
            exit 1
        fi
    else
        echo -e "\n${GREEN}检测到本地已存在仓库，正在同步最新代码...${RESET}"
        cd "$BASE_DIR" && git pull
    fi

    cd "$BASE_DIR" || exit 1

    # 2. 生成配置并构建拉起
    echo -e "${YELLOW}正在生成 docker-compose.yml 配置...${RESET}"
    generate_compose_file "$custom_port"

    echo -e "\n${YELLOW}正在执行 Docker Compose 编译与启动...${RESET}"
    docker compose up -d --build

    echo -e "${YELLOW}正在等待容器启动 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    local DETECT_IP
    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}        codex-helper 部署并启动成功！               ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}访问地址     : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}源码与配置路径 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 代码更新与重编
update_translate() {
    if [ ! -d "$BASE_DIR/.git" ]; then
        echo -e "${RED}错误: 未检测到部署源码，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    
    echo -e "${YELLOW}正在拉取最新代码...${RESET}"
    cd "$BASE_DIR" && git pull

    echo -e "${YELLOW}正在重新编译并重启容器...${RESET}"
    docker compose up -d --build
    echo -e "${GREEN}codex-helper 更新并重编完成！${RESET}"
}

# 彻底卸载
uninstall_translate() {
    echo -ne "${RED}确定要停止并卸载 codex-helper 吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if [ -d "$BASE_DIR" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器与关联网络已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否彻底删除代码文件与 Volume 数据卷？(y/n): ${RESET}"
            read -r clean_data
            if [[ "$clean_data" =~ ^[Yy]$ ]]; then
                docker volume rm codex-helper_codex-helper-data 2>/dev/null
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}所有源码与数据目录已彻底清理！${RESET}"
            fi
        else
            echo -e "${YELLOW}未检测到安装目录，跳过清理。${RESET}"
        fi
    fi
}

# 容器管理命令
start_translate() {
    if [ -d "$BASE_DIR" ]; then
        cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"
    else
        echo -e "${RED}未找到部署目录！${RESET}"
    fi
}

stop_translate() {
    if [ -d "$BASE_DIR" ]; then
        cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"
    else
        echo -e "${RED}未找到部署目录！${RESET}"
    fi
}

restart_translate() {
    if [ -d "$BASE_DIR" ]; then
        cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"
    else
        echo -e "${RED}未找到部署目录！${RESET}"
    fi
}

logs_translate() {
    if [ -d "$BASE_DIR" ]; then
        cd "$BASE_DIR" && docker compose logs -f --tail=100
    else
        echo -e "${RED}未找到部署目录！${RESET}"
    fi
}

show_info() {
    get_status_info
    local DETECT_IP
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}运行状态     : $status"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}   ◈  codex-helper 管理面板  ◈     ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}服务状态 :${RESET}$status"
    echo -e "${GREEN}映射端口 :${RESET}${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新重编${RESET}"
    echo -e "${GREEN}3. 卸载服务${RESET}"
    echo -e "${GREEN}4. 启动服务${RESET}"
    echo -e "${GREEN}5. 停止服务${RESET}"
    echo -e "${GREEN}6. 重启服务${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_translate ;;
        2) update_translate ;;
        3) uninstall_translate ;;
        4) start_translate ;;
        5) stop_translate ;;
        6) restart_translate ;;
        7) logs_translate ;;
        8) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "\n${YELLOW}按回车键继续...${RESET}"
    read -r
done
