#!/bin/bash
# =================================================================
# 1Shell 运维助手 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="1shell"
# 固定安装到 /opt/1Shell
TARGET_DIR="/opt/1Shell"
COMPOSE_FILE="$TARGET_DIR/docker-compose.yml"
ENV_FILE="$TARGET_DIR/.env"

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
        echo -e "${RED}由于 Linux 机制，权限变更需要重新加载组。请执行 'newgrp docker' 。${RESET}"
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

    # 2. 如果容器存在，从环境或容器中提取端口
    if [ -f "$ENV_FILE" ]; then
        webui_port=$(grep "^PORT=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '\r ')
    fi
    [[ -z "$webui_port" ]] && webui_port="3301"
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

# 按照官方指引克隆并部署 1Shell
install_1shell() {
    check_dependencies
    
    echo -e "${CYAN}====== 开始执行 1Shell 克隆部署 ======${RESET}"
    
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
            git clone https://github.com/weidu12123/1Shell.git "$TARGET_DIR"
        fi
    else
        git clone https://github.com/weidu12123/1Shell.git "$TARGET_DIR"
    fi

    if [ ! -f "$TARGET_DIR/docker-compose.yml" ]; then
        echo -e "${RED}错误: 克隆失败或未在 $TARGET_DIR 中找到 docker-compose.yml！${RESET}"
        return
    fi

    # 准备 .env 文件
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${YELLOW}正在创建 .env 配置文件...${RESET}"
        cp "$TARGET_DIR/.env.example" "$ENV_FILE"
    fi

    # 配置环境变量交互
    echo -e "${CYAN}----------------------------------${RESET}"
    echo -e "${YELLOW}开始初始化 1Shell 核心配置参数：${RESET}"
    
    echo -ne "${YELLOW}1. 请输入服务监听端口 [默认: 3301]: ${RESET}"
    read -r custom_port
    [[ -n "$custom_port" ]] && sed -i "s|^PORT=.*|PORT=$custom_port|g" "$ENV_FILE"

    echo -ne "${YELLOW}2. 请输入 OpenAI 兼容 API 基础地址 [默认: https://api.openai.com/v1]: ${RESET}"
    read -r api_base
    [[ -n "$api_base" ]] && sed -i "s|^OPENAI_API_BASE=.*|OPENAI_API_BASE=$api_base|g" "$ENV_FILE"

    echo -ne "${YELLOW}3. 请输入 OpenAI API Key: ${RESET}"
    read -r api_key
    [[ -n "$api_key" ]] && sed -i "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=$api_key|g" "$ENV_FILE"

    echo -ne "${YELLOW}4. 请输入使用的模型名称 [默认: gpt-4o]: ${RESET}"
    read -r model_name
    [[ -n "$model_name" ]] && sed -i "s|^OPENAI_MODEL=.*|OPENAI_MODEL=$model_name|g" "$ENV_FILE"

    echo -ne "${YELLOW}5. 请输入 Web 控制台管理员用户名 [默认: admin]: ${RESET}"
    read -r username
    [[ -n "$username" ]] && sed -i "s|^APP_LOGIN_USERNAME=.*|APP_LOGIN_USERNAME=$username|g" "$ENV_FILE"

    echo -ne "${YELLOW}6. 请输入 Web 控制台管理员密码 (必填以确保能远程访问): ${RESET}"
    read -r password
    [[ -n "$password" ]] && sed -i "s|^APP_LOGIN_PASSWORD=.*|APP_LOGIN_PASSWORD=$password|g" "$ENV_FILE"

    # 启动与构建容器
    cd "$TARGET_DIR" || return
    echo -e "${YELLOW}正在构建 1Shell 镜像并启动容器 (首次构建需要一点时间)...${RESET}"
    docker compose up -d --build

    echo -e "${YELLOW}等待容器启动 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)
    get_status_info

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      1Shell 部署启动指令已执行！    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}控制台访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}管理员用户名   : $username${RESET}"
    echo -e "${YELLOW}管理员密码     : $password${RESET}"
    echo -e "${RED}安全提示: 默认挂载为宿主机各运维目录的只读(:ro)权限。若需文件修改功能，请在面板中添加该机器作为“SSH 主机”操作。${RESET}"
    echo -e "${GREEN}================================${RESET}"
    
    cd - > /dev/null || return
}

# 更新 1Shell 代码并重新编译
update_1shell() {
    if [ ! -d "$TARGET_DIR" ]; then
        echo -e "${RED}错误: 未检测到官方目录 $TARGET_DIR，请先执行选项 1 部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取 Git 最新代码...${RESET}"
    cd "$TARGET_DIR" && git pull
    echo -e "${YELLOW}检测到代码更新，正在重新构建并重启容器...${RESET}"
    docker compose up -d --build --remove-orphans
    echo -e "${GREEN}1Shell 重新构建与升级完成！${RESET}"
    cd - > /dev/null || return
}

# 卸载 1Shell 容器
uninstall_1shell() {
    if [ ! -d "$TARGET_DIR" ]; then
        echo -e "${RED}错误: 未检测到目录 $TARGET_DIR！${RESET}"
        return
    fi
    echo -ne "${YELLOW}确定要停止并删除 1Shell 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        cd "$TARGET_DIR" || return
        docker compose down
        echo -e "${GREEN}1Shell 容器已停止并移除。${RESET}"
        
        echo -ne "${YELLOW}是否彻底删除 /opt/1Shell 源码及持久化数据文件夹？(y/n): ${RESET}"
        read -r delete_dir
        if [ "$delete_dir" = "y" ] || [ "$delete_dir" = "Y" ]; then
            cd - > /dev/null || return
            rm -rf "$TARGET_DIR"
            echo -e "${GREEN}1Shell 的所有文件与数据已彻底清理。${RESET}"
        else
            cd - > /dev/null || return
        fi
    fi
}

start_1shell() { 
    if [ -d "$TARGET_DIR" ]; then cd "$TARGET_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}" && cd - > /dev/null; fi
}
stop_1shell() { 
    if [ -d "$TARGET_DIR" ]; then cd "$TARGET_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}" && cd - > /dev/null; fi
}
restart_1shell() { 
    if [ -d "$TARGET_DIR" ]; then cd "$TARGET_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}" && cd - > /dev/null; fi
}
logs_1shell() { 
    if [ -d "$TARGET_DIR" ]; then cd "$TARGET_DIR" && docker compose logs -f "$CONTAINER_NAME"; cd - > /dev/null; fi
}

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}控制台访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}安装绝对路径   : $TARGET_DIR${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  1Shell 管理面板  ◈   ${RESET}"
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
        1) install_1shell ;;
        2) update_1shell ;;
        3) uninstall_1shell ;;
        4) start_1shell ;;
        5) stop_1shell ;;
        6) restart_1shell ;;
        7) logs_1shell ;;
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
