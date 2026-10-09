#!/bin/bash
# =================================================================
# WebProxy Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="WebProxy"
BASE_DIR="/opt/WebProxy"
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
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        port_display="N/A"
        return 0
    fi
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${GREEN}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "18080/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="18080"
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

# 部署 WebProxy
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. WebProxy 密钥 (Secret) 配置 ======${RESET}"
    echo -e "${YELLOW}提示: 32位十六进制。留空则由容器自动生成，之后可从日志中查看。${RESET}"
    echo -ne "${YELLOW}请输入 Secret [默认: 留空自动生成]: ${RESET}"
    read -r custom_secret

    echo -e "\n${CYAN}====== 2. Web 伪装模式配置 (可选) ======${RESET}"
    echo -ne "${YELLOW}是否启用 Web 伪装模式 (proxy_mode=web)？(y/n) [默认: y]: ${RESET}"
    read -r enable_web
    [[ -z "$enable_web" ]] && enable_web="y"

    local env_web_block=""
    if [[ "$enable_web" =~ ^[Yy]$ ]]; then
        echo -ne "${YELLOW}请输入伪装域名 (web_hostname) [默认: your-domain-replace.it]: ${RESET}"
        read -r web_host
        [[ -z "$web_host" ]] && web_host="your-domain-replace.it"
        
        env_web_block="
            - proxy_mode=web
            - web_hostname=${web_host}
            - web_fallback=public
            - web_front=external
            - web_listen=0.0.0.0:18080"
    fi

    echo -e "\n${CYAN}====== 3. 网络端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 WebProxy 访问端口 [默认: 18080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="18080"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 动态生成规范的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成规范的 docker-compose.yml 配置文件...${RESET}"
    
    # 组装 environment 部分
    local env_content="        environment:"
    if [[ -n "$custom_secret" ]]; then
        env_content="${env_content}
            - secret=${custom_secret}"
    fi
    if [[ -n "$env_web_block" ]]; then
        env_content="${env_content}${env_web_block}"
    fi
    # 如果用户什么都没填，留空一项防止yaml语法错误
    if [[ -z "$custom_secret" && -z "$env_web_block" ]]; then
        env_content="${env_content}
            - proxy_mode=classic"
    fi

    cat <<EOF > "$COMPOSE_FILE"
services:
    WebProxy:
        container_name: ${CONTAINER_NAME}
        restart: always
${env_content}
        ports:
            - "${custom_port}:18080"
        image: ellermister/mtproxy:latest
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 WebProxy...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}       WebProxy 部署成功！       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}访问/代理端口 : ${custom_port}${RESET}"
    echo -e "${YELLOW}查看代理链接  : docker logs WebProxy${RESET}"
    echo -e "${YELLOW}配置文件路径  : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 WebProxy 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 WebProxy 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 WebProxy
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 WebProxy 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            rm -rf "$BASE_DIR"
            echo -e "${GREEN}容器已停止并清理相关配置目录。${RESET}"
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
    echo -e "${YELLOW}当前状态      : $status"
    echo -e "${YELLOW}镜像名称      : ${img_version}${RESET}"
    echo -e "${YELLOW}映射端口      : ${port_display}${RESET}"
    echo -e "${YELLOW}配置文件路径  : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}获取直连链接  : docker logs mtproxy${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  WebProxy 管理面板  ◈     ${RESET}"
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
    echo -e "${GREEN}7. 查看日志 (获取链接)${RESET}"
    echo -e "${GREEN}8. 查看配置信息${RESET}"
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
