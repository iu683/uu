#!/bin/bash
# =================================================================
# Koodo Reader 全功能聚合阅读器 Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="koodo-reader"
BASE_DIR="/opt/koodo-reader"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、多个映射端口及配置路径
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，精准抓取各种端口和路径
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="使用本地构建/已安装"

        # 提取网页端映射出来的宿主机端口 (内部默认 80)
        web_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$web_port" ]] && web_port="80"

        # 提取数据源/OPDS 映射出来的宿主机端口 (内部默认 8080)
        http_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$http_port" ]] && http_port="8080"

        # 提取 KOReader 同步服务器映射出来的宿主机端口 (内部默认 7200)
        ko_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "7200/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$ko_port" ]] && ko_port="7200"

        # 提取宿主机数据保存目录
        path_uploads_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/uploads"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$path_uploads_show" ]] && path_uploads_show="$BASE_DIR/uploads"
    else
        img_version="${RED}未安装${RESET}"
        web_port="N/A"
        http_port="N/A"
        ko_port="N/A"
        path_uploads_show="N/A"
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

# 部署核心逻辑
install_translate() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 基础基础网络端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Koodo 网页端访问端口 (宿主机) [默认: 80]: ${RESET}"
    read -r custom_web_port
    [[ -z "$custom_web_port" ]] && custom_web_port="80"

    echo -ne "${YELLOW}请输入数据源/OPDS 功能端口 (宿主机) [默认: 8080]: ${RESET}"
    read -r custom_http_port
    [[ -z "$custom_http_port" ]] && custom_http_port="8080"

    echo -ne "${YELLOW}请输入 KOReader 同步服务端口 (宿主机) [默认: 7200]: ${RESET}"
    read -r custom_ko_port
    [[ -z "$custom_ko_port" ]] && custom_ko_port="7200"

    echo -e "\n${CYAN}====== 2. 数据持久化路径配置 ======${RESET}"
    echo -ne "${YELLOW}请输入阅读数据与同步数据的本地存储绝对路径 [默认: $BASE_DIR/uploads]: ${RESET}"
    read -r path_uploads
    [[ -z "$path_uploads" ]] && path_uploads="$BASE_DIR/uploads"

    # 初始化开关变量
    enable_http="false"
    enable_opds="false"
    enable_ko="false"
    enable_ko_reg="true"
    srv_user="admin"
    srv_pass="securePass123"

    echo -e "\n${CYAN}====== 3. 高级扩展功能活化开关 ======${RESET}"
    # 功能 A：数据源与 OPDS
    echo -ne "${YELLOW}是否启用【跨平台数据同步数据源】功能？(y/n, 默认 n): ${RESET}"
    read -r opt_http
    if [[ "$opt_http" == "y" || "$opt_http" == "Y" ]]; then
        enable_http="true"
        echo -ne "${YELLOW}  > 是否同时启用【OPDS 外部书库分发】功能？(y/n, 默认 n): ${RESET}"
        read -r opt_opds
        [[ "$opt_opds" == "y" || "$opt_opds" == "Y" ]] && enable_opds="true"
        
        echo -ne "${YELLOW}  > 请设置数据源/OPDS 认证用户名 [默认: admin]: ${RESET}"
        read -r srv_user
        [[ -z "$srv_user" ]] && srv_user="admin"
        
        echo -ne "${YELLOW}  > 请设置数据源/OPDS 认证密码 [默认: securePass123]: ${RESET}"
        read -r srv_pass
        [[ -z "$srv_pass" ]] && srv_pass="securePass123"
    fi

    # 功能 B：KOReader 同步
    echo -ne "${YELLOW}是否启用【KOReader 进度同步服务器】功能？(y/n, 默认 n): ${RESET}"
    read -r opt_ko
    if [[ "$opt_ko" == "y" || "$opt_ko" == "Y" ]]; then
        enable_ko="true"
        echo -ne "${YELLOW}  > 是否禁止陌生未知用户继续注册账号？(y/n, 默认 n 表示允许注册): ${RESET}"
        read -r opt_ko_reg
        [[ "$opt_ko_reg" == "y" || "$opt_ko_reg" == "Y" ]] && enable_ko_reg="false"
    fi

    # 创建本地目录并赋权
    mkdir -p "$path_uploads"
    chmod -R 777 "$path_uploads" "$BASE_DIR"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "\n${YELLOW}正在生成规范化 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  koodo-reader:
    image: ghcr.io/koodo-reader/koodo-reader:master 
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${custom_web_port}:80"
      - "${custom_http_port}:8080"
      - "${custom_ko_port}:7200"
    environment:
      - SERVER_USERNAME=${srv_user}
      - SERVER_PASSWORD=${srv_pass}
      - ENABLE_HTTP_SERVER=${enable_http}
      - ENABLE_OPDS=${enable_opds}
      - ENABLE_KOREADER_SERVER=${enable_ko}
      - ENABLE_KOREADER_REGISTRATION=${enable_ko_reg}
    volumes:
      - "${path_uploads}:/app/uploads"
EOF

    # 启动服务
    echo -e "\n${YELLOW}正在通过 Docker Compose 部署并启动 Koodo Reader 服务集群...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务构建就绪 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    
    echo -e "${GREEN}===================================================${RESET}"
    echo -e "${GREEN}                 Koodo Reader 部署成功！                  ${RESET}"
    echo -e "${GREEN}===================================================${RESET}"
    echo -e "${YELLOW}1. 网页版端访问地址 : http://${DETECT_IP}:${custom_web_port}${RESET}"
    if [[ "$enable_http" == "true" ]]; then
        echo -e "${YELLOW}2. 同步数据源状态   : 🟢 已开启 (端口: ${custom_http_port})${RESET}"
        echo -e "${YELLOW}   - 认证用户/密码  : ${srv_user} / ${srv_pass}${RESET}"
    fi
    if [[ "$enable_opds" == "true" ]]; then
        echo -e "${YELLOW}3. OPDS 书库分发地址: http://${DETECT_IP}:${custom_http_port}/opds${RESET}"
    fi
    if [[ "$enable_ko" == "true" ]]; then
        echo -e "${YELLOW}4. KOReader同步地址 : http://${DETECT_IP}:${custom_ko_port} (默认端口: 7200)${RESET}"
        echo -e "${YELLOW}   - 开放新用户注册 : ${enable_ko_reg}${RESET}"
    fi
    echo -e "${YELLOW}5. 宿主机数据保存轴 : ${path_uploads}${RESET}"
    echo -e "${GREEN}===================================================${RESET}"
}

# 更新镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 Koodo Reader 官方镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！所有关联服务已平滑安全重启。${RESET}"
}

# 卸载容器
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 Koodo Reader 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器集群已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否彻底删除所有上传的图书和跨平台同步数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$path_uploads_show" != "$BASE_DIR"* && -d "$path_uploads_show" ]] && rm -rf "$path_uploads_show"
                echo -e "${GREEN}图书媒体库及全部本地数据缓存已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_translate() { docker logs -f --tail=100 "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${YELLOW}当前运行状态     : $status"
    echo -e "${YELLOW}网页端访问地址   : http://${DETECT_IP}:${web_port}"
    echo -e "${YELLOW}数据源同步地址   : http://${DETECT_IP}:${http_port}"
    echo -e "${YELLOW}OPDS 外部书库地址: http://${DETECT_IP}:${http_port}/opds"
    echo -e "${YELLOW}KOReader同步地址 : http://${DETECT_IP}:${ko_port}"
    echo -e "${YELLOW}数据存储绝对路径 : ${path_uploads_show}${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}  ◈  Koodo Reader 电子书聚合管理面板  ◈ ${RESET}"
    echo -e "${GREEN}=========================================${RESET}"
    echo -e "${GREEN}容器状态  :${RESET} $status"
    echo -e "${GREEN}网页端口  :${RESET} ${YELLOW}${web_port}${RESET}" 
    echo -e "${GREEN}数据源端口:${RESET} ${CYAN}${http_port}${RESET}" 
    echo -e "${GREEN}同步端口  :${RESET} ${YELLOW}${ko_port}${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
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
