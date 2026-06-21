#!/bin/bash
# =================================================================
# Outlook-Email-Plus 邮件增强服务 Docker Compose 独立管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="outlook-email-plus"
BASE_DIR="/opt/outlook-email-plus"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态与映射端口
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        local health=$(docker inspect --format='{{json .State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null | tr -d '"')
        if [[ "$health" == "healthy" ]]; then
            status="${GREEN}运行中 (健康)${RESET}"
        elif [[ "$health" == "starting" ]]; then
            status="${YELLOW}启动中 (健康检查未就绪)${RESET}"
        elif [[ "$health" == "unhealthy" ]]; then
            status="${RED}运行异常 (不健康)${RESET}"
        else
            status="${GREEN}运行中${RESET}"
        fi
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="ghcr.io/zeropointsix/outlook-email-plus:latest"
        
        # 动态抓取映射到容器 5000 端口的宿主机实际端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "5000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="5001"
        port_display="${webui_port}"
    else
        img_version="${RED}未安装${RESET}"
        port_display="N/A"
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

# 部署服务
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 目录物理隔离与赋权 ======${RESET}"
    # 预创建全量依赖物理目录
    echo -e "${YELLOW}正在宿主机上预构建数据卷及运行时所需的物理目录...${RESET}"
    mkdir -p "$BASE_DIR/data" "$BASE_DIR/.runtime" "$BASE_DIR/plugins"
    chmod -R 777 "$BASE_DIR/data" "$BASE_DIR/.runtime" "$BASE_DIR/plugins"

    echo -e "\n${CYAN}====== 2. 安全与网络端口配置 ======${RESET}"
    
    # 自定义外部映射端口
    echo -ne "${YELLOW}请输入外部宿主机访问端口 [默认: 5001]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="5001"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 引导修改默认初始密码
    echo -ne "${YELLOW}请设置您的首次登录密码 [默认: admin123]: ${RESET}"
    read -r login_pwd
    [[ -z "$login_pwd" ]] && login_pwd="admin123"

    # 自动生成 64 位的高强度安全 SECRET_KEY
    local generated_key=$(head -c 32 /dev/urandom | xxd -p | tr -d '[:space:]')

    # 生成配置文件 .env (实现硬编码解耦)
    echo -e "${YELLOW}正在注入并生成环境变量配置文件 .env ...${RESET}"
    cat <<EOF > "$ENV_FILE"
# 自动生成的强加密密钥（用于加密数据库敏感信息）
SECRET_KEY=${generated_key}

# 登录密码（首次启动后会自动哈希存储）
LOGIN_PASSWORD=${login_pwd}

# 是否允许在“系统设置”页面修改登录密码
ALLOW_LOGIN_PASSWORD_CHANGE=true

# 容器对内映射及 Flask 生产环境配置
APP_PORT=${custom_port}
PORT=5000
HOST=0.0.0.0
FLASK_ENV=production

# 后台定时调度器配置
SCHEDULER_AUTOSTART=true
DATABASE_PATH=data/outlook_accounts.db

# GPTMail 临时邮箱基础设施配置
GPTMAIL_BASE_URL=https://mail.chatgpt.org.uk
GPTMAIL_API_KEY=gpt-test

# Watchtower HTTP API 鉴权 Token
WATCHTOWER_HTTP_API_TOKEN=outlook-mail-plus-watchtower-default
EOF

    # 生成解耦后的标准 docker-compose.yml
    echo -e "${YELLOW}正在生成标准 docker-compose.yml 结构体...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  app:
    image: ghcr.io/zeropointsix/outlook-email-plus:\${IMAGE_TAG:-latest}
    container_name: ${CONTAINER_NAME}
    ports:
      - "\${APP_PORT:-5001}:5000"
    env_file:
      - .env
    environment:
      SECRET_KEY: "\${SECRET_KEY:?请在 .env 中设置 SECRET_KEY}"
      WATCHTOWER_HTTP_API_TOKEN: "\${WATCHTOWER_HTTP_API_TOKEN:-outlook-mail-plus-watchtower-default}"
    volumes:
      - ./data:/app/data
      - ./.runtime:/app/.runtime
      - ./plugins:/app/plugins
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: [
        "CMD",
        "python",
        "-c",
        "import urllib.request as u; u.urlopen('http://localhost:5000/healthz', timeout=4).read()"
      ]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    networks:
      - outlook-net

networks:
  outlook-net:
    driver: bridge
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动容器...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}建立健康检查及数据库同步缓冲 (约5秒)...${RESET}"
    sleep 5

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}         Outlook-Email-Plus 部署成功！               ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}服务访问地址     : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}初始管理员账号   : admin${RESET}"
    echo -e "${YELLOW}初始管理员密码   : ${login_pwd}${RESET}"
    echo -e "${CYAN}已为您动态生成的 SECRET_KEY: ${generated_key}${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${CYAN}💡 提示: 所有的数据库与插件均已完美在 ${BASE_DIR} 下实现持久化。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端仓库拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！服务已无缝重启并应用最新镜像。${RESET}"
}

# 卸载组件
uninstall_utils() {
    echo -e "${RED}警告: 卸载如果清理数据，将永久丢失您的所有绑定的 Outlook 账号资产和插件配置！${RESET}"
    echo -ne "${YELLOW}确定要卸载并删除容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}【高风险】是否同时彻底删除本地全量挂载的账户 SQLite 数据库与插件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有 Outlook 历史核心数据已被彻底销毁。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已拉起运行${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已挂起停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已完成重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${port_display}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈  Outlook-Email-Plus 面板 ◈ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${port_display}${RESET}"
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
