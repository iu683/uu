#!/bin/bash
# =================================================================
# BAIDUCHAT2API (官方原生 Clone + 环境变量 Build) 自动化管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

APP_NAME="wenxin2api"
BASE_DIR="/opt/baiduchat2api"
# 直接将面板和源码放在一起
SRC_DIR="$BASE_DIR" 
REPO_URL="https://github.com/XxxXTeam/baiduchat2api.git"

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
    # 优先从根目录的 .env 文件中读取之前自定义过的端口
    if [ -f "$SRC_DIR/.env" ]; then
        webui_port=$(grep "WENXIN_PORT=" "$SRC_DIR/.env" | cut -d'=' -f2)
    fi

    local container_id=$(docker ps -q -f "name=wenxin2api" -f "status=running" 2>/dev/null)

    if [[ -n "$container_id" ]]; then
        status="${GREEN}运行中${RESET}"
        # 如果 .env 没读到，降级使用 docker inspect 抓取
        if [[ -z "$webui_port" ]]; then
            webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8000/tcp") 0).HostPort}}' "$container_id" 2>/dev/null)
            [[ -z "$webui_port" ]] && webui_port="8000"
        fi
    else
        if [ -d "$SRC_DIR/.git" ]; then
            status="${RED}已停止${RESET}"
        else
            status="${RED}未部署${RESET}"
        fi
        [[ -z "$webui_port" ]] && webui_port="N/A"
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

# 部署核心逻辑
install_translate() {
    check_dependencies

    echo -e "${CYAN}====== 1. 端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 百度转API 映射端口 (对应 WENXIN_PORT) [默认: 8000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8000"

    echo -e "\n${CYAN}====== 2. 安全配置 ======${RESET}"
    echo -ne "${YELLOW}请设置你的公网访问 API Key (例如 sk-123456) [留空则不启用鉴权]: ${RESET}"
    read -r custom_key

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

    # 处理 API Key 数组格式
    if [[ -z "$custom_key" ]]; then
        toml_keys="[]"
    else
        toml_keys="[\"$custom_key\"]"
    fi

    # 动态写入适配支持自定义端口与挂载的 docker-compose.yml
    cat <<EOF > docker-compose.yml

services:
  wenxin2api:
    build: .
    image: wenxin2api:latest
    container_name: wenxin2api
    restart: unless-stopped
    ports:
      - "\${WENXIN_PORT:-8000}:8000"
    volumes:
      - ./config.toml:/app/config.toml:ro
      - ./cookies.json:/app/cookies.json
EOF

    # 动态生成配套的 config.toml
    cat <<EOF > config.toml
[cookies]
value = ""

[server]
host = "0.0.0.0"
port = 8000

[auth]
api_keys = $toml_keys

[models]
wenxin = "ernie-4.5"
deepseek_r1 = "deepseek-r1"
dsv4pro = "deepseek-v4-pro"

[headers]
user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

[cookie_persistence]
cookie_file = "cookies.json"
auto_save_cookies = true

[context]
fresh_conversation = true
max_chars = 12000
max_messages = 16
max_message_chars = 2000

[options]
default_model = "ernie-4.5"
stream = true
EOF

    # 初始化被挂载的为空 JSON 文件，防止 docker 将其识别为目录
    touch cookies.json
    chmod 666 cookies.json

    # 将自定义端口写入持久化环境文件
    if [ -f ".env" ]; then
        sed -i '/^WENXIN_PORT=/d' .env
        echo "WENXIN_PORT=$custom_port" >> .env
    else
        echo "WENXIN_PORT=$custom_port" > .env
    fi

    # 执行集群编译启动
    echo -e "\n${YELLOW}正在执行原生编译启动命令...${RESET}"
    WENXIN_PORT=$custom_port docker compose up -d --build

    echo -e "${YELLOW}正在等待容器集群 Build 编译并拉起服务 (约 5 秒)...${RESET}"
    sleep 5

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}        BAIDUCHAT2API 编译并启动成功！              ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}API 接口地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    if [[ -n "$custom_key" ]]; then
        echo -e "${YELLOW}预设鉴权密钥 : ${custom_key}${RESET}"
    fi
    echo -e "${YELLOW}项目所在路径 : ${SRC_DIR}${RESET}"
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
    [[ "$current_port" == "N/A" || -z "$current_port" ]] && current_port="8000"

    echo -e "${YELLOW}正在同步最新的远程官方代码...${RESET}"
    cd "$SRC_DIR" && git pull
    
    if [ -f ".env" ]; then
        sed -i '/^WENXIN_PORT=/d' .env
        echo "WENXIN_PORT=$current_port" >> .env
    fi

    echo -e "${YELLOW}正在使用原自定义端口 [$current_port] 重编镜像并热更新...${RESET}"
    WENXIN_PORT=$current_port docker compose up -d --build --remove-orphans
    echo -e "${GREEN}集群更新并重编完成！${RESET}"
}

# 彻底卸载
uninstall_translate() {
    echo -ne "${RED}确定要停止并卸载 BAIDUCHAT2API 容器集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -d "$SRC_DIR/.git" ]; then
            cd "$SRC_DIR" && docker compose down
            echo -e "${GREEN}容器与网络已被安全停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同步连根拔除本地克隆的【全部源码及环境配置】？(y/n): ${RESET}"
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

# 联动生命周期
start_translate() { cd "$SRC_DIR" && docker compose start && echo -e "${GREEN}集群已全面启动${RESET}"; }
stop_translate() { cd "$SRC_DIR" && docker compose stop && echo -e "${YELLOW}集群已安全停止${RESET}"; }
restart_translate() { cd "$SRC_DIR" && docker compose restart && echo -e "${GREEN}集群已平滑重启${RESET}"; }
logs_translate() { cd "$SRC_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}集群运行状态     : $status"
    echo -e "${YELLOW}服务请求地址     : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN} ◈ BAIDUCHAT2API 自动化管理面板 ◈   ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
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
