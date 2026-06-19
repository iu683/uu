#!/bin/bash
# =================================================================
# Subtracker 订阅管理 Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/subtracker"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
# 主要检查前端 web 容器的状态
CONTAINER_NAME="subtracker-web"
API_CONTAINER="subtracker-api"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口和数据目录
get_status_info() {
    # 1. 检查前端容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从前端容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取镜像名称/版本
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 从容器状态提取 WebUI 端口（前端容器内部默认监听的是 80 端口）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        # 兜底获取第一个绑定的端口
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8080"
        
        # 顺便获取当前 API 暴露的宿主机端口作为展示（从 API 容器提取环境参数中的 PORT 映射情况）
        api_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$API_CONTAINER" 2>/dev/null)
        [[ -z "$api_port" ]] && api_port="3001"
    else
        # 容器未安装/未部署时的返回值
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        api_port="N/A"
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

# 部署 Subtracker
install_subtracker() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 前端端口自定义
    echo -ne "${YELLOW}请输入 Subtracker 前端 Web 访问端口 [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 2. API 端口自定义
    echo -ne "${YELLOW}请输入 Subtracker 后端 API 监听端口 [默认: 3001]: ${RESET}"
    read -r custom_api_port
    [[ -z "$custom_api_port" ]] && custom_api_port="3001"
    if ! [[ "$custom_api_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 3. 路径与域名
    echo -ne "${YELLOW}请输入数据持久化存储绝对路径 [默认: /opt/subtracker/data]: ${RESET}"
    read -r custom_data
    [[ -z "$custom_data" ]] && custom_data="/opt/subtracker/data"

    echo -ne "${YELLOW}请输入该服务计划绑定的公网域名/本地访问地址 (例如: https://subtracker.example.com): ${RESET}"
    read -r web_origin
    [[ -z "$web_origin" ]] && web_origin="https://subtracker.example.com"

    # 1. 创建所需的宿主机目录
    mkdir -p "$custom_data"
    mkdir -p "$custom_data/logos"
    chmod -R 777 "$BASE_DIR" "$custom_data"

    # 2. 动态生成符合要求、且 API 端口可自定义的 docker-compose.yml
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  api:
    image: ghcr.io/smile-qwq/subtracker-api:latest
    container_name: ${API_CONTAINER}
    restart: unless-stopped
    ports:
      - "${custom_api_port}:${custom_api_port}"
    environment:
      PORT: ${custom_api_port}
      HOST: 0.0.0.0
      DATABASE_URL: file:/app/data/subtracker.db
      WEB_ORIGIN: ${web_origin}
      BASE_CURRENCY: CNY
      CRON_SCAN: "* * * * *"
      CRON_REFRESH_RATES: "0 2 * * *"
      LOG_LEVEL: warn
      DEFAULT_APP_LOCALE: zh-CN
      TZ: Asia/Shanghai
    volumes:
      - ${custom_data}:/app/data
      - ${custom_data}/logos:/app/apps/api/storage/logos

  web:
    image: ghcr.io/smile-qwq/subtracker-web:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    depends_on:
      - api
    ports:
      - "${custom_port}:80"
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Subtracker (API + Web)...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待前后端服务初始化 (约5秒)...${RESET}"
    sleep 5

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Subtracker 部署成功！     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}前端访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}后端 API 端口  : ${custom_api_port}${RESET}"
    echo -e "${YELLOW}宿主机数据路径 : $custom_data${RESET}"
    echo -e "${YELLOW}配置的前端域名 : $web_origin${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 Subtracker 镜像
update_subtracker() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Subtracker (API+Web) 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！所有容器已处于最新状态。${RESET}"
}

# 卸载 Subtracker
uninstall_subtracker() {
    echo -ne "${YELLOW}确定要卸载并删除 Subtracker 前后端容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}所有相关容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有订阅数据和图标缓存？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" "$API_CONTAINER" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_subtracker() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_subtracker() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_subtracker() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_subtracker() { cd "$BASE_DIR" && docker compose logs -f; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称(前端) : ${img_version}${RESET}"
    echo -e "${YELLOW}前端访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}后端 API 端口  : ${api_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Subtracker 管理面板  ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态     :${RESET} $status"
    echo -e "${GREEN}前端端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}API端口 :${RESET} ${YELLOW}${api_port}${RESET}"
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
        1) install_subtracker ;;
        2) update_subtracker ;;
        3) uninstall_subtracker ;;
        4) start_subtracker ;;
        5) stop_subtracker ;;
        6) restart_subtracker ;;
        7) logs_subtracker ;;
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
