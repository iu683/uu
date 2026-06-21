#!/bin/bash
# =================================================================
# Emby-In-One 工具箱 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="emby-in-one"
BASE_DIR="/opt/emby-in-one"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
CONFIG_FILE="$BASE_DIR/config/config.yaml"

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

# 动态获取容器状态、映射端口和数据目录
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取镜像名称/版本
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="本地构建 (Local Build)"

        # 从容器状态提取 WebUI 端口（容器内部默认监听的是 8096 端口）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8096/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        # 兜底获取第一个绑定的端口
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8096"
    else
        # 容器未安装/未部署时的返回值
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
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

# 部署 Emby-In-One
install_utils() {
    check_dependencies
    
    # 创建项目基础目录结构
    mkdir -p "$BASE_DIR"/{config,data}

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 端口配置
    echo -ne "${YELLOW}请输入 Emby-In-One 访问端口 (宿主机端口) [默认: 8096]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8096"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 密码配置
    echo -ne "${YELLOW}请输入首次启动的管理面板初始密码 [默认: admin123]: ${RESET}"
    read -r admin_pwd
    [[ -z "$admin_pwd" ]] && admin_pwd="admin123"

    # 1. 克隆或同步源码（【修复点】：进入目录后克隆到当前点，兼容非空目录）
    echo -e "${YELLOW}正在拉取 Emby-In-One 源码仓库...${RESET}"
    if [ -d "$BASE_DIR/.git" ]; then
        cd "$BASE_DIR" && git pull
    else
        cd "$BASE_DIR" && git clone https://github.com/ArizeSky/Emby-In-One.git .
    fi

    # 再一次检查关键文件，确保拉取成功
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 源码拉取失败，未找到 docker-compose.yml！请检查网络后重试。${RESET}"
        return
    fi

    # 2. 动态生成符合要求的 config.yaml 配置文件
    echo -e "${YELLOW}正在生成初始配置文件 config.yaml...${RESET}"
    cat <<EOF > "$CONFIG_FILE"
server:
  port: 8096
  name: "Emby-In-One"
  # trustProxy: true        # 部署在反向代理（Nginx/Caddy 等）后面时设为 true

admin:
  username: "admin"
  password: "${admin_pwd}" # 首次启动后自动加密存储

playback:
  mode: "proxy"

timeouts:
  api: 30000
  global: 15000
  login: 10000
  healthCheck: 10000
  healthInterval: 60000

proxies: []
upstream: []
EOF

    # 3. 修正 docker-compose.yml 的端口映射以匹配用户输入的端口
    echo -e "${YELLOW}正在微调 docker-compose.yml 端口映射...${RESET}"
    sed -i "s/- \"[0-9]*:8096\"/- \"${custom_port}:8096\"/g" "$COMPOSE_FILE" 2>/dev/null

    echo -e "${YELLOW}正在通过 Docker Compose 构建并启动服务...${RESET}"
    cd "$BASE_DIR" && docker compose build
    docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    Emby-In-One 部署成功！      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}客户端连接地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}后台管理面板   : http://${DETECT_IP}:${custom_port}/admin${RESET}"
    echo -e "${YELLOW}初始管理账号   : admin${RESET}"
    echo -e "${YELLOW}初始管理密码   : ${admin_pwd}${RESET}"
    echo -e "${YELLOW}配置文件路径   : $CONFIG_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 Emby-In-One（源码拉取并重新编译构建）
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到项目，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新源码并重新构建镜像...${RESET}"
    cd "$BASE_DIR" && git pull
    docker compose build
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新并构建完成！服务已处于最新状态。${RESET}"
}

# 卸载 Emby-In-One
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 Emby-In-One 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地数据与核心配置文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}项目目录及数据已彻底清理。${RESET}"
            fi
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
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}部署工作目录   : ${BASE_DIR}${RESET}"
    echo -e "${YELLOW}客户端连接地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}后台管理面板   : http://${DETECT_IP}:${webui_port}/admin${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Emby-In-One 管理面板 ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动 (源码构建)${RESET}"
    echo -e "${GREEN}2. 更新源码并重构${RESET}"
    echo -e "${GREEN}3. 卸载容器与删除${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置状态${RESET}"
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
