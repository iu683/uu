#!/bin/bash
# =================================================================
# Epusdt USDT 自動收款系統 Docker Compose 管理面板 
# =================================================================

# 顏色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="epusdt"
BASE_DIR="/opt/epusdt"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
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

        # 从容器状态提取 Web 端口
        webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8000"

        # 从容器状态提取数据目录（挂载路径）
        data_dir=$(docker inspect -f '{{range .Mounts}}{{.Source}}{{break}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$data_dir" ]] && data_dir="/opt/epusdt/data"
    else
        # 容器未安装/未部署时的返回值
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        data_dir="N/A"
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

# 检查环境是否已经部署
check_compose_exists() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return 1
    fi
    return 0
}

# 部署 Epusdt
install_epusdt() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 Epusdt 访问端口 (宿主机端口) [默认: 8000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8000"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入宿主机数据存储绝对路径 [默认: /opt/epusdt/data]: ${RESET}"
    read -r custom_data
    [[ -z "$custom_data" ]] && custom_data="/opt/epusdt/data"

    # 1. 创建所需的宿主机目录并赋予全权限（避免 SQLite 写入或生成 .env 时权限不足）
    mkdir -p "$custom_data"
    chmod -R 777 "$BASE_DIR" "$custom_data"

    # 2. 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  epusdt:
    image: gmwallet/epusdt:latest
    container_name: ${CONTAINER_NAME}
    restart: always
    environment:
      - EPUSDT_CONFIG=/data/.env
    ports:
      - "${custom_port}:8000"
    volumes:
      - ${custom_data}:/data
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Epusdt 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    local detect_ip
    detect_ip=$(get_public_ip)

    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${GREEN}                     Epusdt 部署成功！                          ${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${YELLOW}服务初始化访问地址: http://${detect_ip}:${custom_port}${RESET}"
    echo -e "${YELLOW}宿主机数据持久路径: $custom_data${RESET}"
    echo -e "${CYAN}----------------------------------------------------------------${RESET}"
    echo -e "${RED}⚠️  CRITICAL DOCKER INSTALLATION WARNING (防坑必读)：${RESET}"
    echo -e "${YELLOW}当您在浏览器中打开安装向导并填写参数时，请务必注意：${RESET}"
    echo -e "${RED}👉 http_bind_addr 必须修改填写为: 0.0.0.0${RESET}"
    echo -e "${RED}❌ 绝对不要保留默认的 127.0.0.1！${RESET}"
    echo -e "${YELLOW}原因: 如果保存为 127.0.0.1，容器重启后只会监听内部本地环回，${RESET}"
    echo -e "${YELLOW}      会导致 Docker 端口映射失效，您将无法从外部网络访问！${RESET}"
    echo -e "${CYAN}----------------------------------------------------------------${RESET}"
    echo -e "${GREEN}📝 网页安装向导主要字段：${RESET}"
    echo -e "${CYAN}   app_name / app_uri / http_bind_addr (填0.0.0.0) / http_bind_port${RESET}"
    echo -e "${CYAN}   runtime_root_path / log_save_path / order_expiration_time ...${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
}

# 更新 Epusdt 镜像
update_epusdt() {
    check_compose_exists || return
    echo -e "${YELLOW}正在从远端拉取 Epusdt 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 Epusdt
uninstall_epusdt() {
    echo -ne "${YELLOW}确定要卸载并删除 Epusdt 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件、.env 以及本地数据库？(y/n): ${RESET}"
            read -r clean_data
            if [[ "$clean_data" == "y" || "$clean_data" == "Y" ]]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$data_dir" != "N/A" ]] && rm -rf "$data_dir"
                echo -e "${GREEN}数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_epusdt() { 
    check_compose_exists || return
    cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"
}

stop_epusdt() { 
    check_compose_exists || return
    cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"
}

restart_epusdt() { 
    check_compose_exists || return
    cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"
}

logs_epusdt() { 
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        docker logs -f "$CONTAINER_NAME"
    else
        echo -e "${RED}错误: 容器不存在，无法查看日志！${RESET}"
    fi
}

show_info() {
    get_status_info
    local detect_ip="127.0.0.1"
    if [[ "$webui_port" != "N/A" ]]; then
        detect_ip=$(get_public_ip)
    fi
    
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${detect_ip}:${webui_port}${RESET}"
    echo -e "${YELLOW}宿主机数据路径 : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  Epusdt 管理面板  ◈      ${RESET}"
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
        1) install_epusdt ;;
        2) update_epusdt ;;
        3) uninstall_epusdt ;;
        4) start_epusdt ;;
        5) stop_epusdt ;;
        6) restart_epusdt ;;
        7) logs_epusdt ;;
        8) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

# 主循环
while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
