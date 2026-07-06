#!/bin/bash
# =================================================================
# TOTP-Share-Dashboard (持久化本地挂载 + 自动安全 Build) 自动化管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

APP_NAME="totp-share-dashboard"
BASE_DIR="/opt/totp-dashboard"
SRC_DIR="$BASE_DIR" 
REPO_URL="https://github.com/Time999-1/totp-share-dashboard.git"

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
    if ! command -v openssl &> /dev/null; then
        echo -e "${RED}错误: 未检测到 OpenSSL，请先安装 OpenSSL 用于生成加密密钥！${RESET}"
        exit 1
    fi
}

# 格式化 URL 中的 IP (如果是 IPv6 则加上方括号 [])
format_ip_for_url() {
    local ip="$1"
    if [[ "$ip" == *":"* ]]; then
        echo "[$ip]"
    else
        echo "$ip"
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
    local container_id=$(docker ps -q -f "name=$APP_NAME" -f "status=running" 2>/dev/null)

    if [[ -n "$container_id" ]]; then
        status="${GREEN}运行中${RESET}"
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8000/tcp") 0).HostPort}}' "$container_id" 2>/dev/null)
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

    echo -e "${CYAN}====== 1. 端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入本地映射端口 (127.0.0.1:端口) [默认: 8787]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8787"

    # 创建并克隆仓库
    mkdir -p "$SRC_DIR"
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "\n${YELLOW}正在克隆 TOTP Dashboard 官方 GitHub 仓库...${RESET}"
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

    # 自动化处理环境变量
    if [ ! -f ".env" ]; then
        echo -e "\n${YELLOW}正在自动为您生成高强度安全凭证并配置 .env ...${RESET}"
        cp .env.example .env 2>/dev/null
        
        AUTO_PASS=$(openssl rand -base64 12)
        AUTO_SECRET_1=$(openssl rand -hex 16)
        AUTO_SECRET_2=$(openssl rand -hex 16)

        sed -i "s/ADMIN_PASSWORD=.*/ADMIN_PASSWORD=$AUTO_PASS/g" .env
        sed -i "s/SESSION_SECRET=.*/SESSION_SECRET=$AUTO_SECRET_1/g" .env
        sed -i "s/APP_ENCRYPTION_KEY=.*/APP_ENCRYPTION_KEY=$AUTO_SECRET_2/g" .env
        
        sed -i "s/TRUST_PROXY=.*/TRUST_PROXY=true/g" .env
        sed -i "s/COOKIE_SECURE=.*/COOKIE_SECURE=true/g" .env
        
        if ! grep -q "TZ=" .env; then
            echo "TZ=Asia/Shanghai" >> .env
        fi
    else
        echo -e "\n${GREEN}已检测到现有的 .env 配置文件，跳过覆盖以保护您的凭证。${RESET}"
    fi

    # 预先在宿主机创建 data 目录，并赋予权限（防止挂载后因容器内非 root 用户导致权限拒绝）
    echo -e "${YELLOW}正在预热创建本地挂载数据目录并配置权限...${RESET}"
    mkdir -p "$SRC_DIR/data"
    chmod -R 777 "$SRC_DIR/data"

    # 动态写入【本地绝对路径挂载】的 docker-compose.yml 
    echo -e "${YELLOW}正在动态构建 docker-compose.yml 文件...${RESET}"
    cat <<EOF > docker-compose.yml
services:
  totp-dashboard:
    build: .
    container_name: $APP_NAME
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "127.0.0.1:$custom_port:8000"
    volumes:
      - ./data:/app/data
    security_opt:
      - no-new-privileges:true
EOF

    # 完美对齐官方启动命令并热重编
    echo -e "\n${YELLOW}正在执行容器集群 Build 编译并启动...${RESET}"
    docker compose up -d --build

    echo -e "${YELLOW}正在等待容器集群初始化拉起服务 (约 5 秒)...${RESET}"
    sleep 5

    # 补充跑一次本地挂载目录权限，确保万无一失
    chmod -R 777 "$SRC_DIR/data" 2>/dev/null

    get_status_info

    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")
    
    CURRENT_PASS=$(grep "ADMIN_PASSWORD=" .env | cut -d'=' -f2)
    CURRENT_USER=$(grep "ADMIN_USERNAME=" .env | cut -d'=' -f2)
    [[ -z "$CURRENT_USER" ]] && CURRENT_USER="admin"

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}    TOTP-Share-Dashboard 本地挂载编译启动成功！    ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}面板本地代理监听 : 127.0.0.1:${custom_port}${RESET}"
    echo -e "${YELLOW}1Panel反代建议   : 将反代后端指向 127.0.0.1:${custom_port}${RESET}"
    echo -e "${YELLOW}宿主数据挂载路径 : ${SRC_DIR}/data （可直接在此备份db）${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${CYAN}🔐 系统自动为您分配的初始化凭证：${RESET}"
    echo -e "   - 管理员账号 : ${GREEN}${CURRENT_USER}${RESET}"
    echo -e "   - 管理员密码 : ${GREEN}${CURRENT_PASS}${RESET}"
    echo -e "${RED}⚠️  注意：因开启了 COOKIE_SECURE，1Panel 反代必须配置 SSL(HTTPS) 才能正常登录！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新：拉取最新源码 + 重新 Build
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
    
    echo -e "${YELLOW}正在重新编译镜像并进行平滑热更新...${RESET}"
    docker compose up -d --build --remove-orphans
    # 保持本地挂载目录权限
    chmod -R 777 "$SRC_DIR/data" 2>/dev/null
    echo -e "${GREEN}容器更新并重编完成！${RESET}"
}

# 卸载
uninstall_translate() {
    echo -ne "${RED}确定要停止并卸载 TOTP Dashboard 容器集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -d "$SRC_DIR/.git" ]; then
            cd "$SRC_DIR" && docker compose down
            echo -e "${GREEN}容器与网络已被安全停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同步连根拔除本地【所有加密密钥、代码以及挂载的数据库TOTP数据】？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}宿主机本地所有源码与挂载数据已被彻底清除！${RESET}"
            fi
        else
            echo -e "${YELLOW}未检测到运行中的 compose 环境，跳过物理删除。${RESET}"
        fi
    fi
}

# 基于 Compose 生命周期的联动控制
start_translate() { cd "$SRC_DIR" && docker compose start && echo -e "${GREEN}容器已全面启动${RESET}"; }
stop_translate() { cd "$SRC_DIR" && docker compose stop && echo -e "${YELLOW}容器已安全停止${RESET}"; }
restart_translate() { cd "$SRC_DIR" && docker compose restart && echo -e "${GREEN}容器已平滑重启${RESET}"; }
logs_translate() { cd "$SRC_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    if [ -f "$SRC_DIR/.env" ]; then
        CURRENT_USER=$(grep "ADMIN_USERNAME=" "$SRC_DIR/.env" | cut -d'=' -f2)
        CURRENT_PASS=$(grep "ADMIN_PASSWORD=" "$SRC_DIR/.env" | cut -d'=' -f2)
    fi
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}运行状态         : $status"
    echo -e "${YELLOW}监听端口         : ${webui_port}"
    echo -e "${YELLOW}面板本地代理监听 : 127.0.0.1:${webui_port}${RESET}"
    echo -e "${YELLOW}宿主数据挂载路径 : ${SRC_DIR}/data"
    echo -e "${YELLOW}管理员账号       : ${CURRENT_USER:-admin}"
    echo -e "${YELLOW}管理员密码       : ${CURRENT_PASS:-未生成}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}   ◈ TOTP-Share-Dashboard 面板 ◈   ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}集群状态 :${RESET} $status"
    echo -e "${GREEN}内部端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
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
