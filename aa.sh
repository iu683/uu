#!/bin/bash
# =================================================================
# fakabot 发卡机器人 (双容器高阶版 + 端口动态定制 + 智能配置) 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/fakabot"
SRC_DIR="$BASE_DIR"
CONFIG_FILE="$BASE_DIR/config.json"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
REPO_URL="https://github.com/yanguo888/fakabot.git"

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

# 动态获取服务状态
get_status_info() {
    local bot_run=$(docker ps -q -f name=^/fakabot$ -f status=running)
    local redis_run=$(docker ps -q -f name=^/fakabot-redis$ -f status=running)

    if [[ -n "$bot_run" && -n "$redis_run" ]]; then
        status="${GREEN}运行中 (机器人与 Redis 均健康)${RESET}"
        # 抓取 58001 端口对应的宿主机实际映射端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "58001/tcp") 0).HostPort}}' fakabot 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="58001"
    else
        if [ -d "$SRC_DIR/.git" ]; then
            status="${RED}已停止或健康检查未通过${RESET}"
        else
            status="${RED}未部署${RESET}"
        fi
        webui_port="N/A"
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

# 部署与引导
install_fakabot() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    # 1. 克隆官方仓库
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "\n${YELLOW}正在从 GitHub 远程仓库克隆 fakabot 最新源码...${RESET}"
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
        echo -e "\n${GREEN}检测到本地已存在源码，正在同步最新代码...${RESET}"
        cd "$SRC_DIR" && git pull
    fi

    cd "$SRC_DIR"

    # 2. 智能配置引导
    echo -e "\n${CYAN}====== 🛠️  fakabot 智能配置引导 ======${RESET}"
    
    echo -ne "${YELLOW}1. 请输入你的 Telegram BOT_TOKEN: ${RESET}"
    read -r tg_token
    while [[ -z "$tg_token" ]]; do
        echo -ne "${RED}Token 不能为空，请重新输入: ${RESET}"
        read -r tg_token
    done

    echo -ne "${YELLOW}2. 请输入你的 Admin Telegram ID: ${RESET}"
    read -r tg_admin_id
    while [[ -z "$tg_admin_id" ]]; do
        echo -ne "${RED}Admin ID 不能为空，请重新输入: ${RESET}"
        read -r tg_admin_id
    done

    echo -ne "${YELLOW}3. 请输入 Web 服务的宿主机端口 1 [默认: 58001]: ${RESET}"
    read -r port_1
    [[ -z "$port_1" ]] && port_1="58001"

    echo -ne "${YELLOW}4. 请输入 Web 服务的宿主机端口 2 [默认: 58002]: ${RESET}"
    read -r port_2
    [[ -z "$port_2" ]] && port_2="58002"

    echo -ne "${YELLOW}5. 端口映射模式: 1.仅本地访问(127.0.0.1) 2.开启外网直接访问(0.0.0.0) [默认 1]: ${RESET}"
    read -r bind_mode
    if [[ "$bind_mode" == "2" ]]; then
        bind_ip="0.0.0.0"
    else
        bind_ip="127.0.0.1"
    fi

    # 3. 自动生成标准 config.json
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "\n${YELLOW}正在为您初始化生成标准的 config.json...${RESET}"
        cat <<EOF > "$CONFIG_FILE"
{
  "BOT_TOKEN": "${tg_token}",
  "ADMIN_ID": ${tg_admin_id},
  "DOMAIN": "http://${bind_ip}:${port_1}",
  "ORDER_TIMEOUT_SECONDS": 3600,
  "PAYMENTS": {},
  "START": {
    "cover_url": "https://img.example/start-cover.jpg",
    "title": "欢迎选购",
    "intro": "这里是商店简介或活动文案。"
  },
  "SHOW_QR": true,
  "PRODUCTS": []
}
EOF
    fi

    # 创建必要的本地挂载数据文件夹，并赋予足够权限
    mkdir -p "$BASE_DIR/data"
    chmod -R 777 "$BASE_DIR/data"

    # 4. 原汁原味生成带你自定义端口的 docker-compose.yml
    echo -e "${YELLOW}正在完美对齐并构建高级版 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  redis:
    image: redis:7-alpine
    container_name: fakabot-redis
    restart: unless-stopped
    command: redis-server --appendonly yes --maxmemory 128mb --maxmemory-policy allkeys-lru
    volumes:
      - redis_data:/data
    networks:
      - fakabot_network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "2"

  sp_shop_bot:
    build: .
    container_name: fakabot
    restart: unless-stopped
    environment:
      - TZ=Asia/Shanghai
      - REDIS_HOST=redis
      - REDIS_PORT=6379
    user: "0:0"
    ports:
      - "${bind_ip}:${port_1}:58001"
      - "${bind_ip}:${port_2}:58002"
    volumes:
      - ./config.json:/app/config.json:ro
      - ./data:/app/data
    networks:
      - fakabot_network
    depends_on:
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "python -c 'import urllib.request,sys; sys.exit(0 if urllib.request.urlopen(\"http://127.0.0.1:58001/health\", timeout=3).read().strip()==b\"ok\" else 1)'"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 10s
    stop_grace_period: 20s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  fakabot_network:
    driver: bridge

volumes:
  redis_data:
    driver: local
EOF

    # 5. 原生一键拉起并编译
    echo -e "\n${YELLOW}正在通过原厂参数本地现场编译 Build 整个双容器集群...${RESET}"
    docker compose up -d --build

    echo -e "${YELLOW}高级健康检查预热中，请等待集群完全上线 (约 12 秒)...${RESET}"
    sleep 12

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}        fakabot 高级版集群本地编译构建成功！        ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}绑定 IP 模式   : ${bind_ip} (${bind_mode})${RESET}"
    echo -e "${YELLOW}健康服务端口 1 : ${port_1}${RESET}"
    echo -e "${YELLOW}业务通知端口 2 : ${port_2}${RESET}"
    if [[ "$bind_ip" == "127.0.0.1" ]]; then
        echo -e "${CYAN}💡 提示：当前端口绑定在本地，安全级别高，请使用 Nginx 等进行反代。${RESET}"
    else
        echo -e "${YELLOW}外网直连地址   : http://${DETECT_IP}:${port_1}/health${RESET}"
    fi
    echo -e "${GREEN}====================================================${RESET}"
}

# 高级：直接在面板里调用本地编辑器修改配置文件
edit_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}错误: 配置文件不存在，请先执行选项 1 部署！${RESET}"
        return
    fi
    echo -e "${CYAN}正在为你唤醒本地文本编辑器 (修改完后按 Ctrl+X 然后选 Y 保存退出)...${RESET}"
    sleep 1
    nano "$CONFIG_FILE" || vi "$CONFIG_FILE"
    echo -e "${YELLOW}检测到配置文件变更，正在热重启机器人集群...${RESET}"
    cd "$SRC_DIR" && docker compose restart sp_shop_bot
    echo -e "${GREEN}配置已成功热生效！${RESET}"
}

# 更新代码并重新 Build
update_fakabot() {
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "${RED}错误: 未检测到克隆的仓库，请先执行选项 1！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在同步最新的远程官方代码...${RESET}"
    cd "$SRC_DIR" && git pull
    echo -e "${YELLOW}正在严格按照依赖顺序重编机器人镜像...${RESET}"
    docker compose up -d --build --remove-orphans
    echo -e "${GREEN}高阶集群源码更新并重编完成！${RESET}"
}

# 彻底卸载
uninstall_fakabot() {
    echo -ne "${RED}确定要停止并卸载整个 fakabot 集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -d "$SRC_DIR/.git" ]; then
            cd "$SRC_DIR" && docker compose down -v
            echo -e "${GREEN}机器人与 Redis 容器、专属隔离网络、内部 Volume 卷均已安全移除。${RESET}"
            echo -ne "${YELLOW}是否同步清理本地克隆的【全部源码和商品卡密配置】？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}所有物理数据已被彻底清除！${RESET}"
                exit 0
            fi
        fi
    fi
}

start_fakabot() { cd "$SRC_DIR" && docker compose start && echo -e "${GREEN}高阶集群已全面拉起${RESET}"; }
stop_fakabot() { cd "$SRC_DIR" && docker compose stop && echo -e "${YELLOW}高阶集群已安全停止${RESET}"; }
restart_fakabot() { cd "$SRC_DIR" && docker compose restart && echo -e "${GREEN}高阶集群已完成平滑重启${RESET}"; }
logs_fakabot() { cd "$SRC_DIR" && docker compose logs -f --tail=100; }

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}  ◈  fakabot 发卡机器人管理面板  ◈ ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}服务状态 :${RESET} $status"
    echo -e "${GREEN}健康端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 快捷编辑商品和支付${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_fakabot ;;
        2) update_fakabot ;;
        3) uninstall_fakabot ;;
        4) start_fakabot ;;
        5) stop_fakabot ;;
        6) restart_fakabot ;;
        7) logs_fakabot ;;
        8) edit_config ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
