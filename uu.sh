#!/bin/bash
# =================================================================
# Emby Server (开心版) 架构/硬解/本地数据挂载自适应管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="amilys_embyserver"
BASE_DIR="/opt/emby"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、架构、端口及本地挂载配置
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 自动检测当前宿主机 CPU 架构
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        CURRENT_ARCH_TEXT="AMD64 (x86_64)"
    elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        CURRENT_ARCH_TEXT="ARM64 (arm64v8)"
    else
        CURRENT_ARCH_TEXT="未知架构 ($ARCH)"
    fi

    # 3. 如果容器存在，精准提取本地挂载路径
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 提取端口 (内部默认 8096)
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8096/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="7568"

        # 【核心：精准提取本地挂载路径】
        path_config_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_media_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$path_config_show" ]] && path_config_show="未检测到挂载"
        [[ -z "$path_media_show" ]] && path_media_show="未检测到挂载"

        # 检查是否挂载了硬解设备
        has_dri=$(docker inspect -f '{{range .HostConfig.Devices}}{{.PathOnHost}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | grep "/dev/dri")
        if [[ -n "$has_dri" ]]; then
            hw_status="${GREEN}已开启 (/dev/dri)${RESET}"
        else
            hw_status="${RED}已关闭${RESET}"
        fi
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        path_config_show="N/A"
        path_media_show="N/A"
        hw_status="N/A"
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

# 部署并配置本地挂载核心逻辑
install_translate() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 系统架构自动判定 ======${RESET}"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        IMAGE_NAME="amilys/embyserver"
        ARCH_TEXT="AMD64 (x86_64)"
    elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        IMAGE_NAME="amilys/embyserver_arm64v8"
        ARCH_TEXT="ARM64 (arm64v8)"
    else
        echo -e "${RED}❌ 未知或不支持的系统架构: $ARCH${RESET}"
        return
    fi
    echo -e "硬件架构: ${GREEN}${ARCH_TEXT}${RESET} -> 匹配镜像: ${CYAN}${IMAGE_NAME}${RESET}"

    echo -e "\n${CYAN}====== 2. 基础网络端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Emby WEB 访问映射端口 (宿主机) [默认: 7568]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="7568"

    echo -e "\n${CYAN}====== 3. 本地数据挂载自定义 (绝对路径) ======${RESET}"
    echo -e "${GREEN}提示：挂载到本地可以确保容器删除、更新时，你的观影记录和媒体文件绝不丢失。${RESET}"
    
    echo -ne "${YELLOW}1. 请输入【本地 Emby 配置与缓存】保存路径 [默认: /opt/emby/config]: ${RESET}"
    read -r path_config
    [[ -z "$path_config" ]] && path_config="/opt/emby/config"

    echo -ne "${YELLOW}2. 请输入【本地媒体电影/剧集视频】存放路径 [默认: /opt/emby/media]: ${RESET}"
    read -r path_media
    [[ -z "$path_media" ]] && path_media="/opt/emby/media"

    echo -e "\n${CYAN}====== 4. 显卡核显硬件解码配置 ======${RESET}"
    echo -ne "${YELLOW}是否需要启用 Intel/AMD 核显硬解解压（挂载 /dev/dri）？(y/n, 默认 n): ${RESET}"
    read -r HW_TRANSCODE

    # 自动创建本地挂载目录并赋予最高权限，防止 Emby 容器内部产生 Permission Denied
    echo -e "\n${YELLOW}正在创建并初始化本地挂载目录权限...${RESET}"
    mkdir -p "$path_config" "$path_media"
    chmod -R 777 "$path_config" "$path_media"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合本地挂载规范的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  embyserver:
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    network_mode: bridge
    environment:
      - UID=0
      - GID=0
      - GIDLIST=0
      - TZ=Asia/Shanghai
    volumes:
      - "${path_config}:/config"
      - "${path_media}:/data"
    ports:
      - "${custom_port}:8096"
    restart: unless-stopped
EOF

    # 动态追加硬解
    if [[ "$HW_TRANSCODE" == "y" || "$HW_TRANSCODE" == "Y" ]]; then
        cat <<EOF >> "$COMPOSE_FILE"
    devices:
      - /dev/dri:/dev/dri
EOF
    fi

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 启动本地挂载版 Emby Server...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务构建并扫描环境 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}              Emby 本地挂载部署成功！                ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}WEB 访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}本地配置路径   : ${path_config}${RESET}"
    echo -e "${YELLOW}本地媒体路径   : ${path_media}${RESET}"
    echo -e "${CYAN}💡 进阶提示：请将你的电影/电视剧文件直接上传到主机的 ${path_media} 目录中。${RESET}"
    echo -e "${CYAN}   进入 Emby 网页端后台添加媒体库时，选择容器内的【 /data 】目录即可读取！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新开心版 Emby 官方镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！Emby 服务已平滑重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 Emby 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地保存的 Emby 刮削配置与海报数据？(⚠️ 绝不会删除你的电影和视频文件)(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$path_config_show" != "$BASE_DIR"* && -d "$path_config_show" ]] && rm -rf "$path_config_show"
                echo -e "${GREEN}所有相关的本地刮削海报及配置缓存已彻底清理。${RESET}"
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
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}当前硬件架构   : ${CURRENT_ARCH_TEXT}${RESET}"
    echo -e "${YELLOW}核心镜像版本   : ${img_version}${RESET}"
    echo -e "${YELLOW}显卡硬解状态   : ${hw_status}${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}本地配置路径   : ${path_config_show}${RESET}"
    echo -e "${YELLOW}本地媒体路径   : ${path_media_show}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}   ◈  Emby Server 开心版面板  ◈    ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}状态    :${RESET} $status"
    echo -e "${GREEN}系统架构:${RESET} ${CYAN}${CURRENT_ARCH_TEXT}${RESET}" 
    echo -e "${GREEN}硬解状态:${RESET} ${hw_status}${RESET}"
    echo -e "${GREEN}端口    :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置"
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
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
