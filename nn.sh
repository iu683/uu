#!/bin/bash
# =================================================================
# Komga (Manga/EPUB/CBZ) 数字化漫画服务器 自动化集成管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="komga"
BASE_DIR="/opt/komga"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态及多品类书架的真实物理挂载路径
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="latest"

        # 提取 Web 访问端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "25600/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="45600"

        # 提取本地多类别挂载物理路径
        path_config_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_comic_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/comic"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        
        [[ -z "$path_config_show" ]] && path_config_show="$BASE_DIR/config"
        [[ -z "$path_comic_show" ]] && path_comic_show="$BASE_DIR/comic"
    else
        img_version="N/A"
        webui_port="N/A"
        path_config_show="N/A"
        path_comic_show="N/A"
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

# 部署并配置多目录核心逻辑
install_translate() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 网络访问端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Komga 网页访问映射端口 (宿主机) [默认: 45600]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="45600"

    echo -e "\n${CYAN}====== 2. 分类书架数据挂载自定义 (绝对路径) ======${RESET}"
    echo -ne "${YELLOW}1. 请输入【程序系统配置 ./config】保存路径 [默认: $BASE_DIR/config]: ${RESET}"
    read -r path_config
    [[ -z "$path_config" ]] && path_config="$BASE_DIR/config"

    echo -ne "${YELLOW}2. 请输入【本地核心漫画库 ./comic】保存路径 [默认: $BASE_DIR/comic]: ${RESET}"
    read -r path_comic
    [[ -z "$path_comic" ]] && path_comic="$BASE_DIR/comic"

    # 批量创建本地分类目录并赋予高兼容读写权限
    echo -e "\n${YELLOW}正在批量初始化 Komga 分类物理仓所有权及强力读写权限...${RESET}"
    mkdir -p "$path_config" "$path_comic"
    chmod -R 777 "$path_config" "$path_comic"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在构建符合 Komga 标准规范的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  komga:
    image: gotson/komga:latest
    container_name: ${CONTAINER_NAME}
    ports:
      - "${custom_port}:25600"
    environment:
      - UID=0
      - GID=0
      - TZ=Asia/Shanghai
    volumes:
      - "${path_config}:/config"
      - "${path_comic}:/comic"
    restart: unless-stopped
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 编排启动 Komga 漫画库...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待 Komga 引擎构建元数据库及索引环境 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}              Komga 漫画服务器部署成功！                ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}Web 后台访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}系统元数据配置路径: ${path_config}${RESET}"
    echo -e "${YELLOW}漫画流媒体物理路径: ${path_comic}${RESET}"
    echo -e "${CYAN}💡 进阶提示：请将你的 CBZ, CBR, EPUB 或 PDF 漫画归类放入主机的 ${path_comic}。${RESET}"
    echo -e "${CYAN}   首次登录进入 Web 页面注册管理员后，新建媒体库时直接选择【 /comic 】目录即可！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新服务
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 Komga 官方发布版镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！数字化阅读服务已平滑重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 Komga 漫画容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地保存的书架内页缓存、阅读进度及 SQLite 数据库？(⚠️绝不会动你的漫画原文件)(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$path_config_show" != "$BASE_DIR"* && -d "$path_config_show" ]] && rm -rf "$path_config_show"
                echo -e "${GREEN}所有本地的 Komga 账户信息、页码缓存、元数据已彻底清理。${RESET}"
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
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态     : $status"
    echo -e "${YELLOW}核心镜像版本     : ${img_version}${RESET}"
    echo -e "${YELLOW}Web 后台访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}系统元数据配置路径: ${path_config_show}${RESET}"
    echo -e "${YELLOW}漫画流媒体本地路径: ${path_comic_show}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  Komga 漫画仓面板  ◈     ${RESET}"
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
