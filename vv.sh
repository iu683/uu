#!/bin/bash
# =================================================================
# LangBot  Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="langbot"
# 固定安装到 /opt/LangBot
TARGET_DIR="/opt/LangBot"
BASE_DIR="/opt/LangBot/docker"

# 检测并修复依赖与权限
check_dependencies() {
    if ! command -v git &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Git，请先安装 Git！${RESET}"
        exit 1
    fi

    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    
    # 检查当前用户是否有权限访问 Docker 守护进程
    if ! docker info &> /dev/null; then
        echo -e "${YELLOW}检测到当前用户无 Docker 访问权限，正在尝试修复...${RESET}"
        sudo usermod -aG docker $USER
        echo -e "${GREEN}已将当前用户加入 docker 组。${RESET}"
        echo -e "${RED}由于 Linux 机制，权限变更需要重新加载组。请执行 'newgrp docker'${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口
get_status_info() {
    # 1. 检查主容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署 / 未启动${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "5300/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="5300"
    else
        webui_port="5300"
    fi
}

get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
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

# 按照官方指引克隆到 /opt 并部署
install_langbot() {
    check_dependencies
    
    echo -e "${CYAN}====== 开始执行官方克隆部署 ======${RESET}"
    
    # 确保对 /opt 有操作权限
    if [ ! -w "/opt" ]; then
        echo -e "${YELLOW}提示: 当前用户对 /opt 目录没有写权限，正在请求 sudo 权限创建目录...${RESET}"
        sudo mkdir -p "$TARGET_DIR"
        sudo chown -R $USER:$USER "$TARGET_DIR"
    fi

    if [ -d "$TARGET_DIR" ] && [ "$(ls -A $TARGET_DIR)" ]; then
        echo -e "${YELLOW}提示: 检测到 $TARGET_DIR 文件夹已存在且不为空。${RESET}"
        echo -ne "${YELLOW}是否清空并重新克隆？(y/n) [默认: n]: ${RESET}"
        read -r re_clone
        if [[ "$re_clone" == "y" || "$re_clone" == "Y" ]]; then
            rm -rf "$TARGET_DIR"
            git clone https://github.com/langbot-app/LangBot "$TARGET_DIR"
        fi
    else
        git clone https://github.com/langbot-app/LangBot "$TARGET_DIR"
    fi

    if [ ! -d "$BASE_DIR" ]; then
        echo -e "${RED}错误: 未找到 $BASE_DIR 目录，请检查 Git 克隆是否成功！${RESET}"
        return
    fi

    # 中国大陆镜像替换提示
    echo -ne "${YELLOW}是否位于中国大陆，需要一键替换为官方提供的国内镜像源？(y/n) [默认: n]: ${RESET}"
    read -r use_mirror
    if [[ "$use_mirror" == "y" || "$use_mirror" == "Y" ]]; then
        echo -e "${YELLOW}正在修改 docker-compose.yaml 使用国内镜像源...${RESET}"
        sed -i 's|rockchin/langbot:latest|docker.langbot.app/langbot-public/rockchin/langbot:latest|g' "$BASE_DIR/docker-compose.yaml"
    fi

    # 可选配置 LANGBOT_BOX_ROOT
    echo -e "${CYAN}----------------------------------${RESET}"
    echo -e "${YELLOW}提示: 若要改 Box 根目录，请使用绝对路径设置。${RESET}"
    echo -ne "${YELLOW}是否设置自定义 LANGBOT_BOX_ROOT 绝对路径？(直接回车跳过使用默认值): ${RESET}"
    read -r custom_box_root

    cd "$BASE_DIR" || return

    if [[ -n "$custom_box_root" ]]; then
        if [[ ! "$custom_box_root" =~ ^/ ]]; then
            echo -e "${RED}错误: Box 根目录必须使用绝对路径！部署中断。${RESET}"
            return
        fi
        echo -e "${YELLOW}正在使用自定义路径启动官方容器...${RESET}"
        export LANGBOT_BOX_ROOT="$custom_box_root"
        docker compose --profile all up -d
    else
        echo -e "${YELLOW}正在按照官方推荐启动容器 (开启 --profile all)...${RESET}"
        docker compose --profile all up -d
    fi

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      LangBot 启动命令已发送！    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}OneBot 反向端口: 2280-2285${RESET}"
    echo -e "${RED}首次启动请注意：请观察终端输出或容器日志，按照提示继续配置文件。${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 LangBot 官方代码与镜像
update_langbot() {
    if [ ! -d "$BASE_DIR" ]; then
        echo -e "${RED}错误: 未检测到官方目录 $BASE_DIR，请先执行选项 1 部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在同步官方最新代码 (Git Pull)...${RESET}"
    cd "$TARGET_DIR" && git pull
    cd "$BASE_DIR" || return
    echo -e "${YELLOW}正在拉取最新镜像...${RESET}"
    docker compose --profile all pull
    docker compose --profile all up -d --remove-orphans
    echo -e "${GREEN}更新完成！${RESET}"
}

# 卸载 LangBot 容器
uninstall_langbot() {
    if [ ! -d "$BASE_DIR" ]; then
        echo -e "${RED}错误: 未检测到官方目录 $BASE_DIR！${RESET}"
        return
    fi
    echo -ne "${YELLOW}确定要停止并删除 LangBot 吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        cd "$BASE_DIR" || return
        docker compose --profile all down
        echo -e "${GREEN}容器已停止并移除。${RESET}"
        
        echo -ne "${YELLOW}是否彻底删除 /opt/LangBot 源码文件夹？(y/n): ${RESET}"
        read -r delete_dir
        if [ "$delete_dir" = "y" ] || [ "$delete_dir" = "Y" ]; then
            rm -rf "$TARGET_DIR"
            echo -e "${GREEN}LangBot 源码目录已彻底删除。${RESET}"
        fi
    fi
}

start_langbot() { 
    if [ -d "$BASE_DIR" ]; then cd "$BASE_DIR" && docker compose --profile all start && echo -e "${GREEN}服务已启动${RESET}"; else echo -e "${RED}目录不存在！${RESET}"; fi
}
stop_langbot() { 
    if [ -d "$BASE_DIR" ]; then cd "$BASE_DIR" && docker compose --profile all stop && echo -e "${YELLOW}服务已停止${RESET}"; else echo -e "${RED}目录不存在！${RESET}"; fi
}
restart_langbot() { 
    if [ -d "$BASE_DIR" ]; then cd "$BASE_DIR" && docker compose --profile all restart && echo -e "${GREEN}服务已重启${RESET}"; else echo -e "${RED}目录不存在！${RESET}"; fi
}
logs_langbot() { 
    if [ -d "$BASE_DIR" ]; then cd "$BASE_DIR" && docker compose --profile all logs -f "$CONTAINER_NAME"; else echo -e "${RED}目录不存在！${RESET}"; fi
}

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态   : $status"
    echo -e "${YELLOW}访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}目录位置   : $BASE_DIR${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  LangBot  管理面板  ◈     ${RESET}"
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
        1) install_langbot ;;
        2) update_langbot ;;
        3) uninstall_langbot ;;
        4) start_langbot ;;
        5) stop_langbot ;;
        6) restart_langbot ;;
        7) logs_langbot ;;
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
