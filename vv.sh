#!/bin/bash
# =================================================================
# Codex WebUI Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="codex-webui"
BASE_DIR="/opt/codex-webui"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
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
        [[ -z "$img_version" ]] && img_version="已安装"

        # 从容器状态提取前端绑定的端口（默认监听的是 8172 端口）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8172/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        # 兜底获取第一个绑定的端口
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8172"

        # 提取挂载的数据卷信息
        data_dir="Docker Volumes (root_home, workspaces)"
    else
        # 容器未安装/未部署时的返回值
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        data_dir="N/A"
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

# 部署 Codex WebUI
install_codex() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}1. 请输入 Codex WebUI 访问端口 (宿主机端口) [默认: 8172]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8172"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 默认生成一个 32 位的强安全密钥作为内置默认值
    default_api_key=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
    echo -ne "${YELLOW}2. 是否启用 Web 密码/API保护？(y/n) [默认: y]: ${RESET}"
    read -r enable_auth
    [[ -z "$enable_auth" ]] && enable_auth="y"
    
    webui_api_key="change-me-to-a-random-secret"
    if [[ "$enable_auth" == "y" || "$enable_auth" == "Y" ]]; then
        echo -ne "${YELLOW}   请输入您的 WebUI API 验证密钥 [默认随机生成: ${default_api_key}]: ${RESET}"
        read -r input_key
        webui_api_key=${input_key:-$default_api_key}
    fi

    echo -ne "${YELLOW}3. 请输入您的 OpenAI API Key (Codex工作必需) [必填]: ${RESET}"
    read -r openai_key
    while [[ -z "$openai_key" ]]; do
        echo -e "${RED}   OpenAI API Key 不能为空，请重新输入！${RESET}"
        echo -ne "${YELLOW}   请输入您的 OpenAI API Key: ${RESET}"
        read -r openai_key
    done

    # 1. 确保目录权限
    chmod -R 777 "$BASE_DIR"

    # 2. 动态生成 .env 配置文件
    echo -e "${YELLOW}正在生成 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
# Required: access key for WebUI API/WebSocket authentication
WEBUI_API_KEY=${webui_api_key}

# Optional: backend listen port (default 8172)
PORT=${custom_port}

# Optional: OpenAI API key (required for Codex to work)
OPENAI_API_KEY=${openai_key}

# Optional: Pino log level (default: info)
# LOG_LEVEL=info

# Optional: path to codex CLI binary (default: codex)
# CODEX_BIN=codex

# Optional: codex home directory (default: ~/.codex)
# CODEX_HOME=/codex-home

# Optional: SQLite database path (default: CODEX_HOME/codex-webui.sqlite)
# WEBUI_DB_PATH=
EOF

    # 3. 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  codex-webui:
    container_name: ${CONTAINER_NAME}
    image: ghcr.io/limlll/codex-webui:latest
    ports:
      - "${custom_port}:${custom_port}"
    environment:
      NODE_ENV: production
      PORT: ${custom_port}
      WEBUI_API_KEY: \${WEBUI_API_KEY:?Set WEBUI_API_KEY in .env}
      WORKSPACE_ROOTS: /workspaces
      OPENAI_API_KEY: \${OPENAI_API_KEY:-}
    volumes:
      - root_home:/root
      - workspaces:/workspaces
    # Codex sandbox (bubblewrap) needs user namespaces + mount capabilities
    cap_add:
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
      - seccomp:unconfined
    restart: unless-stopped

volumes:
  root_home:
  workspaces:
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Codex WebUI 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    Codex WebUI 部署成功！       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}WebUI 验证密钥 : ${webui_api_key}${RESET}"
    echo -e "${YELLOW}提示: 请妥善保管好您的验证密钥，在首次登录或调用API时需要输入。${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 Codex 镜像
update_codex() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Codex WebUI 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 Codex
uninstall_codex() {
    echo -ne "${YELLOW}确定要卸载并删除 Codex 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            echo -e "${GREEN}容器及关联的 Named Volumes 已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有本地配置文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置工作目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_codex() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_codex() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_codex() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_codex() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}WebUI 验证密钥 : ${webui_api_key}${RESET}"
    echo -e "${YELLOW}数据存储位置   : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  Codex WebUI 管理面板  ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
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
        1) install_codex ;;
        2) update_codex ;;
        3) uninstall_codex ;;
        4) start_codex ;;
        5) stop_codex ;;
        6) restart_codex ;;
        7) logs_codex ;;
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
