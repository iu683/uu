#!/bin/bash
# =================================================================
# simple-blog 后端 (官方原生 Clone + 环境变量 Build) 自动化管理面板
# =================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

REPO_URL="https://github.com/usxs/simple-blog.git"
BASE_DIR="/opt/simple-blog"
BACKEND_DIR="$BASE_DIR/backend"
RUN_UID_GID="1000:1000"

PERSIST_DIRS="data article Musings img file"
PERSIST_FILES="config.json"

check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! docker compose version &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker Compose (docker compose)，请先安装！${RESET}"
        exit 1
    fi
    if ! command -v git &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Git，请先安装 Git！${RESET}"
        exit 1
    fi
}

get_env_port() {
    local port=""
    if [ -f "$BACKEND_DIR/.env" ]; then
        port=$(grep -E '^HOST_PORT=' "$BACKEND_DIR/.env" | head -n1 | cut -d '=' -f2- | tr -d '"' | tr -d "'" | xargs)
    fi
    [[ -z "$port" ]] && port="33001"
    echo "$port"
}

get_status_info() {
    local container_id=""
    if [ -d "$BACKEND_DIR" ] && [ -f "$BACKEND_DIR/docker-compose.yml" ]; then
        container_id=$(cd "$BACKEND_DIR" && docker compose ps -q --status running 2>/dev/null | head -n1)
    fi
    if [[ -z "$container_id" ]]; then
        container_id=$(docker ps -q -f "name=simple-blog-backend" -f "status=running" 2>/dev/null | head -n1)
    fi

    if [[ -n "$container_id" ]]; then
        status="${GREEN}运行中${RESET}"
        webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{end}}{{end}}' "$container_id" 2>/dev/null | head -n1)
        [[ -z "$webui_port" ]] && webui_port=$(get_env_port)
    else
        if [ -d "$BASE_DIR/.git" ]; then
            status="${RED}已停止${RESET}"
        else
            status="${RED}未部署${RESET}"
        fi
        webui_port=$(get_env_port)
        [[ "$status" == "${RED}未部署${RESET}" ]] && webui_port="N/A"
    fi
}

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
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
}

set_env_kv() {
    local key="$1"
    local val="$2"
    local file="$3"
    if grep -qE "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
        echo "${key}=${val}" >> "$file"
    fi
}

prepare_dirs_and_perms() {
    cd "$BACKEND_DIR" || return 1
    echo -e "${YELLOW}正在创建持久化目录与文件 (config.json 必须为文件)...${RESET}"
    mkdir -p $PERSIST_DIRS
    for f in $PERSIST_FILES; do
        # 若误建为目录则清理后重建为空文件
        if [ -d "$f" ]; then
            rm -rf "$f"
        fi
        [ ! -f "$f" ] && touch "$f"
    done

    echo -e "${YELLOW}正在修复目录与文件属主 (${RUN_UID_GID})...${RESET}"
    if command -v sudo &> /dev/null && [ "$(id -u)" -ne 0 ]; then
        sudo chown -R "$RUN_UID_GID" $PERSIST_DIRS $PERSIST_FILES
    else
        chown -R "$RUN_UID_GID" $PERSIST_DIRS $PERSIST_FILES 2>/dev/null || true
    fi
}

configure_env() {
    cd "$BACKEND_DIR" || return 1
    if [ ! -f ".env" ]; then
        if [ -f ".env.example" ]; then
            cp .env.example .env
        else
            touch .env
        fi
    fi

    local default_port
    default_port=$(get_env_port)

    echo -e "\n${CYAN}====== 1. 环境变量配置 (.env) ======${RESET}"
    echo -ne "${YELLOW}宿主机监听端口 HOST_PORT [默认: ${default_port}]: ${RESET}"
    read -r input_port
    [[ -z "$input_port" ]] && input_port="$default_port"
    set_env_kv "HOST_PORT" "$input_port" ".env"

    echo -ne "${YELLOW}管理员账号 ADMIN_USERNAME [默认: admin，留空跳过修改]: ${RESET}"
    read -r input_admin_user
    if [[ -n "$input_admin_user" ]]; then
        set_env_kv "ADMIN_USERNAME" "$input_admin_user" ".env"
    elif ! grep -qE '^ADMIN_USERNAME=' ".env"; then
        set_env_kv "ADMIN_USERNAME" "admin" ".env"
    fi

    echo -ne "${YELLOW}管理员密码 ADMIN_PASSWORD（仅首次初始化生效，留空则走向导/保持不变）: ${RESET}"
    read -r input_admin_pass
    if [[ -n "$input_admin_pass" ]]; then
        set_env_kv "ADMIN_PASSWORD" "$input_admin_pass" ".env"
    fi

    echo -ne "${YELLOW}前端地址 SITE_PUBLIC_URL（如 https://www.example.com，留空跳过）: ${RESET}"
    read -r input_site_url
    [[ -n "$input_site_url" ]] && set_env_kv "SITE_PUBLIC_URL" "$input_site_url" ".env"

    echo -ne "${YELLOW}后端地址 BACKEND_PUBLIC_URL（如 https://api.example.com，留空跳过）: ${RESET}"
    read -r input_backend_url
    [[ -n "$input_backend_url" ]] && set_env_kv "BACKEND_PUBLIC_URL" "$input_backend_url" ".env"

    if ! grep -qE '^CAPTCHA_SECRET=.+' ".env" && command -v openssl &> /dev/null; then
        local cap_secret
        cap_secret=$(openssl rand -hex 32)
        set_env_kv "CAPTCHA_SECRET" "$cap_secret" ".env"
        echo -e "${GREEN}已自动生成 CAPTCHA_SECRET 并写入 .env${RESET}"
    fi

    echo -ne "${YELLOW}是否使用 vim 手动编辑 .env？(y/N): ${RESET}"
    read -r edit_vim
    if [[ "$edit_vim" == "y" || "$edit_vim" == "Y" ]]; then
        vim .env
    fi
}

install_blog() {
    check_dependencies

    if [ ! -d "$BASE_DIR/.git" ]; then
        echo -e "\n${YELLOW}正在克隆官方 GitHub 仓库...${RESET}"
        mkdir -p "$BASE_DIR"
        git clone "$REPO_URL" "$BASE_DIR/tmp_repo"
        if [ $? -eq 0 ]; then
            mv "$BASE_DIR/tmp_repo/"* "$BASE_DIR/" 2>/dev/null
            mv "$BASE_DIR/tmp_repo/."* "$BASE_DIR/" 2>/dev/null
            rm -rf "$BASE_DIR/tmp_repo"
        else
            echo -e "${RED}错误: 仓库克隆失败，请检查网络！${RESET}"
            return 1
        fi
    else
        echo -e "\n${GREEN}检测到本地已存在仓库，正在同步最新代码...${RESET}"
        cd "$BASE_DIR" && git pull
    fi

    if [ ! -d "$BACKEND_DIR" ]; then
        echo -e "${RED}错误: 未找到 ${BACKEND_DIR} 目录！${RESET}"
        return 1
    fi

    prepare_dirs_and_perms
    configure_env

    echo -e "\n${YELLOW}正在执行 docker compose up -d --build...${RESET}"
    cd "$BACKEND_DIR" && docker compose up -d --build
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 容器构建或启动失败，请检查日志！${RESET}"
        return 1
    fi

    sleep 3
    prepare_dirs_and_perms

    get_status_info
    local DETECT_IP
    DETECT_IP=$(get_public_ip)
    local PORT_NOW
    PORT_NOW=$(get_env_port)

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}       simple-blog 后端编译并启动成功！             ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}本地监听地址 : http://127.0.0.1:${PORT_NOW}${RESET}"
    echo -e "${YELLOW}后台访问地址 : http://127.0.0.1:${PORT_NOW}/admin.html${RESET}"
    echo -e "${YELLOW}账号         : ${ADMIN_USERNAME}${RESET}"
    echo -e "${YELLOW}密码         : ${ADMIN_PASSWORD}${RESET}"
    echo -e "${YELLOW}后端工作目录 : ${BACKEND_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

update_blog() {
    if [ ! -d "$BASE_DIR/.git" ]; then
        echo -e "${RED}错误: 未检测到克隆的仓库，请先执行选项 1！${RESET}"
        return
    fi

    echo -e "${YELLOW}正在同步最新远程代码...${RESET}"
    cd "$BASE_DIR" && git pull

    prepare_dirs_and_perms
    echo -e "${YELLOW}正在重新构建并启动容器...${RESET}"
    cd "$BACKEND_DIR" && docker compose up -d --build --remove-orphans
    echo -e "${GREEN}后端更新并重编完成！${RESET}"
}

uninstall_blog() {
    echo -ne "${RED}确定要停止并卸载 simple-blog 后端容器吗？(y/N): ${RESET}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        if [ -f "$BACKEND_DIR/docker-compose.yml" ]; then
            cd "$BACKEND_DIR" && docker compose down
            echo -e "${GREEN}容器与网络已被安全停止并移除。${RESET}"
        fi
        echo -ne "${YELLOW}是否同步删除本地整个目录 (${BASE_DIR}，含文章/随笔/图片/配置数据)？(y/N): ${RESET}"
        read -r clean_data
        if [[ "$clean_data" == "y" || "$clean_data" == "Y" ]]; then
            rm -rf "$BASE_DIR"
            echo -e "${GREEN}本地所有源码与持久化数据已被彻底清除！${RESET}"
        fi
    fi
}

start_blog()   { [ -f "$BACKEND_DIR/docker-compose.yml" ] && (cd "$BACKEND_DIR" && docker compose start)   && echo -e "${GREEN}后端容器已启动${RESET}"   || echo -e "${RED}未找到 docker-compose.yml${RESET}"; }
stop_blog()    { [ -f "$BACKEND_DIR/docker-compose.yml" ] && (cd "$BACKEND_DIR" && docker compose stop)    && echo -e "${YELLOW}后端容器已停止${RESET}"    || echo -e "${RED}未找到 docker-compose.yml${RESET}"; }
restart_blog() { [ -f "$BACKEND_DIR/docker-compose.yml" ] && (cd "$BACKEND_DIR" && docker compose restart) && echo -e "${GREEN}后端容器已重启${RESET}"    || echo -e "${RED}未找到 docker-compose.yml${RESET}"; }
logs_blog()    { [ -f "$BACKEND_DIR/docker-compose.yml" ] && (cd "$BACKEND_DIR" && docker compose logs -f --tail=100) || echo -e "${RED}未找到 docker-compose.yml${RESET}"; }

show_info() {
    get_status_info
    local DETECT_IP
    DETECT_IP=$(get_public_ip)
    local PORT_NOW
    PORT_NOW=$(get_env_port)
    local SITE_URL
    SITE_URL=$(grep -E '^SITE_PUBLIC_URL=' "$BACKEND_DIR/.env" 2>/dev/null | cut -d '=' -f2-)
    local BACKEND_URL
    BACKEND_URL=$(grep -E '^BACKEND_PUBLIC_URL=' "$BACKEND_DIR/.env" 2>/dev/null | cut -d '=' -f2-)

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}运行状态       : ${status}"
    echo -e "${YELLOW}宿主机端口     : ${PORT_NOW} (127.0.0.1:${PORT_NOW})${RESET}"
    echo -e "${YELLOW}参考访问地址   : http://${DETECT_IP}:${PORT_NOW}${RESET}"
    echo -e "${YELLOW}SITE_PUBLIC_URL: ${SITE_URL:-未设置}${RESET}"
    echo -e "${YELLOW}BACKEND_URL    : ${BACKEND_URL:-未设置}${RESET}"
    echo -e "${YELLOW}后端目录       : ${BACKEND_DIR}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}    ◈  simple-blog 后端面板  ◈     ${RESET}"
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
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_blog ;;
        2) update_blog ;;
        3) uninstall_blog ;;
        4) start_blog ;;
        5) stop_blog ;;
        6) restart_blog ;;
        7) logs_blog ;;
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
