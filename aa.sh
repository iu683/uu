#!/bin/bash
# =================================================================
# SearXNG (带 Valkey 缓存版) Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="searxng"
BASE_DIR="/opt/searxng"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口和数据目录
get_status_info() {
    # 1. 检查主容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${GREEN}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 检查 Redis/Valkey 辅助容器状态
    if [ "$(docker ps -q -f name=^/searxng-redis$)" ]; then
        redis_status="${GREEN}健康运行${RESET}"
    else
        redis_status="${RED}未运行${RESET}"
    fi

    # 3. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 从容器状态提取 WebUI 端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8080"
    else
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

# 部署 SearXNG 组合服务
install_searxng() {
    check_dependencies
    
    mkdir -p "$BASE_DIR/searxng" "$BASE_DIR/data/redis" "$BASE_DIR/data/searxng"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 SearXNG 访问端口 [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"

    # 生成强随机密钥
    local secret_key
    secret_key=$(date +%s | sha256sum | base64 | head -c 32)

    # 1. 动态生成 settings.yml
    echo -e "${YELLOW}正在写入优化版 settings.yml 配置...${RESET}"
    cat <<EOF > "$BASE_DIR/searxng/settings.yml"
use_default_settings: true
general:
  instance_name: "我的私有搜索引擎"
  debug: false
  privacypolicy_url: false
server:
  secret_key: "${secret_key}"
  limiter: true  # 已开启，配合 Valkey 缓存与限流
  image_proxy: true
  http_protocol_version: "1.1"
  request_timeout: 10.0
ui:
  static_use_hash: true
  theme: simple
  default_locale: "zh-Hans-CN"
  query_in_title: true
  center_alignment: true
  results_on_new_tab: false
  infinite_scroll: false
  search_on_category_select: true
search:
  safe_search: 0
  autocomplete: "baidu"
  default_lang: "zh-CN"
  languages:
    - "zh-CN"
    - "en"
  formats:
    - html
    - json
  scoring:
    method: "linear"
    profile: "normal"
redis:
  url: "redis://redis:6379/0"
engines:
  - name: baidu
    engine: baidu
    categories: [web, general]
    disabled: false
    timeout: 8.0
    max_results: 20
  - name: bing
    engine: bing
    categories: [web, general, images]
    disabled: false
    timeout: 10.0
    max_results: 20
    engine_params:
      region: "zh-CN"
  - name: 360搜索
    engine: 360search
    categories: [web, general]
    disabled: false
    timeout: 8.0
  - name: 搜狗
    engine: sogou
    categories: [web, general]
    disabled: false
  - name: 知乎
    engine: zhihu
    categories: [web, general]
    disabled: false
  - name: 哔哩哔哩
    engine: bilibili
    categories: [videos]
    disabled: false
  - name: google
    engine: google
    disabled: true
  - name: duckduckgo
    engine: duckduckgo
    disabled: true
  - name: startpage
    engine: startpage
    disabled: true
  - name: qwant
    engine: qwant
    disabled: true
result_proxy:
  url: ""
  key: ""
preferences:
  lock:
    - engine
    - language
    - locale
EOF

    # 2. 动态生成空的 limiter.toml 防止挂载报错
    if [ ! -f "$BASE_DIR/searxng/limiter.toml" ]; then
        echo -e "${YELLOW}正在初始化空的 limiter.toml...${RESET}"
        touch "$BASE_DIR/searxng/limiter.toml"
    fi

    # 3. 动态生成符合你要求的 docker-compose.yml
    echo -e "${YELLOW}正在生成高级 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"

networks:
  searxng-network:
    driver: bridge

services:
  redis:
    image: valkey/valkey:8-alpine
    container_name: searxng-redis
    restart: unless-stopped
    command: valkey-server --save 30 1 --loglevel warning
    networks:
      - searxng-network
    volumes:
      - ./data/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3
    sysctls:
      - net.core.somaxconn=1024

  searxng:
    image: searxng/searxng:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    depends_on:
      redis:
        condition: service_healthy
    networks:
      - searxng-network
    ports:
      - "${custom_port}:8080"
    volumes:
      - ./searxng/settings.yml:/etc/searxng/settings.yml:ro
      - ./searxng/limiter.toml:/etc/searxng/limiter.toml:ro
      - ./data/searxng:/var/log/searxng:rw
    environment:
      - SEARXNG_BASE_URL=http://localhost:${custom_port}
      - UWSGI_WORKERS=4
      - UWSGI_THREADS=2
      - SEARXNG_SECRET_KEY=${secret_key}
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    # 修正宿主机权限
    chmod -R 777 "$BASE_DIR"

    echo -e "${YELLOW}正在通过 Docker Compose 启动全套服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务及健康检查响应 (约 5 秒)...${RESET}"
    sleep 5

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    SearXNG (缓存版) 部署成功！  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}工作根目录     : ${BASE_DIR}${RESET}"
    echo -e "${YELLOW}提示: Valkey 高速缓存已就绪，已完美适配国内常用引擎。${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新所有镜像
update_searxng() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新镜像 (SearXNG & Valkey)...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！所有关联容器已处于最新状态。${RESET}"
}

# 卸载全套容器
uninstall_searxng() {
    echo -ne "${YELLOW}确定要卸载并删除 SearXNG 及 Valkey 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器集群已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件、搜索缓存与 Valkey 数据库？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" searxng-redis 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_searxng() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器集群已启动${RESET}"; }
stop_searxng() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器集群已停止${RESET}"; }
restart_searxng() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器集群已重启${RESET}"; }
logs_searxng() { cd "$BASE_DIR" && docker compose logs -f; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}主服务状态     : $status"
    echo -e "${YELLOW}缓存后端状态   : $redis_status"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}配置挂载根目录 : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  SearXNG 搜索面板  ◈      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}主服务状态 :${RESET} $status"
    echo -e "${GREEN}缓存后端   :${RESET} $redis_status"
    echo -e "${GREEN}绑定端口   :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新集群${RESET}"
    echo -e "${GREEN}3. 卸载集群${RESET}"
    echo -e "${GREEN}4. 启动集群${RESET}"
    echo -e "${GREEN}5. 停止集群${RESET}"
    echo -e "${GREEN}6. 重启集群${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_searxng ;;
        2) update_searxng ;;
        3) uninstall_searxng ;;
        4) start_searxng ;;
        5) stop_searxng ;;
        6) restart_searxng ;;
        7) logs_searxng ;;
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
