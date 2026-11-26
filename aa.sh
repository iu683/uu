#!/bin/bash
# =================================================================
# OVH-SNIPER (官方原生 Clone + 环境变量 Build) 自动化管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

SERVICE_NAME="ovh-sniper"
BASE_DIR="/opt/ovh-sniper"
SRC_DIR="$BASE_DIR"
REPO_URL="https://github.com/super888-png/stockhawk-ovh.git"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! docker compose version &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker Compose 插件，请先安装！${RESET}"
        exit 1
    fi
    if ! command -v git &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Git，请先安装 Git！${RESET}"
        exit 1
    fi
}

# 读取 .env 中的端口（若存在）
get_env_port() {
    if [ -f "$SRC_DIR/.env" ]; then
        local p
        p=$(grep -E '^PORT=' "$SRC_DIR/.env" | tail -n 1 | cut -d'=' -f2- | tr -d '[:space:]"')
        [[ -n "$p" ]] && echo "$p" && return 0
    fi
    echo "8000"
}

# 动态获取服务端口与运行状态
get_status_info() {
    local container_id
    container_id=$(docker ps -q -f "name=${SERVICE_NAME}" -f "status=running" 2>/dev/null | head -n 1)

    if [[ -n "$container_id" ]]; then
        status="${GREEN}运行中${RESET}"
        webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$container_id" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(get_env_port)
    else
        if [ -d "$SRC_DIR/.git" ]; then
            status="${RED}已停止${RESET}"
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

# 生成随机 SECRET_KEY
gen_secret_key() {
    if command -v python3 &> /dev/null; then
        python3 -c "import secrets; print(secrets.token_urlsafe(48))"
    else
        head -c 48 /dev/urandom | base64 | tr -d '\n/+='
    fi
}

# 更新或写入 .env 键值
set_env_kv() {
    local key="$1"
    local val="$2"
    local file="$SRC_DIR/.env"
    if grep -qE "^#?\s*${key}=" "$file"; then
        sed -i "s|^#*\s*${key}=.*|${key}=${val}|" "$file"
    else
        echo "${key}=${val}" >> "$file"
    fi
}

# 部署核心逻辑
install_sniper() {
    check_dependencies

    echo -e "${CYAN}====== 1. 基础配置 ======${RESET}"
    echo -ne "${YELLOW}请输入监听端口 (对应 PORT) [默认: 8000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8000"

    echo -ne "${YELLOW}请输入绑定地址 (对应 BIND_ADDR，反代建议 127.0.0.1) [默认: 0.0.0.0]: ${RESET}"
    read -r bind_addr
    [[ -z "$bind_addr" ]] && bind_addr="0.0.0.0"

    echo -ne "${YELLOW}是否启用 HTTPS Cookie 安全标记 (COOKIE_SECURE: 0/1) [默认: 0]: ${RESET}"
    read -r cookie_secure
    [[ -z "$cookie_secure" ]] && cookie_secure="0"

    echo -ne "${YELLOW}请输入默认语言 (zh/en) [默认: zh]: ${RESET}"
    read -r default_lang
    [[ -z "$default_lang" ]] && default_lang="zh"

    # 克隆官方仓库
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "\n${YELLOW}正在克隆官方 GitHub 仓库...${RESET}"
        mkdir -p "$SRC_DIR"
        local tmp_clone="/tmp/stockhawk_ovh_clone_$$"
        rm -rf "$tmp_clone"
        if git clone "$REPO_URL" "$tmp_clone"; then
            # 移动所有文件（含隐藏文件，排除 . 和 ..）
            shopt -s dotglob nullglob
            for item in "$tmp_clone"/*; do
                local base_item
                base_item=$(basename "$item")
                # 若目标目录已存在同名脚本且为同一文件，跳过覆盖
                if [ -e "$SRC_DIR/$base_item" ] && [ "$(readlink -f "$SRC_DIR/$base_item" 2>/dev/null)" = "$SCRIPT_PATH" ]; then
                    continue
                fi
                mv "$item" "$SRC_DIR/"
            done
            shopt -u dotglob nullglob
            rm -rf "$tmp_clone"
        else
            rm -rf "$tmp_clone"
            echo -e "${RED}错误: 仓库克隆失败，请检查网络！${RESET}"
            return 1
        fi
    else
        echo -e "\n${GREEN}检测到本地已存在官方仓库，正在同步最新代码...${RESET}"
        cd "$SRC_DIR" && git pull
    fi

    cd "$SRC_DIR" || return 1

    # 初始化并配置 .env
    if [ ! -f ".env" ]; then
        if [ -f ".env.example" ]; then
            cp .env.example .env
        else
            touch .env
        fi
    fi

    local current_secret
    current_secret=$(grep -E '^SECRET_KEY=' .env | tail -n 1 | cut -d'=' -f2-)
    if [[ -z "$current_secret" || "$current_secret" == *"change-me"* ]]; then
        local new_secret
        new_secret=$(gen_secret_key)
        set_env_kv "SECRET_KEY" "$new_secret"
        echo -e "${GREEN}已自动生成强随机 SECRET_KEY（请妥善备份 .env，丢失后无法解密已保存 Key）。${RESET}"
    fi

    set_env_kv "PORT" "$custom_port"
    set_env_kv "BIND_ADDR" "$bind_addr"
    set_env_kv "COOKIE_SECURE" "$cookie_secure"
    set_env_kv "DEFAULT_LANG" "$default_lang"
    chmod 600 .env

    # 持久化目录准备
    mkdir -p data

    echo -e "\n${YELLOW}正在执行官方 Compose 构建并启动服务...${RESET}"
    docker compose up -d --build

    echo -e "${YELLOW}正在等待服务拉起 (约 5 秒)...${RESET}"
    sleep 5

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}        OVH-SNIPER 集群编译并启动成功！             ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}访问地址       : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}绑定监听       : ${bind_addr}:${custom_port}${RESET}"
    echo -e "${YELLOW}仓库所在路径   : ${SRC_DIR}${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${CYAN}下一步建议：执行菜单 [9] 创建管理员账号 (create-admin)${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 原生更新：拉取代码 + 重新 Build
update_sniper() {
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "${RED}错误: 未检测到克隆的仓库，请先执行选项 1！${RESET}"
        return
    fi

    echo -e "${YELLOW}正在同步最新的远程官方代码...${RESET}"
    cd "$SRC_DIR" || return
    git pull

    [ -f ".env" ] && chmod 600 .env

    echo -e "${YELLOW}正在重编镜像并热更新容器...${RESET}"
    docker compose up -d --build --remove-orphans
    echo -e "${GREEN}OVH-SNIPER 集群更新并重编完成！${RESET}"
}

# 彻底卸载
uninstall_sniper() {
    echo -ne "${RED}确定要停止并卸载 OVH-SNIPER 容器集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -d "$SRC_DIR/.git" ] || [ -f "$SRC_DIR/docker-compose.yml" ]; then
            cd "$SRC_DIR" && docker compose down
            echo -e "${GREEN}容器与网络已被安全停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同步连根拔除本地克隆的【全部源码、配置及持久化数据】？(y/n): ${RESET}"
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

# 生命周期管理
start_sniper() {
    [ ! -d "$SRC_DIR/.git" ] && echo -e "${RED}错误: 未检测到仓库，请先部署！${RESET}" && return
    cd "$SRC_DIR" && docker compose start && echo -e "${GREEN}原生集群已全面启动${RESET}"
}

stop_sniper() {
    [ ! -d "$SRC_DIR/.git" ] && echo -e "${RED}错误: 未检测到仓库，请先部署！${RESET}" && return
    cd "$SRC_DIR" && docker compose stop && echo -e "${YELLOW}原生集群已安全停止${RESET}"
}

restart_sniper() {
    [ ! -d "$SRC_DIR/.git" ] && echo -e "${RED}错误: 未检测到仓库，请先部署！${RESET}" && return
    cd "$SRC_DIR" && docker compose restart && echo -e "${GREEN}原生集群已平滑重启${RESET}"
}

logs_sniper() {
    [ ! -d "$SRC_DIR/.git" ] && echo -e "${RED}错误: 未检测到仓库，请先部署！${RESET}" && return
    cd "$SRC_DIR" && docker compose logs -f --tail=100
}

create_admin_sniper() {
    [ ! -d "$SRC_DIR/.git" ] && echo -e "${RED}错误: 未检测到仓库，请先部署！${RESET}" && return
    cd "$SRC_DIR" || return
    echo -e "${CYAN}正在进入容器创建管理员账号...${RESET}"
    docker compose exec "$SERVICE_NAME" python -m app.cli create-admin
}

show_info() {
    get_status_info
    local DETECT_IP
    DETECT_IP=$(get_public_ip)
    local bind_addr="0.0.0.0"
    local cookie_secure="0"
    local default_lang="en"
    if [ -f "$SRC_DIR/.env" ]; then
        bind_addr=$(grep -E '^BIND_ADDR=' "$SRC_DIR/.env" | tail -n 1 | cut -d'=' -f2-)
        cookie_secure=$(grep -E '^COOKIE_SECURE=' "$SRC_DIR/.env" | tail -n 1 | cut -d'=' -f2-)
        default_lang=$(grep -E '^DEFAULT_LANG=' "$SRC_DIR/.env" | tail -n 1 | cut -d'=' -f2-)
    fi
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}集群运行状态     : $status"
    echo -e "${YELLOW}前端访问地址     : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}监听地址/端口    : ${bind_addr:-0.0.0.0}:${webui_port}${RESET}"
    echo -e "${YELLOW}COOKIE_SECURE    : ${cookie_secure:-0}${RESET}"
    echo -e "${YELLOW}DEFAULT_LANG     : ${default_lang:-en}${RESET}"
    echo -e "${YELLOW}配置与数据目录   : ${SRC_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}   ◈  OVH-SNIPER 抢购管理面板  ◈   ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}集群状态 :${RESET} $status"
    echo -e "${GREEN}服务端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}9. 创建管理员${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_sniper ;;
        2) update_sniper ;;
        3) uninstall_sniper ;;
        4) start_sniper ;;
        5) stop_sniper ;;
        6) restart_sniper ;;
        7) logs_sniper ;;
        8) show_info ;;
        9) create_admin_sniper ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
