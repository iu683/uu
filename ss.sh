#!/bin/bash
# =================================================================
# Puppy Stardew Server Docker Compose 交互式管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

MAIN_CONTAINER="puppy-stardew"
INIT_CONTAINER="puppy-stardew-init"
MGR_CONTAINER="puppy-stardew-manager"

# 默认基础路径，后续会根据用户输入动态调整
BASE_DIR="/opt/puppy-stardew"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态和端口信息
get_status_info() {
    # 1. 检查主容器状态
    if [ "$(docker ps -q -f name=^/${MAIN_CONTAINER}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${MAIN_CONTAINER}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 从容器状态动态提取当前映射的端口，若未部署则从 .env 读取，再没有则走默认
    if [ "$(docker ps -aq -f name=^/${MAIN_CONTAINER}$)" ]; then
        game_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if index $p | grep -q "udp"}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$MAIN_CONTAINER" 2>/dev/null)
        web_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "18642/tcp") 0).HostPort}}' "$MAIN_CONTAINER" 2>/dev/null)
        vnc_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "5900/tcp") 0).HostPort}}' "$MAIN_CONTAINER" 2>/dev/null)
        metric_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "9090/tcp") 0).HostPort}}' "$MAIN_CONTAINER" 2>/dev/null)
    fi

    # 兜底逻辑
    [[ -z "$game_port" || "$game_port" == "<nil>" ]] && game_port="24642"
    [[ -z "$web_port" || "$web_port" == "<nil>" ]] && web_port="18642"
    [[ -z "$vnc_port" || "$vnc_port" == "<nil>" ]] && vnc_port="5900"
    [[ -z "$metric_port" || "$metric_port" == "<nil>" ]] && metric_port="9090"

    if [ "$status" == "${RED}未部署${RESET}" ] && [ ! -f "$ENV_FILE" ]; then
        game_port="N/A"
        web_port="N/A"
        vnc_port="N/A"
        metric_port="N/A"
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

# 部署并配置 Stardew Valley 服务器
install_stardew() {
    check_dependencies
    
    echo -e "${CYAN}====== 1. 路径与端口自定义配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入宿主机数据安装绝对路径 [默认: /opt/puppy-stardew]: ${RESET}"
    read -r custom_path
    [[ -z "$custom_path" ]] && custom_path="/opt/puppy-stardew"
    
    # 动态重置全局路径变量
    BASE_DIR="$custom_path"
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
    ENV_FILE="$BASE_DIR/.env"

    echo -ne "${YELLOW}请输入游戏联机端口 (UDP) [默认: 24642]: ${RESET}"
    read -r custom_game_port
    [[ -z "$custom_game_port" ]] && custom_game_port="24642"

    echo -ne "${YELLOW}请输入 Web 管理面板端口 (TCP) [默认: 18642]: ${RESET}"
    read -r custom_web_port
    [[ -z "$custom_web_port" ]] && custom_web_port="18642"

    echo -ne "${YELLOW}请输入 VNC 远程桌面端口 (TCP) [默认: 5900]: ${RESET}"
    read -r custom_vnc_port
    [[ -z "$custom_vnc_port" ]] && custom_vnc_port="5900"

    echo -ne "${YELLOW}请输入 Prometheus 指标监控端口 (TCP) [默认: 9090]: ${RESET}"
    read -r custom_metric_port
    [[ -z "$custom_metric_port" ]] && custom_metric_port="9090"

    echo -e "\n${CYAN}====== 2. Steam 账号凭证配置 (必需) ======${RESET}"
    echo -e "${RED}提示: 您的 Steam 账户必须已购买《星露谷物语》！${RESET}"
    
    echo -ne "${YELLOW}请输入 Steam 用户名 (非邮箱): ${RESET}"
    read -r steam_user
    while [[ -z "$steam_user" ]]; do
        echo -ne "${RED}用户名不能为空，请重新输入: ${RESET}"
        read -r steam_user
    done

    echo -ne "${YELLOW}请输入 Steam 密码: ${RESET}"
    read -r -s steam_pass
    echo ""
    while [[ -z "$steam_pass" ]]; do
        echo -ne "${RED}密码不能为空，请重新输入: ${RESET}"
        read -r -s steam_pass
        echo ""
    done

    echo -e "\n${CYAN}====== 3. 高级环境配置 (可选) ======${RESET}"
    echo -ne "${YELLOW}请输入服务器时区 [默认: Asia/Shanghai]: ${RESET}"
    read -r custom_tz
    [[ -z "$custom_tz" ]] && custom_tz="Asia/Shanghai"

    echo -ne "${YELLOW}是否启用自动备份功能？(true/false) [默认: true]: ${RESET}"
    read -r enable_backup
    [[ -z "$enable_backup" ]] && enable_backup="true"

    # 1. 自动执行宿主机目录创建与权限修复 (UID 1000:1000)
    echo -e "${YELLOW}正在宿主机创建数据目录并授权归属 UID 1000...${RESET}"
    mkdir -p "$BASE_DIR"/data/{saves,game,steam,logs,backups,panel,custom-mods}
    chown -R 1000:1000 "$BASE_DIR/data"
    chmod -R 755 "$BASE_DIR/data"

    # 2. 写入 .env 配置文件
    echo -e "${YELLOW}正在写入 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
STEAM_USERNAME=${steam_user}
STEAM_PASSWORD=${steam_pass}
ENABLE_VNC=true
VNC_PASSWORD=
TZ=${custom_tz}
ENABLE_LOG_MONITOR=true
ENABLE_AUTO_BACKUP=${enable_backup}
MAX_BACKUPS=7
BACKUP_HOUR=4
ENABLE_CRASH_RESTART=true
EOF

    # 3. 写入 docker-compose.yml 配置文件 (绑定全自定义端口与安装目录)
    echo -e "${YELLOW}正在写入 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  stardew-manager:
    image: puppy-stardew-manager:local
    container_name: ${MGR_CONTAINER}
    restart: unless-stopped
    environment:
      - PROJECT_DIR=${BASE_DIR}
      - COMPOSE_FILE=${COMPOSE_FILE}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${BASE_DIR}:${BASE_DIR}:ro

  stardew-init:
    image: puppy-stardew-server:local
    container_name: ${INIT_CONTAINER}
    user: root
    entrypoint: ["/home/steam/scripts/init-container.sh"]
    environment:
      - USE_GPU=\${USE_GPU:-false}
    volumes:
      - ${BASE_DIR}/data/saves:/home/steam/.config/StardewValley:rw
      - ${BASE_DIR}/data/game:/home/steam/stardewvalley:rw
      - ${BASE_DIR}/data/steam:/home/steam/Steam:rw
      - ${BASE_DIR}/data/logs:/home/steam/.local/share/puppy-stardew/logs:rw
      - ${BASE_DIR}/data/backups:/home/steam/.local/share/puppy-stardew/backups:rw
      - ${BASE_DIR}/data/panel:/home/steam/web-panel/data:rw

  stardew-server:
    image: puppy-stardew-server:local
    container_name: ${MAIN_CONTAINER}
    restart: unless-stopped
    depends_on:
      stardew-manager:
        condition: service_started
      stardew-init:
        condition: service_completed_successfully
    stdin_open: true
    tty: true
    environment:
      - STEAM_USERNAME=\${STEAM_USERNAME}
      - STEAM_PASSWORD=\${STEAM_PASSWORD}
      - STEAM_GUARD_CODE=\${STEAM_GUARD_CODE:-}
      - ENABLE_VNC=\${ENABLE_VNC:-true}
      - VNC_PASSWORD=\${VNC_PASSWORD:-}
      - ENABLE_LOG_MONITOR=\${ENABLE_LOG_MONITOR:-true}
      - USE_GPU=\${USE_GPU:-false}
      - RESOLUTION_WIDTH=\${RESOLUTION_WIDTH:-1280}
      - RESOLUTION_HEIGHT=\${RESOLUTION_HEIGHT:-720}
      - REFRESH_RATE=\${REFRESH_RATE:-60}
      - LOW_PERF_MODE=\${LOW_PERF_MODE:-false}
      - ENABLE_AUTO_BACKUP=\${ENABLE_AUTO_BACKUP:-false}
      - MAX_BACKUPS=\${MAX_BACKUPS:-7}
      - BACKUP_HOUR=\${BACKUP_HOUR:-4}
      - ENABLE_CRASH_RESTART=\${ENABLE_CRASH_RESTART:-false}
    ports:
      - "${custom_game_port}:24642/udp"
      - "${custom_vnc_port}:5900/tcp"
      - "${custom_metric_port}:9090/tcp"
      - "${custom_web_port}:18642/tcp"
    volumes:
      - ${BASE_DIR}/data/saves:/home/steam/.config/StardewValley:rw
      - ${BASE_DIR}/data/game:/home/steam/stardewvalley:rw
      - ${BASE_DIR}/data/steam:/home/steam/Steam:rw
      - ${BASE_DIR}/data/logs:/home/steam/.local/share/puppy-stardew/logs:rw
      - ${BASE_DIR}/data/backups:/home/steam/.local/share/puppy-stardew/backups:rw
      - ${BASE_DIR}/data/panel:/home/steam/web-panel/data:rw
      - ${BASE_DIR}/data/custom-mods:/home/steam/custom-mods:rw
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 2G
        reservations:
          memory: 1G
    healthcheck:
      test: ["CMD", "pgrep", "-f", "StardewModdingAPI"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 180s
    cap_drop:
      - NET_RAW
      - SYS_ADMIN
      - MKNOD
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    echo -e "${YELLOW}正在启动服务并拉取/下载游戏组件...${RESET}"
    cd "$BASE_DIR" && docker compose up -d

    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${GREEN}                Puppy Stardew 容器组构建完成！                  ${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${YELLOW}【关键下一步】: 由于是首次启动，请立即在主菜单使用 选项 9${RESET}"
    echo -e "${YELLOW}               进入交互模式输入您的 Steam 令牌 (Steam Guard)！${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
}

# 捕获并连接到 Steam 令牌交互终端
attach_steam_guard() {
    if [ "$(docker ps -q -f name=^/${MAIN_CONTAINER}$)" ]; then
        echo -e "${CYAN}正在连接到服务器后台终端...${RESET}"
        echo -e "${YELLOW} 提示: 如果看到输入 Steam Guard 代码提示，直接键入并回车即可。${RESET}"
        echo -e "${RED} 注意退出方法: 必须按快捷键 Ctrl+P 然后按 Ctrl+Q 来安全分离！${RESET}"
        echo -e "${RED} 切勿使用 Ctrl+C，否则会导致容器意外关闭！${RESET}"
        echo -ne "${GREEN}按回车键确认进入终端...${RESET}"
        read -r
        docker attach "$MAIN_CONTAINER"
    else
        echo -e "${RED}错误: 服务器容器当前未运行，无法连接令牌终端！${RESET}"
    fi
}

# 更新容器和游戏
update_stardew() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取小狗星谷最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}容器升级指令已执行。游戏更新由内置 SteamCMD 在容器启动时自动核对。${RESET}"
}

# 卸载服务
uninstall_stardew() {
    echo -ne "${YELLOW}确定要完全卸载并删除小狗星谷服务器组吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}所有相关容器已安全停止并销毁。${RESET}"
            echo -ne "${YELLOW}是否要同时删除所有的游戏世界存档、下载的游戏本体、Steam凭证和备份？(y/n): ${RESET}"
            read -r clean_data
            if [[ "$clean_data" == "y" || "$clean_data" == "Y" ]]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}宿主机路径及所有存档数据已被彻底物理清除。${RESET}"
            fi
        else
            docker rm -f "$MAIN_CONTAINER" "$INIT_CONTAINER" "$MGR_CONTAINER" 2>/dev/null
        fi
        echo -e "${GREEN}卸载流程执行完毕！${RESET}"
    fi
}

start_stardew() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器组已拉起。${RESET}"; }
stop_stardew() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器组已降下停止。${RESET}"; }
restart_stardew() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器组已执行重启。${RESET}"; }
logs_stardew() { docker logs -f --tail 100 "$MAIN_CONTAINER"; }

# 状态与安全审计面板
show_info() {
    get_status_info
    local current_ip=$(get_public_ip)
    
    # 自动检索随机生成的 VNC 密码
    local vnc_pass="未生成或已禁用 VNC"
    local pass_file="$BASE_DIR/data/panel/vnc_password.txt"
    if [[ -f "$pass_file" ]]; then
        vnc_pass=$(cat "$pass_file" 2>/dev/null)
        [[ -z "$vnc_pass" ]] && vnc_pass="为空 (可能尚未完成初始化)"
    fi

    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${GREEN}                   小狗星露谷服务器 运行时配置                   ${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${YELLOW}当前核心状态   : $status"
    echo -e "${YELLOW}Web 管理控制台 : http://${current_ip}:${web_port}${RESET}"
    echo -e "${YELLOW}VNC 远程桌面   : ${current_ip}:${vnc_port}${RESET}"
    echo -e "${RED}动态 VNC 密码   : ${vnc_pass}${RESET}"
    echo -e "${YELLOW}指标监控地址   : http://${current_ip}:${metric_port}/metrics${RESET}"
    echo -e "${YELLOW}联机直连游戏IP : ${current_ip} (UDP端口: ${game_port})${RESET}"
    echo -e "${YELLOW}数据持久化基路 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${CYAN}💡 首次开服向导：${RESET}"
    echo -e " 1. 看到容器运行后，用 [选项 9] 盲输绑定的 Steam 令牌验证码（若有提示）。"
    echo -e " 2. 登录 Web 控制台或通过 VNC 桌面连接服务器，创建/加载一张农场世界存档。"
    echo -e " 3. 游戏正常进图开始广播后，可去修改该目录下的 .env 中的 ENABLE_VNC=false 节省 50M 内存。"
    echo -e "${GREEN}================================================================${RESET}"
}

# 自动定位当前脚本所在的上下文路径
auto_find_base_dir() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        if [ -f "/opt/puppy-stardew/docker-compose.yml" ]; then
            BASE_DIR="/opt/puppy-stardew"
        fi
        COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
        ENV_FILE="$BASE_DIR/.env"
    fi
}

menu() {
    clear
    auto_find_base_dir
    get_status_info
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}     ◈  星露谷物语 开服管理面板  ◈     ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}服务状态 :${RESET} $status"
    echo -e "${GREEN}UDP端口  :${RESET} ${YELLOW}${game_port}${RESET}"
    echo -e "${GREEN}Web端口  :${RESET} ${YELLOW}${web_port}${RESET}"
    echo -e "${GREEN}VNC端口  :${RESET} ${YELLOW}${vnc_port}${RESET}" 
    echo -e "${GREEN}监控端口 :${RESET} ${YELLOW}${metric_port}${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}1. 部署安装服务${RESET}"
    echo -e "${GREEN}2. 更新容器游戏${RESET}"
    echo -e "${GREEN}3. 彻底卸载服务${RESET}"
    echo -e "${GREEN}4. 开启服务器组${RESET}"
    echo -e "${GREEN}5. 关闭服务器组${RESET}"
    echo -e "${GREEN}6. 重启服务器组${RESET}"
    echo -e "${GREEN}7. 追踪游戏日志${RESET}"
    echo -e "${GREEN}8. 查看连接信息与VNC密码${RESET}"
    echo -e "${GREEN}9. 连接到 Steam 令牌交互终端${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_stardew ;;
        2) update_stardew ;;
        3) uninstall_stardew ;;
        4) start_stardew ;;
        5) stop_stardew ;;
        6) restart_stardew ;;
        7) logs_stardew ;;
        8) show_info ;;
        9) attach_steam_guard ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
