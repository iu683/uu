#!/bin/bash
# =================================================================
# TgtoDrive 服务 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/tgtodrive"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
CONTAINER_NAME="TgtoDrive"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器的状态、映射端口和数据目录
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 从 .env 文件中提取配置信息（如果存在）
    if [ -f "$ENV_FILE" ]; then
        webui_port=$(grep "^PORT=" "$ENV_FILE" | cut -d'=' -f2 | sed 's/\r//g')
        [[ -z "$webui_port" ]] && webui_port="12366"
        
        web_user=$(grep "^WEB_USER=" "$ENV_FILE" | cut -d'=' -f2 | sed 's/\r//g')
        
        # 从 docker-compose.yml 中提取实际挂载的宿主机数据根目录
        if [ -f "$COMPOSE_FILE" ]; then
            # 提取挂载 /app/db 的主目录
            local raw_dir=$(grep "\- " "$COMPOSE_FILE" | grep ":/app/db" | awk -F':' '{print $1}' | sed 's/-//g' | sed 's/^[ \t]*//' | head -n 1)
            # 去掉最后的 /db 得到根目录
            data_dir="${raw_dir%/db}"
        fi
        [[ -z "$data_dir" ]] && data_dir="$BASE_DIR"
    else
        webui_port="N/A"
        web_user="N/A"
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

# 部署 TgtoDrive
install_translate() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 配置 Web 面板账户和密码
    echo -ne "${YELLOW}请设置面板登录账号 [默认: admin]: ${RESET}"
    read -r custom_user
    [[ -z "$custom_user" ]] && custom_user="admin"

    echo -ne "${YELLOW}请设置面板登录密码 [默认: password]: ${RESET}"
    read -r custom_pass
    [[ -z "$custom_pass" ]] && custom_pass="password"

    # 2. 配置映射端口
    echo -ne "${YELLOW}请输入 TgtoDrive 访问端口 (宿主机端口) [默认: 12366]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="12366"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 3. 配置数据目录（支持自定义根目录）
    echo -ne "${YELLOW}请输入宿主机数据存储根路径 [默认: /opt/tgtodrive]: ${RESET}"
    read -r custom_data
    [[ -z "$custom_data" ]] && custom_data="/opt/tgtodrive"

    # 创建子文件夹
    mkdir -p "${custom_data}/db" "${custom_data}/Emby/strm" "${custom_data}/downloads" "${custom_data}/MoviePilot/transfer"
    chmod -R 777 "$BASE_DIR" "${custom_data}"

    # 生成环境变量 .env 配置文件
    echo -e "${YELLOW}正在生成环境变量 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
TZ=Asia/Shanghai
PORT=${custom_port}
WEB_USER=${custom_user}
WEB_PASS=${custom_pass}
DATA_ROOT=${custom_data}
EOF

    # 动态生成 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  tgtodrive-service:
    image: walkingd/tgto123:latest
    container_name: ${CONTAINER_NAME}
    ports:
      - "\${PORT:-12366}:12366"
    environment:
      - TZ=\${TZ:-Asia/Shanghai}
      - ENV_WEB_PASSPORT=\${WEB_USER}
      - ENV_WEB_PASSWORD=\${WEB_PASS}
    volumes:
      - \${DATA_ROOT}/db:/app/db
      - \${DATA_ROOT}/Emby/strm:/app/strm
      - \${DATA_ROOT}/downloads:/app/downloads
      - \${DATA_ROOT}/MoviePilot/transfer:/app/upload
    restart: always
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 TgtoDrive 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      TgtoDrive 部署成功！      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}面板访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}登录账号密码 : ${custom_user} / ${custom_pass}${RESET}"
    echo -e "${YELLOW}面板配置目录 : $BASE_DIR${RESET}"
    echo -e "${YELLOW}数据挂载根区 : ${custom_data}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新 TgtoDrive 镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载服务
uninstall_translate() {
    get_status_info
    echo -ne "${YELLOW}确定要卸载并删除 TgtoDrive 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有挂载的数据、网盘缓存和配置文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                # 清理自定义的数据路径
                if [ -d "$data_dir" ] && [ "$data_dir" != "N/A" ]; then
                    rm -rf "$data_dir"
                    echo -e "${GREEN}数据挂载根区 [${data_dir}] 已彻底清理。${RESET}"
                fi
                # 清理脚本自身所在的配置主目录
                if [ "$BASE_DIR" != "$data_dir" ]; then
                    rm -rf "$BASE_DIR"
                fi
                echo -e "${GREEN}项目配置主目录 [${BASE_DIR}] 已彻底清理。${RESET}"
            fi
        else
            echo -e "${RED}未找到 compose 文件，尝试强制清理可能残留的容器...${RESET}"
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_translate() { cd "$BASE_DIR" && docker compose logs -f; }

show_info() {
    get_status_info
    local current_user=$(grep "^WEB_USER=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2)
    local current_pass=$(grep "^WEB_PASS=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}TgtoDrive 服务状态 : ${status}"
    echo -e "${YELLOW}管理面板登录账号   : ${current_user:-N/A}"
    echo -e "${YELLOW}管理面板登录密码   : ${current_pass:-N/A}"
    echo -e "${YELLOW}数据实际挂载根区   : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  TgtoDrive 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}服务状态 : ${status}"
    echo -e "${GREEN}映射端口 : ${YELLOW}${webui_port}${RESET}"
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
