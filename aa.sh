#!/bin/bash
# =================================================================
# BiliLive-Tools 服务 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/bililive-tools"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取多个容器的状态、映射端口和数据目录
get_status_info() {
    # 1. 检查各个容器状态
    w_status="${RED}已停止/未部署${RESET}"
    a_status="${RED}已停止/未部署${RESET}"

    if [ "$(docker ps -q -f name=bililive-tools-webui-1)" ] || [ "$(docker ps -q -f name=webui-1)" ]; then w_status="${YELLOW}运行中${RESET}"; fi
    if [ "$(docker ps -q -f name=bililive-tools-api-1)" ] || [ "$(docker ps -q -f name=api-1)" ]; then a_status="${YELLOW}运行中${RESET}"; fi

    # 2. 从 .env 文件中提取配置信息（如果存在）
    if [ -f "$ENV_FILE" ]; then
        web_port=$(grep "^WEB_PORT=" "$ENV_FILE" | cut -d'=' -f2 | sed 's/\r//g')
        api_port=$(grep "^API_PORT=" "$ENV_FILE" | cut -d'=' -f2 | sed 's/\r//g')
        [[ -z "$web_port" ]] && web_port="3000"
        [[ -z "$api_port" ]] && api_port="18010"
        
        # 从 docker-compose.yml 中提取实际挂载的宿主机数据根目录
        if [ -f "$COMPOSE_FILE" ]; then
            local raw_dir=$(grep "\- " "$COMPOSE_FILE" | grep ":/app/data" | awk -F':' '{print $1}' | sed 's/-//g' | sed 's/^[ \t]*//' | head -n 1)
            data_dir="${raw_dir%/data}"
        fi
        [[ -z "$data_dir" ]] && data_dir="$BASE_DIR"
    else
        web_port="N/A"
        api_port="N/A"
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

# 部署 BiliLive-Tools
install_translate() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 配置映射端口
    echo -ne "${YELLOW}请输入前端 WEB UI 访问端口 [默认: 3000]: ${RESET}"
    read -r custom_web_port
    [[ -z "$custom_web_port" ]] && custom_web_port="3000"

    echo -ne "${YELLOW}请输入后端 API 接口服务端口 [默认: 18010]: ${RESET}"
    read -r custom_api_port
    [[ -z "$custom_api_port" ]] && custom_api_port="18010"

    # 2. 配置数据存储目录
    echo -ne "${YELLOW}请输入宿主机数据挂载根路径 [默认: /opt/bililive-tools]: ${RESET}"
    read -r custom_data
    [[ -z "$custom_data" ]] && custom_data="/opt/bililive-tools"

    # 3. 配置安全密钥（不输入则自动随机生成）
    rand_pass=$(date +%s | sha256sum | head -c 16)
    rand_bili=$(date +%s | sha256sum | base64 | head -c 24)

    echo -ne "${YELLOW}请设置登录密钥 PASSKEY (留空自动生成随机串): ${RESET}"
    read -r custom_pass
    [[ -z "$custom_pass" ]] && custom_pass="${rand_pass}"

    echo -ne "${YELLOW}请设置加密密钥 BILIKEY (留空自动生成随机串): ${RESET}"
    read -r custom_bili
    [[ -z "$custom_bili" ]] && custom_bili="${rand_bili}"

    # 创建必要的子挂载目录
    mkdir -p "${custom_data}/data" "${custom_data}/video" "${custom_data}/fonts"
    chmod -R 777 "$BASE_DIR" "${custom_data}"

    # 生成环境变量 .env 配置文件
    echo -e "${YELLOW}正在生成环境变量 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
TZ=Asia/Shanghai
WEB_PORT=${custom_web_port}
API_PORT=${custom_api_port}
DATA_ROOT=${custom_data}
PASSKEY=${custom_pass}
BILIKEY=${custom_bili}
EOF

    # 动态生成 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  webui:
    image: renmu1234/bililive-tools-frontend
    ports:
      - "\${WEB_PORT:-3000}:3000"
    restart: unless-stopped

  api:
    image: renmu1234/bililive-tools-backend
    ports:
      - "\${API_PORT:-18010}:18010"
    volumes:
      - \${DATA_ROOT}/data:/app/data
      - \${DATA_ROOT}/video:/app/video
      - \${DATA_ROOT}/fonts:/usr/local/share/fonts
    environment:
      - BILILIVE_TOOLS_PASSKEY=\${PASSKEY}
      - BILILIVE_TOOLS_BILIKEY=\${BILIKEY}
      - BILILIVE_TOOLS_DELETE_DIRS=/app/video
      - TZ=\${TZ:-Asia/Shanghai}
    restart: unless-stopped
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 BiliLive-Tools 服务组合...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     BiliLive-Tools 部署成功！    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}前端 UI 访问地址 : http://${DETECT_IP}:${custom_web_port}${RESET}"
    echo -e "${YELLOW}后端 API 监听地址 : http://${DETECT_IP}:${custom_api_port}${RESET}"
    echo -e "${YELLOW}登录密钥 PASSKEY : ${custom_pass}${RESET}"
    echo -e "${YELLOW}面板管理配置目录 : $BASE_DIR${RESET}"
    echo -e "${YELLOW}持久化数据根路径 : ${custom_data}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新所有镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新 BiliLive-Tools 镜像组件...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！所有容器已处于最新状态。${RESET}"
}

# 卸载服务
uninstall_translate() {
    get_status_info
    echo -ne "${YELLOW}确定要卸载并删除 BiliLive-Tools 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有录制视频、配置文件和字体？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                # 清理外部自定义的数据挂载路径
                if [ -d "$data_dir" ] && [ "$data_dir" != "N/A" ]; then
                    rm -rf "$data_dir"
                    echo -e "${GREEN}数据挂载区 [${data_dir}] 已彻底清理。${RESET}"
                fi
                # 清理脚本主目录
                if [ "$BASE_DIR" != "$data_dir" ]; then
                    rm -rf "$BASE_DIR"
                fi
                echo -e "${GREEN}项目配置主目录 [${BASE_DIR}] 已彻底清理。${RESET}"
            fi
        else
            echo -e "${RED}未找到 compose 文件，尝试强制清理可能残留的容器...${RESET}"
            docker rm -f $(docker ps -aq -f name=bililive-tools) 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}所有组件已启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}所有组件已停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}所有组件已重启${RESET}"; }
logs_translate() { cd "$BASE_DIR" && docker compose logs -f; }

show_info() {
    get_status_info
    local current_pass=$(grep "^PASSKEY=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2)
    local current_bili=$(grep "^BILIKEY=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}前端状态 (WebUI)  : ${w_status}"
    echo -e "${YELLOW}后端状态 (API)    : ${a_status}"
    echo -e "${YELLOW}登录密钥 PASSKEY  : ${current_pass:-N/A}"
    echo -e "${YELLOW}加密密钥 BILIKEY  : ${current_bili:-N/A}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} ◈  BiliLive-Tools  管理面板 ◈  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}前端状态 (WebUI)  : ${w_status}"
    echo -e "${GREEN}后端状态 (API)    : ${a_status}"
    echo -e "${GREEN}前端映射端口      : ${YELLOW}${web_port}${RESET}"  
    echo -e "${GREEN}后端映射端口      : ${YELLOW}${api_port}${RESET}"
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
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
