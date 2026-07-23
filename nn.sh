#!/bin/bash
# =================================================================
# Aegis-Relay Emby 多服务器反向代理管理面板 自动化管理面板
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

APP_NAME="aegis-relay"
BASE_DIR="/opt/aegis-relay"
SRC_DIR="$BASE_DIR"
REPO_URL="https://github.com/bear4f/aegis-relay.git"

# 检测基础依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! command -v git &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Git，请先安装 Git！${RESET}"
        exit 1
    fi
    if ! command -v openssl &> /dev/null; then
        echo -e "${RED}错误: 未检测到 OpenSSL，请先安装 OpenSSL！${RESET}"
        exit 1
    fi
}

# 动态获取服务端口与运行状态
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        data_dir="N/A"
        return 0
    fi
    local container_id=$(docker ps -q -f "name=aegis-relay" -f "status=running" 2>/dev/null)

    if [[ -n "$container_id" ]]; then
        status="${GREEN}运行中${RESET}"
        admin_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "9080/tcp") 0).HostPort}}' "$container_id" 2>/dev/null)
        proxy_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$container_id" 2>/dev/null)
        [[ -z "$admin_port" ]] && admin_port="9080"
        [[ -z "$proxy_port" ]] && proxy_port="8080"
    else
        if [ -d "$SRC_DIR/.git" ]; then
            status="${RED}已停止${RESET}"
        else
            status="${RED}未部署${RESET}"
        fi
        admin_port="N/A"
        proxy_port="N/A"
    fi
}

# 获取服务器公网 IP
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

    echo -e "${CYAN}====== 1. 端口与网络配置 ======${RESET}"

    echo -ne "${YELLOW}管理后台绑定 IP (0.0.0.0 为全网开放，127.0.0.1 为本地独占) [默认: 0.0.0.0]: ${RESET}"
    read -r admin_pub_ip
    [[ -z "$admin_pub_ip" ]] && admin_pub_ip="0.0.0.0"

    echo -ne "${YELLOW}代理服务绑定 IP (0.0.0.0 为全网开放，127.0.0.1 为本地独占) [默认: 0.0.0.0]: ${RESET}"
    read -r proxy_pub_ip
    [[ -z "$proxy_pub_ip" ]] && proxy_pub_ip="0.0.0.0"

    # 克隆官方仓库到当前工作目录
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "\n${YELLOW}正在克隆 Aegis-Relay GitHub 仓库...${RESET}"
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
        echo -e "\n${GREEN}检测到本地已存在仓库，正在同步最新代码...${RESET}"
        cd "$SRC_DIR" && git pull
    fi

    cd "$SRC_DIR"

    # 预先创建本地映射目录并补全读写权限（对应容器 10001 用户）
    echo -e "${YELLOW}正在创建并初始化本地数据存储目录 (${SRC_DIR}/data)...${RESET}"
    mkdir -p "$SRC_DIR/data"
    chmod -R 777 "$SRC_DIR/data"

    # 生成安全随机 Token 与 Key
    echo -e "${YELLOW}正在自动生成系统安全密钥与随机路径...${RESET}"
    MASTER_KEY_VAL=$(openssl rand -hex 32)
    SETUP_TOKEN_VAL=$(openssl rand -hex 16)
    RANDOM_ADMIN_PATH="admin_$(openssl rand -hex 6)"

    # 写入 .env 配置文件
    echo -e "${YELLOW}正在配置 .env 环境变量...${RESET}"
    cat <<EOF > .env
APP_MASTER_KEY=${MASTER_KEY_VAL}
SETUP_TOKEN=${SETUP_TOKEN_VAL}
ADMIN_PATH=${RANDOM_ADMIN_PATH}
ADMIN_HOST=0.0.0.0
ADMIN_PORT=9080
ADMIN_PUBLISH_IP=${admin_pub_ip}
PROXY_HOST=0.0.0.0
PROXY_PORT=8080
PROXY_PUBLISH_IP=${proxy_pub_ip}
SECURE_COOKIES=false
PUBLIC_BASE_URL=
LOCAL_PROXY_BASE_URL=
CERTIFICATE_EMAIL=
DATA_FILE=/app/data/aegis.enc.json
EOF

    # 编译并启动容器集群
    echo -e "\n${YELLOW}正在执行 Docker 编译并启动服务...${RESET}"
    docker compose up -d --build

    echo -e "${YELLOW}正在等待容器编译并拉起服务 (约 5 秒)...${RESET}"
    sleep 5

    chmod -R 777 "$SRC_DIR/data" 2>/dev/null

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}       Aegis-Relay 容器编译并启动成功！        ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}后台管理地址 : http://${DETECT_IP}:9080/${RANDOM_ADMIN_PATH}${RESET}"
    echo -e "${YELLOW}初始化 Token : ${SETUP_TOKEN_VAL}${RESET}"
    echo -e "${YELLOW}代理服务端口 : 8080${RESET}"
    echo -e "${YELLOW}本地数据路径 : ${SRC_DIR}/data${RESET}"
    echo -e "${YELLOW}项目所在路径 : ${SRC_DIR}${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${CYAN}🔑 首次安装登录提示：${RESET}"
    echo -e "${YELLOW}   - 访问后台需附带随机路径：/${RANDOM_ADMIN_PATH}${RESET}"
    echo -e "${YELLOW}   - 使用设置 Token (${SETUP_TOKEN_VAL}) 完成初始化账号注册。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 原生更新：拉取代码 + 重新 Build
update_translate() {
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "${RED}错误: 未检测到克隆的仓库，请先执行选项 1！${RESET}"
        return
    fi

    echo -e "${YELLOW}正在同步最新的远程官方代码...${RESET}"
    cd "$SRC_DIR" && git pull
    
    echo -e "${YELLOW}正在使用 docker compose 重编镜像并热更新...${RESET}"
    docker compose up -d --build --remove-orphans
    
    chmod -R 777 "$SRC_DIR/data" 2>/dev/null
    echo -e "${GREEN}Aegis-Relay 镜像更新并重编完成！${RESET}"
}

# 彻底卸载
uninstall_translate() {
    echo -ne "${RED}确定要停止并卸载 Aegis-Relay 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -d "$SRC_DIR/.git" ]; then
            cd "$SRC_DIR" && docker compose down
            echo -e "${GREEN}容器已被安全停止并移除。${RESET}"
            echo -ne "${YELLOW}是否彻底删除本地【源码、配置文件及 ./data 加密数据库】？(y/n): ${RESET}"
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

# 基于 Compose 文件的生命周期联动
start_translate() { cd "$SRC_DIR" && docker compose start && echo -e "${GREEN}Aegis-Relay 服务已启动${RESET}"; }
stop_translate() { cd "$SRC_DIR" && docker compose stop && echo -e "${YELLOW}Aegis-Relay 服务已停止${RESET}"; }
restart_translate() { cd "$SRC_DIR" && docker compose restart && echo -e "${GREEN}Aegis-Relay 服务已重启${RESET}"; }
logs_translate() { cd "$SRC_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}集群运行状态     : $status"
    echo -e "${YELLOW}代理监听端口     : ${proxy_port}"
    if [ -f "$SRC_DIR/.env" ]; then
        local admin_path_val=$(grep "^ADMIN_PATH=" "$SRC_DIR/.env" | cut -d '=' -f2-)
        local setup_token_val=$(grep "^SETUP_TOKEN=" "$SRC_DIR/.env" | cut -d '=' -f2-)
        echo -e "${YELLOW}后台管理地址     : http://${DETECT_IP}:${admin_port}/${admin_path_val}${RESET}"
        echo -e "${YELLOW}初始化 Token     : ${setup_token_val}${RESET}"
    else
        echo -e "${YELLOW}后台管理地址     : http://${DETECT_IP}:${admin_port}${RESET}"
    fi
    echo -e "${YELLOW}本地数据存储     : ${SRC_DIR}/data${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN} ◈AegisRelay Emby反向代理管理面板◈ ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}服务状态 :${RESET} $status"
    echo -e "${GREEN}管理端口 :${RESET} ${YELLOW}${admin_port}${RESET}"
    echo -e "${GREEN}代理端口 :${RESET} ${YELLOW}${proxy_port}${RESET}"
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
