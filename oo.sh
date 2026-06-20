#!/bin/bash
# =================================================================
# Twilight 影音工具箱 Docker Compose 运维管理面板（终极适配版）
# =================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/twilight"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! command -v git &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Git，请先安装 Git 依赖！${RESET}"
        exit 1
    fi
}

get_status_info() {
    if [ "$(docker ps -q -f name=twilight-webui)" ] || [ "$(docker ps -q -f name=twilight-backend)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=twilight-webui)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=twilight-webui)" ]; then
        if [ -f "$BASE_DIR/.env" ]; then
            webui_port=$(grep "^WEBUI_PORT=" "$BASE_DIR/.env" | cut -d'=' -f2)
        fi
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "twilight-webui" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3000"
    else
        webui_port="N/A"
    fi
}

get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://4.ip.sb"; do
        ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
    done
    echo "127.0.0.1" && return 0
}

install_utils() {
    check_dependencies
    
    if [ -d "$BASE_DIR/.git" ]; then
        echo -e "${YELLOW}检测到项目目录已存在，正在同步最新源码...${RESET}"
        cd "$BASE_DIR" && git pull
    else
        echo -e "${YELLOW}正在克隆 Twilight 项目源码到 $BASE_DIR ...${RESET}"
        git clone https://github.com/Prejudice-Studio/Twilight.git "$BASE_DIR"
        cd "$BASE_DIR"
    fi

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入前端对外访问端口 [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"

    echo -ne "${YELLOW}请输入 Emby 服务器地址 (例如 http://192.168.1.100:8096): ${RESET}"
    read -r emby_url

    echo -ne "${YELLOW}请输入 Emby API Token: ${RESET}"
    read -r emby_token

    echo -ne "${YELLOW}请输入管理员用户名 [默认: admin]: ${RESET}"
    read -r admin_user
    [[ -z "$admin_user" ]] && admin_user="admin"

    echo -ne "${YELLOW}请输入 PostgreSQL 数据库密码 [默认: twilight_pwd]: ${RESET}"
    read -r db_pwd
    [[ -z "$db_pwd" ]] && db_pwd="twilight_pwd"

    generated_secret=$(date +%s | sha256sum | base64 | head -c 32)

    # 1. 彻底斩断环境变量污染：让全局 .env 与 docker-compose 内部占位符完美咬合
    echo -e "${YELLOW}正在构建全局控制级 .env 配置文件...${RESET}"
    cat <<EOF > .env
# Twilight 全局精简部署变量
TWILIGHT_API_HOST=0.0.0.0
TWILIGHT_API_PORT=5000
SITE_NAME=Twilight
LOG_LEVEL=info
RUNTIME_LOG_LIMIT=5000

# 精准命中并覆盖 Compose 内置环境变量
POSTGRES_PASSWORD=${db_pwd}
ADMIN_USERNAMES=${admin_user}
BOT_INTERNAL_SECRET=${generated_secret}
WEBUI_PORT=${custom_port}
EOF

    # 2. 遵循官方 Quick Start 规范生成主 config.toml
    echo -e "${YELLOW}正在生成主功能配置文件...${RESET}"
    if [ -f "config.docker.toml" ]; then
        cp config.docker.toml config.toml
    elif [ -f "config.production.toml" ]; then
        cp config.production.toml config.toml
    fi

    # 3. 剥离密钥，写入私密覆盖配置
    cat <<EOF > config.local.toml
# Twilight Local Private Configuration (Overrides config.toml)
[Database]
postgres_password = "${db_pwd}"

[Emby]
emby_url = "${emby_url}"
emby_token = "${emby_token}"

[Security]
bot_internal_secret = "${generated_secret}"
EOF

    # 4. 前端环境变量处理
    if [ -f "webui/.env.example" ]; then
        cp webui/.env.example webui/.env
    else
        echo "VITE_API_BASE_URL=/api/v1" > webui/.env
        echo "NEXT_PUBLIC_SITE_NAME=Twilight" >> webui/.env
    fi

    # 5. 防冲突处理（规避 pnpm 锁文件 mismatch 报错）
    if [ -f "webui/Dockerfile" ]; then
        sed -i 's/pnpm install --frozen-lockfile/pnpm install/g' webui/Dockerfile
    fi

    # 6. 【核心重置】：格式化历史遗留的脏卷，强迫后端通过最新代码结构无感知建表
    echo -e "${RED}正在格式化清理此前失败的历史脏数据卷...${RESET}"
    docker compose down -v &>/dev/null

    echo -e "${YELLOW}正在编译并启动容器组...${RESET}"
    docker compose up -d --build

    echo -e "${YELLOW}等待服务进行最后的健康检查...${RESET}"
    sleep 8

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN}          Twilight 影音工具箱部署成功！         ${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW}前端访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}管理用户名     : ${admin_user}${RESET}"
    echo -e "${RED}⚠️  注意: 首次打开网页注册的第一个账号，名字必须叫: ${admin_user}${RESET}"
    echo -e "${GREEN}================================================${RESET}"
}

update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到项目，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端同步最新源码并重新打包...${RESET}"
    cd "$BASE_DIR" && git pull
    if [ -f "webui/Dockerfile" ]; then
        sed -i 's/pnpm install --frozen-lockfile/pnpm install/g' webui/Dockerfile
    fi
    docker compose up -d --build --remove-orphans
    echo -e "${GREEN}更新并构建完成！${RESET}"
}

uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 Twilight 容器组吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -d "$BASE_DIR" ]; then
            cd "$BASE_DIR" && docker compose down -v
            rm -rf "$BASE_DIR"
            echo -e "${GREEN}服务、配置文件及数据卷已彻底清理干净。${RESET}"
        fi
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }

logs_utils() {
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}         查看运行日志           ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 查看 后端 Go API 日志${RESET}"
    echo -e "${GREEN}2. 查看 前端 WebUI 日志${RESET}"
    echo -e "${GREEN}3. 查看 数据库 Postgres 日志${RESET}"
    echo -e "${GREEN}4. 查看 缓存 Redis 日志${RESET}"
    echo -e "${GREEN}5. 查看 容器组全部混合日志${RESET}"
    echo -e "${GREEN}0. 返回主菜单${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请选择要查看的日志组件: ${RESET}"
    read -r log_choice
    cd "$BASE_DIR" || return
    case "$log_choice" in
        1) docker compose logs -f twilight ;;
        2) docker compose logs -f webui ;;
        3) docker compose logs -f postgres ;;
        4) docker compose logs -f redis ;;
        5) docker compose logs -f ;;
        0) return ;;
        *) echo -e "${RED}无效参数${RESET}" ;;
    esac
}

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}主配置文件路径 : $BASE_DIR/config.toml"
    echo -e "${YELLOW}秘密配置文件路径: $BASE_DIR/config.local.toml${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  Twilight 核心面板  ◈     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 源码部署与构建${RESET}"
    echo -e "${GREEN}2. 拉取源码并更新${RESET}"
    echo -e "${GREEN}3. 卸载清除服务${RESET}"
    echo -e "${GREEN}4. 启动所有容器${RESET}"
    echo -e "${GREEN}5. 停止所有容器${RESET}"
    echo -e "${GREEN}6. 重启所有容器${RESET}"
    echo -e "${GREEN}7. 查看运行日志${RESET}"
    echo -e "${GREEN}8. 查看基本信息${RESET}"
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
