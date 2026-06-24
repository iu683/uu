#!/bin/bash
# =================================================================
# KaraKeep 服务 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/karakeep"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取多个容器的状态、映射端口和数据目录
get_status_info() {
    # 1. 检查各个容器状态
    k_status="${RED}已停止/未部署${RESET}"
    m_status="${RED}已停止/未部署${RESET}"
    c_status="${RED}已停止/未部署${RESET}"

    if [ "$(docker ps -q -f name=karakeep-karakeep-1)" ] || [ "$(docker ps -q -f name=karakeep-1)" ]; then k_status="${YELLOW}运行中${RESET}"; fi
    if [ "$(docker ps -q -f name=karakeep-meilisearch-1)" ] || [ "$(docker ps -f name=meilisearch-1)" ]; then m_status="${YELLOW}运行中${RESET}"; fi
    if [ "$(docker ps -q -f name=karakeep-chrome-1)" ] || [ "$(docker ps -q -f name=chrome-1)" ]; then c_status="${YELLOW}运行中${RESET}"; fi

    # 2. 从 .env 文件中提取配置信息（如果存在）
    if [ -f "$ENV_FILE" ]; then
        webui_port=$(grep "NEXTAUTH_URL=" "$ENV_FILE" | awk -F':' '{print $3}' | sed 's/\r//g')
        [[ -z "$webui_port" ]] && webui_port="8088"
        img_version=$(grep "KARAKEEP_VERSION=" "$ENV_FILE" | cut -d'=' -f2 | sed 's/\r//g')
        [[ -z "$img_version" ]] && img_version="release"
        
        # 从 docker-compose.yml 中提取实际挂载的宿主机数据根目录
        if [ -f "$COMPOSE_FILE" ]; then
            data_dir=$(grep -A 1 "./data/karakeep" "$COMPOSE_FILE" 2>/dev/null | grep -v "karakeep" | awk -F':' '{print $1}' | sed 's/^[ \t]*//')
            # 兼容读取自定义绝对路径的情况
            data_dir=$(grep "karakeep:" "$COMPOSE_FILE" -A 10 | grep "\- " | grep "/karakeep:" | awk -F':' '{print $1}' | sed 's/-//g' | sed 's/^[ \t]*//' | head -n 1)
            [[ -z "$data_dir" ]] && data_dir=$(grep "meilisearch:" "$COMPOSE_FILE" -A 10 | grep "\- " | grep "/meilisearch:" | awk -F':' '{print $1}' | sed 's/-//g' | sed 's/^[ \t]*//' | head -n 1)
        fi
        [[ -z "$data_dir" ]] && data_dir="$BASE_DIR/data"
    else
        webui_port="N/A"
        img_version="${RED}未安装${RESET}"
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

# 部署 KaraKeep
install_translate() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 配置映射端口
    echo -ne "${YELLOW}请输入 KaraKeep 访问端口 (宿主机端口) [默认: 8088]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8088"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 2. 配置数据目录（支持自定义）
    echo -ne "${YELLOW}请输入宿主机数据存储绝对路径 [默认: /opt/karakeep/data]: ${RESET}"
    read -r custom_data
    [[ -z "$custom_data" ]] && custom_data="/opt/karakeep/data"

    # 3. 配置外部 Auth 认证 URL
    DETECT_IP=$(get_public_ip)
    echo -ne "${YELLOW}请输入外部访问的完整 URL (用于 Auth 认证) [默认: http://${DETECT_IP}:${custom_port}]: ${RESET}"
    read -r custom_url
    [[ -z "$custom_url" ]] && custom_url="http://${DETECT_IP}:${custom_port}"

    # 随机生成安全密钥
    rand_secret=$(date +%s | sha256sum | base64 | head -c 32)
    rand_meili=$(date +%s | sha256sum | head -c 16)

    # 创建自定义持久化子目录
    mkdir -p "${custom_data}/karakeep" "${custom_data}/meilisearch"
    chmod -R 777 "$BASE_DIR" "${custom_data}"

    # 生成环境变量 .env 配置文件
    echo -e "${YELLOW}正在生成环境变量 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
KARAKEEP_VERSION=release
NEXTAUTH_SECRET=${rand_secret}
MEILI_MASTER_KEY=${rand_meili}
NEXTAUTH_URL=${custom_url}
EOF

    # 动态生成 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  karakeep:
    image: ghcr.io/karakeep-app/karakeep:\${KARAKEEP_VERSION:-release}
    restart: unless-stopped
    ports:
      - "${custom_port}:3000"
    volumes:
      - "${custom_data}/karakeep:/data"
    environment:
      - DATA_DIR=/data
      - MEILI_ADDR=http://meilisearch:7700
      - MEILI_MASTER_KEY=\${MEILI_MASTER_KEY}
      - BROWSER_WEB_URL=http://chrome:9222
      - NEXTAUTH_URL=\${NEXTAUTH_URL}
      - NEXTAUTH_SECRET=\${NEXTAUTH_SECRET}
      - DISABLE_SIGNUPS=false
      - INFERENCE_LANG=中文
      - CRAWLER_NUM_WORKERS=5
      - CRAWLER_VIDEO_DOWNLOAD=true
      - CRAWLER_VIDEO_DOWNLOAD_MAX_SIZE=-1
    depends_on:
      - meilisearch
      - chrome

  meilisearch:
    image: getmeili/meilisearch:v1.13.3
    restart: unless-stopped
    volumes:
      - "${custom_data}/meilisearch:/meili_data"
    environment:
      - MEILI_MASTER_KEY=\\${MEILI_MASTER_KEY}
      - MEILI_NO_ANALYTICS=true

  chrome:
    image: ghcr.io/zenika/alpine-chrome:124
    restart: unless-stopped
    command:
      - --no-sandbox
      - --disable-gpu
      - --disable-dev-shm-usage
      - --remote-debugging-address=0.0.0.0
      - --remote-debugging-port=9222
      - --hide-scrollbars
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 KaraKeep 及其依赖服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务初始化 (约5秒)...${RESET}"
    sleep 5

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      KaraKeep 部署成功！      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : ${custom_url}${RESET}"
    echo -e "${YELLOW}面板配置主目录 : $BASE_DIR${RESET}"
    echo -e "${YELLOW}用户数据存储器 : ${custom_data}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新所有镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像组件...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！所有容器已处于最新状态。${RESET}"
}

# 卸载服务
uninstall_translate() {
    get_status_info
    echo -ne "${YELLOW}确定要卸载并删除所有 KaraKeep 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有自定义的持久化数据和配置文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                # 清理自定义的数据路径
                if [ -d "$data_dir" ] && [ "$data_dir" != "N/A" ]; then
                    rm -rf "$data_dir"
                    echo -e "${GREEN}外部自定义数据目录 [${data_dir}] 已彻底清理。${RESET}"
                fi
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}项目配置主目录 [${BASE_DIR}] 已彻底清理。${RESET}"
            fi
        else
            echo -e "${RED}未找到 compose 文件，尝试强制清理可能残留的容器...${RESET}"
            docker rm -f $(docker ps -aq -f name=karakeep) 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}所有容器已启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}所有容器已停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}所有容器已重启${RESET}"; }
logs_translate() { cd "$BASE_DIR" && docker compose logs -f; }

show_info() {
    get_status_info
    local current_url=$(grep "NEXTAUTH_URL=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}应用主服务 (KaraKeep) : ${k_status}"
    echo -e "${YELLOW}搜索数据库 (Meili)    : ${m_status}"
    echo -e "${YELLOW}无头浏览器 (Chrome)   : ${c_status}"
    echo -e "${YELLOW}应用发布版本          : ${img_version}${RESET}"
    echo -e "${YELLOW}外部认证地址          : ${current_url:-N/A}${RESET}"
    echo -e "${YELLOW}数据实际存储路径      : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  KaraKeep 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}应用主服务 (KaraKeep) : ${k_status}"
    echo -e "${GREEN}搜索数据库 (Meili)    : ${m_status}"
    echo -e "${GREEN}无头浏览器 (Chrome)   : ${c_status}"
    echo -e "${GREEN}项目映射端口          : ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新服务${RESET}"
    echo -e "${GREEN}3. 卸载服务${RESET}"
    echo -e "${GREEN}4. 启动服务${RESET}"
    echo -e "${GREEN}5. 停止服务${RESET}"
    echo -e "${GREEN}6. 重举服务${RESET}"
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
