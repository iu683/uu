#!/bin/bash
# =================================================================
# IYUUPlus 自动辅种/转种工具 Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="IYUUPlus"
BASE_DIR="/opt/iyuuplus"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口和各本地挂载目录
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，精准提取实时挂载和端口信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 提取 WebUI 映射出来的宿主机端口 (内部默认 8780)
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8780/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8780"

        # 提取本地 iyuu 配置目录
        path_iyuu_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/iyuu"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$path_iyuu_show" ]] && path_iyuu_show="$BASE_DIR/iyuu"

        # 提取本地数据/种子目录
        path_data_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$path_data_show" ]] && path_data_show="$BASE_DIR/data"
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        path_iyuu_show="N/A"
        path_data_show="N/A"
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

    echo -e "${CYAN}====== 1. 基础网络端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 IYUU WebUI 访问端口 (宿主机) [默认: 8780]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8780"

    echo -e "\n${CYAN}====== 2. 本地数据挂载自定义 (绝对路径) ======${RESET}"
    echo -e "${GREEN}提示：建议将数据目录直接指向你各下载器（如 qB/TR）共用的主下载或种子存放路径。${RESET}"
    
    echo -ne "${YELLOW}1. 请输入【本地 IYUU 程序配置】保存路径 [默认: $BASE_DIR/iyuu]: ${RESET}"
    read -r path_iyuu
    [[ -z "$path_iyuu" ]] && path_iyuu="$BASE_DIR/iyuu"

    echo -ne "${YELLOW}2. 请输入【本地种子/媒体数据】存放路径 [默认: $BASE_DIR/data]: ${RESET}"
    read -r path_data
    [[ -z "$path_data" ]] && path_data="$BASE_DIR/data"

    # 自动创建本地挂载目录并赋予高权限
    echo -e "\n${YELLOW}正在创建并安全初始化本地独立挂载卷...${RESET}"
    mkdir -p "$path_iyuu" "$path_data"
    chmod -R 777 "$path_iyuu" "$path_data"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合 IYUU 规范的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  iyuuplus-dev:
    stdin_open: true
    tty: true
    container_name: ${CONTAINER_NAME}
    restart: always
    image: iyuucn/iyuuplus-dev:latest
    ports:
      - "${custom_port}:8780"
    volumes:
      - "${path_iyuu}:/iyuu"
      - "${path_data}:/data"
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 启动 IYUUPlus 辅种矩阵...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务构建并扫描网络环境 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}            IYUUPlus 自动化部署成功！                ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}Web 后台访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}程序配置本地路径 : ${path_iyuu}${RESET}"
    echo -e "${YELLOW}种子数据本地路径 : ${path_data}${RESET}"
    echo -e "${CYAN}💡 进阶提示：首次进入后台，默认用户名为 admin，密码自行设置。${RESET}"
    echo -e "${CYAN}   在 IYUU 后台配置下载器路径映射时，请记得勾选或关联容器内的【 /data 】目录。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 IYUUPlus 官方开发版镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！辅种服务已平滑重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 IYUUPlus 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地保存的 IYUU 辅种站点绑定及转种配置？(⚠️ 绝不会动你的下载盘视频文件)(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$path_iyuu_show" != "$BASE_DIR"* && -d "$path_iyuu_show" ]] && rm -rf "$path_iyuu_show"
                echo -e "${GREEN}所有本地的 IYUU 站点令牌、过滤规则及配置数据已彻底清理。${RESET}"
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
    echo -e "${YELLOW}官方开发版镜像   : ${img_version}${RESET}"
    echo -e "${YELLOW}Web 后台访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}程序配置本地路径 : ${path_iyuu_show}${RESET}"
    echo -e "${YELLOW}种子数据本地路径 : ${path_data_show}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}   ◈  IYUUPlus 自动辅种/转种矩阵全能集成管理面板  ◈ ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
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
