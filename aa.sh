#!/bin/bash
# =================================================================
# ClaudeGate Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="claudegate"
BASE_DIR="/opt/claudegate"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
VOLUME_NAME="claudegate-data"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
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

# 动态获取容器状态、映射端口和镜像信息
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        return 0
    fi

    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${GREEN}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 容器内部固定监听 8800 端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8800/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="27666"
    else
        img_version="${RED}未安装${RESET}"
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

# 部署 ClaudeGate
install_claudegate() {
    check_dependencies

    mkdir -p "$BASE_DIR"

    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"

    echo -ne "${YELLOW}请输入宿主机映射端口 [默认: 27666，容器内固定 8800]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="27666"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]] || [ "$custom_port" -lt 1 ] || [ "$custom_port" -gt 65535 ]; then
        echo -e "${RED}错误: 端口必须是 1-65535 之间的数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入 PUBLIC_URL (如 https://gw.example.com) [默认: http://${DETECT_IP}:${custom_port}]: ${RESET}"
    read -r public_url
    [[ -z "$public_url" ]] && public_url="http://${DETECT_IP}:${custom_port}"

    echo -ne "${YELLOW}请输入出站代理 UPSTREAM_PROXY (如 socks5h://127.0.0.1:1080，留空直连): ${RESET}"
    read -r upstream_proxy

    echo -ne "${YELLOW}请输入默认模型 DEFAULT_MODEL [默认: claude-sonnet-4-5-20250929]: ${RESET}"
    read -r default_model
    [[ -z "$default_model" ]] && default_model="claude-sonnet-4-5-20250929"

    echo -ne "${YELLOW}请输入网关令牌有效期 TOKEN_TTL_DAYS (天) [默认: 365]: ${RESET}"
    read -r token_ttl
    [[ -z "$token_ttl" ]] && token_ttl="365"

    echo -e "${YELLOW}正在生成 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
# ============ 监听 ============
PORT=8800
HOST=0.0.0.0
PUBLIC_URL=${public_url}

# ============ 安全 ============
SECRET=
ADMIN_TOKEN=
ADMIN_SECRET=
CG_ENV_FILE=
TOKEN_TTL_DAYS=${token_ttl}
TRUST_PROXY=true

# ============ 上游 ============
UPSTREAM_BASE=https://api.anthropic.com
UPSTREAM_PROXY=${upstream_proxy}
IP_CHECK=block
IP_CHECK_URL=https://ipinfo.io/json
TLS_MIN=TLSv1.2
TLS_MAX=TLSv1.3
UPSTREAM_ALPN=http/1.1
UPSTREAM_TIMEOUT_MS=600000
UPSTREAM_MAX_SOCKETS=64

# ============ 占用与限流 ============
MAX_BODY_BYTES=33554432
SHUTDOWN_GRACE_MS=5000

# ============ Claude Code 请求头守卫 ============
GUARD_MODE=strict
GUARD_REQUIRE=user-agent,x-app
INJECT_MISSING=false

# ============ 隐写拦截 ============
STEGO_MODE=block

# ============ 请求 ID ============
REQ_ID_IN_RESPONSE=error

# ============ OAuth ============
OAUTH_MODE=claude_ai
OAUTH_CLIENT_ID=
OAUTH_SCOPES=
OAUTH_AUTHORIZE_URL=
OAUTH_TOKEN_URL=
OAUTH_MANUAL_REDIRECT=https://platform.claude.com/oauth/code/callback
TOKEN_AUTO_REFRESH=on
TOKEN_REFRESH_INTERVAL_SEC=60
TOKEN_REFRESH_LEAD_SEC=600
OAUTH_PROFILE_URL=https://api.anthropic.com/api/oauth/profile

# ============ 请求体身份校验 ============
IDENTITY_MODE=block

# ============ 模型上下文与输出 ============
MODEL_LIMITS=
CONTEXT_GUARD=block
CONTEXT_HEADROOM=0.1
IMAGE_MAX_TOKENS=1600

# ============ 模型 ============
DEFAULT_MODEL=${default_model}
MAX_TOKENS_DEFAULT=8192

# ============ 其他 ============
DATA_DIR=/data
LOG_LEVEL=info

# ============ 模型目录 ============
MODEL_CATALOG_URL=https://downloads.claude.ai/model-catalog/v1/catalog.json
MODEL_CATALOG_TTL_MS=21600000
MODEL_VALIDATION=strict
MODEL_DISABLED=
EOF
    chmod 600 "$ENV_FILE"

    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  claudegate:
    image: ghcr.io/moteam-cn/claudegate:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      DATA_DIR: /data
      PORT: "8800"
      HOST: 0.0.0.0
      NODE_OPTIONS: --disable-warning=ExperimentalWarning
    ports:
      - "${custom_port}:8800"
    volumes:
      - ${VOLUME_NAME}:/data
    healthcheck:
      test:
        - CMD
        - bun
        - -e
        - "fetch('http://127.0.0.1:8800/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 5s

volumes:
  ${VOLUME_NAME}:
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 ClaudeGate 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}正在等待容器初始化并提取面板登录密钥...${RESET}"
    local count=0
    local key_info=""
    while [ $count -lt 15 ]; do
        sleep 1
        key_info=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -A 6 '面板登录密钥')
        if [[ -n "$key_info" ]]; then
            break
        fi
        ((count++))
    done

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}            ClaudeGate 部署及启动成功！             ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}PUBLIC_URL   : ${public_url}${RESET}"
    echo -e "${YELLOW}数据持久化卷 : ${VOLUME_NAME} -> /data${RESET}"
    echo -e "${YELLOW}环境变量文件 : ${ENV_FILE}${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    if [[ -n "$key_info" ]]; then
        echo -e "${CYAN}🔑 面板登录密钥日志提取成功：${RESET}"
        echo -e "${GREEN}${key_info}${RESET}"
    else
        echo -e "${RED}⚠️  提示: 暂未在启动日志中匹配到「面板登录密钥」（可能已非首次启动或已显式设置 ADMIN_TOKEN）。${RESET}"
        echo -e "${YELLOW}      可选择选项 7 查看完整日志，或删除 data/admin.json 后重启重新派发。${RESET}"
    fi
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_claudegate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载服务
uninstall_claudegate() {
    echo -ne "${YELLOW}确定要卸载并删除 ClaudeGate 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除配置目录 ($BASE_DIR) 及数据卷 ($VOLUME_NAME)？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                docker volume rm "$VOLUME_NAME" 2>/dev/null
                echo -e "${GREEN}配置目录及数据卷已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_claudegate()   { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_claudegate()    { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_claudegate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_claudegate() {
    echo -e "${CYAN}--- 容器当前运行日志 (按 Ctrl+C 退出查看) ---${RESET}"
    docker logs -f "$CONTAINER_NAME"
}

show_info() {
    get_status_info
    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")
    local pub_url=""
    if [[ -f "$ENV_FILE" ]]; then
        pub_url=$(grep -E '^PUBLIC_URL=' "$ENV_FILE" | cut -d'=' -f2-)
    fi
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${YELLOW}当前状态     : $status"
    echo -e "${YELLOW}镜像名称     : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    [[ -n "$pub_url" ]] && echo -e "${YELLOW}PUBLIC_URL   : ${pub_url}${RESET}"
    echo -e "${YELLOW}数据持久化卷 : ${VOLUME_NAME} -> /data${RESET}"
    echo -e "${YELLOW}环境变量文件 : ${ENV_FILE}${RESET}"
    echo -e "${GREEN}========================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}  ◈  ClaudeGate 管理面板  ◈   ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_claudegate ;;
        2) update_claudegate ;;
        3) uninstall_claudegate ;;
        4) start_claudegate ;;
        5) stop_claudegate ;;
        6) restart_claudegate ;;
        7) logs_claudegate ;;
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
