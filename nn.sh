#!/bin/bash
# =================================================================
# SaveAny-Bot 机器人服务 Docker Compose 管理面板 (支持自定义路径)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="saveany-bot"
BASE_DIR="/opt/saveany"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
CONFIG_FILE="$BASE_DIR/config.toml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 生成随机密钥的辅助函数
generate_random_token() {
    if command -v openssl &> /dev/null; then
        openssl_rand=$(openssl rand -hex 16 2>/dev/null)
        if [[ -n "$openssl_rand" ]]; then
            echo "$openssl_rand"
            return 0
        fi
    fi
    echo "api_$(date +%s)_$((RANDOM % 10000))"
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

        # 解析本地端口
        if [ -f "$CONFIG_FILE" ]; then
            webui_port=$(grep -A 5 "\[api\]" "$CONFIG_FILE" | grep "port" | awk -F'=' '{print $2}' | tr -d ' "')
            [[ -z "$webui_port" ]] && webui_port="Host模式 (默认8080)"
        else
            webui_port="Host模式"
        fi

        # 【核心修改】从容器状态中精准提取挂载到 /app/downloads 的宿主机自定义路径
        data_dir=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/downloads"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$data_dir" ]] && data_dir="$BASE_DIR/downloads"
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        data_dir="N/A"
    fi
}

# 获取公网 IP
get_public_ip() {
    local mode=${1:-"auto"}
    local ip=""
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
}

# 部署 SaveAny-Bot
install_translate() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入你的 Telegram Bot Token (必填): ${RESET}"
    read -r tg_token
    while [[ -z "$tg_token" ]]; do
        echo -e "${RED}错误: Bot Token 不能为空！${RESET}"
        echo -ne "${YELLOW}请重新输入 Telegram Bot Token: ${RESET}"
        read -r tg_token
    done

    echo -ne "${YELLOW}请输入允许使用机器人的 Telegram 用户 ID [默认: 114514]: ${RESET}"
    read -r tg_user_id
    [[ -z "$tg_user_id" ]] && tg_user_id="114514"

    # 【新增交互】自定义宿主机下载路径
    echo -ne "${YELLOW}请输入宿主机文件下载存储的绝对路径 [默认: $BASE_DIR/downloads]: ${RESET}"
    read -r custom_downloads
    [[ -z "$custom_downloads" ]] && custom_downloads="$BASE_DIR/downloads"

    # 自动创建所需的所有挂载子目录
    echo -e "${YELLOW}正在初始化宿主机目录...${RESET}"
    mkdir -p "$BASE_DIR/data" "$BASE_DIR/cache" "$custom_downloads"
    chmod -R 777 "$BASE_DIR" "$custom_downloads"

    # 生成一个随机的 API 认证 Token
    RAND_API_TOKEN=$(generate_random_token)

    # 1. 动态生成符合要求的 config.toml 配置文件
    echo -e "${YELLOW}正在生成规范化的 config.toml 配置文件...${RESET}"
    cat <<EOF > "$CONFIG_FILE"
workers = 4    # 同时下载文件数
retry = 3      # 下载失败重试次数
threads = 4    # 单个任务下载使用的最大线程数
stream = false # 使用流式传输模式

[log]
level = "info"

[telegram]
token = "${tg_token}"

[telegram.proxy]
enable = false
url = "socks5://127.0.0.1:7890"

[aria2]
enable = false
url = "http://localhost:6800/jsonrpc"
secret = ""
remove_after_transfer = true

[api]
enable = false
host = "0.0.0.0"
port = 8080
token = "${RAND_API_TOKEN}"

[[storages]]
name = "本机1"
type = "local"
enable = true
base_path = "./downloads"

[[users]]
id = ${tg_user_id}
storages = []
blacklist = true
EOF

    # 2. 动态生成符合要求的 docker-compose.yml 配置文件 (应用自定义下载路径)
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  saveany-bot:
    image: ghcr.io/krau/saveany-bot:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    volumes:
      - ${BASE_DIR}/data:/app/data
      - ${CONFIG_FILE}:/app/config.toml
      - ${custom_downloads}:/app/downloads
      - ${BASE_DIR}/cache:/app/cache
    network_mode: host
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 SaveAny-Bot 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     SaveAny-Bot 部署成功！     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前管理员 ID  : $tg_user_id${RESET}"
    echo -e "${YELLOW}宿主机下载路径 : $custom_downloads${RESET}"
    echo -e "${YELLOW}提示: 已经成功将下载目录映射至您自定义的路径。${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 SaveAny-Bot 镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 SaveAny-Bot 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 SaveAny-Bot
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 SaveAny-Bot 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            # 提前捕获下载路径，防止 down 之后读不到 inspect
            get_status_info
            local current_download_dir="$data_dir"

            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除配置文件、缓存以及已下载的文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                # 如果自定义下载路径不在 BASE_DIR 下，单独将其清理
                if [[ "$current_download_dir" != "$BASE_DIR"* && -d "$current_download_dir" ]]; then
                    rm -rf "$current_download_dir"
                fi
                echo -e "${GREEN}所有数据和自定义下载目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_translate() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务网络模式   : ${webui_port}${RESET}"
    echo -e "${YELLOW}宿主机下载路径 : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}◈  SaveAny-Bot 机器人管理面板  ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}路径 :${RESET} ${YELLOW}${data_dir}${RESET}"
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
