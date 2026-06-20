#!/bin/bash
# =================================================================
# MDC (Movie Data Capture) 刮削大师 自动化集成与多卷挂载面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="mdc"
BASE_DIR="/opt/mdc"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 获取容器状态、鉴权账户及本地挂载配置
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

        # 提取端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "9208/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="9208"

        # 提取本地 Config 与 Media 真实路径
        path_config_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_media_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/media"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$path_config_show" ]] && path_config_show="$BASE_DIR/config"
        [[ -z "$path_media_show" ]] && path_media_show="$BASE_DIR/media"
    else
        img_version="N/A"
        webui_port="N/A"
        path_config_show="N/A"
        path_media_show="N/A"
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

    echo -e "${CYAN}====== 1. 网络访问端口与鉴权设置 ======${RESET}"
    echo -ne "${YELLOW}1. 请输入 MDC 网页访问映射端口 (宿主机) [默认: 9208]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="9208"

    echo -ne "${YELLOW}2. 请设置 MDC 登录后台的【用户名】 [默认: admin]: ${RESET}"
    read -r custom_user
    [[ -z "$custom_user" ]] && custom_user="admin"

    echo -ne "${YELLOW}3. 请设置 MDC 登录后台的【密 码】 [默认: admin]: ${RESET}"
    read -r custom_pass
    [[ -z "$custom_pass" ]] && custom_pass="admin"

    echo -e "\n${CYAN}====== 2. 本地数据挂载自定义 (绝对路径) ======${RESET}"
    echo -e "${GREEN}提示：MDC 需要对媒体执行整理及重命名，请确保媒体路径具备读写权限。${RESET}"
    echo -ne "${YELLOW}1. 请输入【本地程序配置 ./config】保存路径 [默认: $BASE_DIR/config]: ${RESET}"
    read -r path_config
    [[ -z "$path_config" ]] && path_config="$BASE_DIR/config"

    echo -ne "${YELLOW}2. 请输入【本地待刮削/已整理媒体库 ./media】主路径 [默认: $BASE_DIR/media]: ${RESET}"
    read -r path_media
    [[ -z "$path_media" ]] && path_media="$BASE_DIR/media"

    # 初始化本地目录，赋予 777 权限，规避 PUID=1000 时的写入报错
    echo -e "\n${YELLOW}正在对本地文件系统执行高兼容权限初始化...${RESET}"
    mkdir -p "$path_config" "$path_media"
    chmod -R 777 "$path_config" "$path_media"

    # 生成安全的规范化 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在构建符合 MDC-NG 规范的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  mdc:
    image: mdcng/mdc:latest
    container_name: ${CONTAINER_NAME}
    environment:
      - PGID=0
      - PUID=0
      - MDC_USERNAME=${custom_user}
      - MDC_PASSWORD=${custom_pass}
    volumes:
      - "${path_config}:/config"
      - "${path_media}:/media"
#     - "/你的第二个硬盘路径:/media2" # 如需挂载更多媒体盘，可在部署后取消注释此行并仿照添加
    ports:
      - "${custom_port}:9208"
    restart: unless-stopped
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 启动 MDC 刮削器后台...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待 MDC 引擎构建环境环境 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}              MDC 刮削器部署成功！                ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}后台管理地址     : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}默认登录账户     : ${custom_user}${RESET}"
    echo -e "${YELLOW}默认登录密码     : ${custom_pass}${RESET}"
    echo -e "${YELLOW}程序配置本地路径 : ${path_config}${RESET}"
    echo -e "${YELLOW}视频媒体本地路径 : ${path_media}${RESET}"
    echo -e "${CYAN}💡 进阶提示：请将你要刮削或分类的视频文件夹放入主机的 ${path_media}。${RESET}"
    echo -e "${CYAN}   登录网页端配置“本地扫描路径”和“输出路径”时，直接填写【 /media 】即可！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新服务
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 MDC 官方镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！MDC 服务已平滑重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 MDC 刮削容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地保存的 MDC 刮削规则、刮削缓存数据？(绝不会删除你的电影和视频文件)(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$path_config_show" != "$BASE_DIR"* && -d "$path_config_show" ]] && rm -rf "$path_config_show"
                echo -e "${GREEN}所有相关的本地 MDC 数据库、API 缓存文件已彻底清理。${RESET}"
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
    echo -e "${YELLOW}本地配置存储路径 : ${path_config_show}${RESET}"
    echo -e "${YELLOW}视频媒体存储路径 : ${path_media_show}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  MDC  刮削管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态  :${RESET} $status"
    echo -e "${GREEN}端口  :${RESET} ${YELLOW}${webui_port}${RESET}"
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
