#!/bin/bash
# =================================================================
# 015 临时文件/文本分享平台 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="015-app"
BASE_DIR="/opt/015"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
CONFIG_FILE="$BASE_DIR/config.yaml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 生成随机密钥的辅助函数
generate_random_secret() {
    if command -v openssl &> /dev/null; then
        openssl_rand=$(openssl rand -hex 16 2>/dev/null)
        if [[ -n "$openssl_rand" ]]; then
            echo "$openssl_rand"
            return 0
        fi
    fi
    echo "sec_$(date +%s)_$((RANDOM % 10000))"
}

# 动态获取容器状态、映射端口和数据目录
get_status_info() {
    # 1. 检查核心 Web 容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取核心镜像版本
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 从容器状态提取 WebUI 端口（容器内部默认监听的是 80 端口）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        # 兜底获取第一个绑定的端口
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8080"

        # 从容器状态提取挂载的数据路径
        data_dir=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/upload"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$data_dir" ]] && data_dir="$BASE_DIR/uploads"
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

# 部署 015 平台
install_translate() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 015 访问端口 (宿主机端口) [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入文件上传存储的宿主机绝对路径 [默认: $BASE_DIR/uploads]: ${RESET}"
    read -r custom_data
    [[ -z "$custom_data" ]] && custom_data="$BASE_DIR/uploads"

    # 创建所需的宿主机目录并赋权
    mkdir -p "$custom_data"
    chmod -R 777 "$BASE_DIR" "$custom_data"

    # 获取动态公网 IP
    DETECT_IP=$(get_public_ip)
    
    # 生成随机且高安全性的 Secret 和 Salt
    RAND_SECRET=$(generate_random_secret)
    RAND_SALT=$(generate_random_secret)

    # 1. 动态生成符合要求的 config.yaml 配置文件
    echo -e "${YELLOW}正在生成系统配套的 config.yaml 配置文件...${RESET}"
    cat <<EOF > "$CONFIG_FILE"
share:
    # 自动生成的下载jwt secret令牌，有效期1小时
    download_secret: ${RAND_SECRET}
    # 颁发的下载token的窗口期，默认12小时
    download_window: 12
    # 自动生成的密码加盐
    password_salt: ${RAND_SALT}

upload:
    # 上传文件保存路径（容器内部固定为 /upload，与 compose 卷相对应）
    path: /upload
    # 实例最大上传容量
    maximum: 100GiB

redis:
    # 内部 redis 地址
    url: redis://015-redis:6379/0

features:
    file-share:
        enabled: true
    text-share:
        enabled: true
    file-image-compress:
        enabled: true
    file-image-convert:
        enabled: true

site:
    # 动态绑定的访问域名/URL
    url: http://${DETECT_IP}:${custom_port}
    title:
        'en': '015'
    desc:
        'en': '015 is an open-source temporary file sharing platform project that supports uploading, downloading, and sharing files and text.'
    icon: '/logo.png'
    bg_url: 'https://img.fudaoyuan.icu/api/1/random/?scale_min=1.5&webp=true&md=false&format=302'

about:
    bg_url: 'https://files.mastodon.social/site_uploads/files/000/000/001/@1x/57c12f441d083cde.png'
    content:
        'zh': |
            ### 015 临时文件分享平台
            欢迎使用本站分享文件或文本。
        'en': |
            ### 015 Temporary Share Platform
            Welcome to share files or texts here.
    email: admin@domain.com
    name: admin
    url: 'http://${DETECT_IP}:${custom_port}'
    avatar: ''
EOF

    # 2. 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  app:
    image: fudaoyuanicu/015-app:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    volumes:
      - ${custom_data}:/upload
      - ${CONFIG_FILE}:/app/config.yaml
    ports:
      - "${custom_port}:80"
    depends_on:
      - redis

  worker:
    image: fudaoyuanicu/015-worker:latest
    container_name: 015-worker
    restart: unless-stopped
    volumes:
      - ${custom_data}:/upload
      - ${CONFIG_FILE}:/app/config.yaml
    depends_on:
      - app
      - redis

  redis:
    image: redis:7-alpine
    container_name: 015-redis
    restart: unless-stopped
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 015 分享平台群组...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务容器初始化群组 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}       015 分享平台 部署成功！      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}宿主机存储路径 : $custom_data${RESET}"
    echo -e "${YELLOW}提示: 安全混淆密钥(Secret/Salt)已在 config.yaml 中为您全自动生成。${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 015 群组镜像
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 015 各组件的最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！所有关联容器已处于最新状态。${RESET}"
}

# 卸载 015 平台
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 015 容器环境吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器集群已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件和上传的缓存文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}主配置与数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 015-worker 015-redis 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}所有服务已启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}所有服务已停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}所有服务已重启${RESET}"; }
logs_translate() { cd "$BASE_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}核心镜像       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}宿主机数据路径 : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈   015 分享平台管理面板  ◈    ${RESET}"
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
