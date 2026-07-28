#!/bin/bash
# =================================================================
# Animaku 影视播放系统 (官方原生 Clone + 环境变量 Build) 自动化管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

APP_NAME="animaku"
BASE_DIR="/opt/animaku"
SRC_DIR="$BASE_DIR" 
REPO_URL="https://github.com/uerax/Animaku.git"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! command -v git &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Git，请先安装 Git！${RESET}"
        exit 1
    fi
}

# 动态获取服务端口与运行状态
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        return 0
    fi
    local container_id=$(docker ps -q -f "ancestor=animaku:local" -f "status=running" 2>/dev/null)
    [[ -z "$container_id" ]] && container_id=$(docker ps -q -f "name=animaku" -f "status=running" 2>/dev/null)

    if [[ -n "$container_id" ]]; then
        status="${GREEN}运行中${RESET}"
        # 优先从运行中的容器环境变量中提取 PORT
        webui_port=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container_id" 2>/dev/null | grep "^PORT=" | cut -d'=' -f2)
        # 如果环境变量没取到，则回退去解析宿主机端口映射
        if [[ -z "$webui_port" ]]; then
            webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8787/tcp") 0).HostPort}}' "$container_id" 2>/dev/null)
        fi
        [[ -z "$webui_port" ]] && webui_port="8787"
    else
        if [ -d "$SRC_DIR/.git" ]; then
            status="${RED}已停止${RESET}"
        else
            status="${RED}未部署${RESET}"
        fi
        webui_port="N/A"
    fi
}

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

    echo -e "${CYAN}====== 1. 端口与代理配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Animaku 映射端口 (对应 PORT) [默认: 8787]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8787"

    echo -ne "${YELLOW}是否开启公开代理/插件API (PUBLIC_PROXY: 1=开启, 0=仅局域网) [默认: 1]: ${RESET}"
    read -r custom_proxy
    [[ -z "$custom_proxy" ]] && custom_proxy="1"

    echo -ne "${YELLOW}是否开启 Anime1 完整媒体隧道 (MEDIA_FULL_PROXY: 1=开启, 0=仅m3u8) [默认: 0]: ${RESET}"
    read -r custom_full_proxy
    [[ -z "$custom_full_proxy" ]] && custom_full_proxy="0"

    # 克隆官方仓库到当前工作目录
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "\n${YELLOW}正在克隆官方 GitHub 仓库...${RESET}"
        git clone "$REPO_URL" "$SRC_DIR/tmp_repo"
        if [ $? -eq 0 ]; then
            mv "$SRC_DIR/tmp_repo/"* "$SRC_DIR/" 2>/dev/null
            mv "$SRC_DIR/tmp_repo/."* "$SRC_DIR/" 2>/dev/null
            rm -rf "$SRC_DIR/tmp_repo"
        else
            echo -e "${RED}错误: 仓库克隆失败，请检查网络！${RESET}"
            exit 1
        fi
    else
        echo -e "\n${GREEN}检测到本地已存在官方仓库，正在同步最新代码...${RESET}"
        cd "$SRC_DIR" && git pull
    fi

    # 回到仓库根目录
    cd "$SRC_DIR"

    # 初始化 .env 配置文件
    if [ ! -f ".env" ]; then
        if [ -f ".env.example" ]; then
            cp .env.example .env
            echo -e "${GREEN}已基于 .env.example 自动创建 .env 配置文件${RESET}"
        fi
    fi

    # 动态写入用户自定义的环境变量到 .env
    sed -i "s/^PORT=.*/PORT=$custom_port/" .env 2>/dev/null || echo "PORT=$custom_port" >> .env
    sed -i "s/^PUBLIC_PROXY=.*/PUBLIC_PROXY=$custom_proxy/" .env 2>/dev/null || echo "PUBLIC_PROXY=$custom_proxy" >> .env
    sed -i "s/^MEDIA_FULL_PROXY=.*/MEDIA_FULL_PROXY=$custom_full_proxy/" .env 2>/dev/null || echo "MEDIA_FULL_PROXY=$custom_full_proxy" >> .env

    echo -e "\n${YELLOW}正在执行官方原生编译启动命令...${RESET}"
    PORT=$custom_port PUBLIC_PROXY=$custom_proxy MEDIA_FULL_PROXY=$custom_full_proxy docker compose up -d --build

    echo -e "${YELLOW}正在等待容器集群 Build 编译并拉起服务 (约 5 秒)...${RESET}"
    sleep 5

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}        Animaku 官方原生集群编译并启动成功！         ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}默认访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}健康检查接口 : http://${DETECT_IP}:${custom_port}/api/health${RESET}"
    echo -e "${YELLOW}仓库所在路径 : ${SRC_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 原生更新：拉取代码 + 重新 Build
update_translate() {
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "${RED}错误: 未检测到克隆的仓库，请先执行选项 1！${RESET}"
        return
    fi
    get_status_info
    local current_port=$webui_port
    [[ "$current_port" == "N/A" ]] && current_port="8787"

    echo -e "${YELLOW}正在同步最新的远程官方代码...${RESET}"
    cd "$SRC_DIR" && git pull
    
    echo -e "${YELLOW}正在使用官方命令重编镜像并热更新...${RESET}"
    PORT=$current_port docker compose up -d --build --remove-orphans
    echo -e "${GREEN}官方集群更新并重编完成！${RESET}"
}

# 彻底卸载
uninstall_translate() {
    echo -ne "${RED}确定要停止并卸载 Animaku 官方容器集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -d "$SRC_DIR/.git" ]; then
            cd "$SRC_DIR" && docker compose down
            echo -e "${GREEN}官方容器与网络已被安全停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同步连根拔除本地克隆的【全部源码及配置文件】？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有源码与持久化数据已被彻底清除！${RESET}"
            fi
        else
            echo -e "${YELLOW}未检测到运行中的 compose 环境，跳过物理删除。${RESET}"
        fi
    fi
}

# 基于官方 Compose 文件的生命周期联动
start_translate() { cd "$SRC_DIR" && docker compose start && echo -e "${GREEN}原生集群已全面启动${RESET}"; }
stop_translate() { cd "$SRC_DIR" && docker compose stop && echo -e "${YELLOW}原生集群已安全停止${RESET}"; }
restart_translate() { cd "$SRC_DIR" && docker compose restart && echo -e "${GREEN}原生集群已平滑重启${RESET}"; }
logs_translate() { cd "$SRC_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}集群运行状态     : $status"
    echo -e "${YELLOW}前端访问地址     : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}健康检查接口     : http://${DETECT_IP}:${webui_port}/api/health${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}    ◈  Animaku 影视管理面板  ◈     ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}集群状态 :${RESET} $status"
    echo -e "${GREEN}服务端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
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
