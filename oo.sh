#!/bin/bash
# =================================================================
# Emby-Proxy-Go 高性能流媒体代理网关 Docker Compose 自动化管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="emby-proxy"
BASE_DIR="/opt/emby-proxy"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态及网络端口映射
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="v1.3"

        # 提取 Web 访问端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="22567"
    else
        img_version="N/A"
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


# 部署核心逻辑
install_translate() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 网络代理网关端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Emby-Proxy 外网代理监听端口 [默认: 22567]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="22567"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "\n${YELLOW}正在构建符合高性能规范的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  emby-proxy:
    image: ghcr.io/gsy-allen/emby-proxy-go:v1.3
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${custom_port}:8080"
    logging:
      driver: 'local'
      options:
        max-size: '10m'
        max-file: '5'
    environment:
      LISTEN_ADDR: ':8080'
      BLOCK_PRIVATE_TARGETS: 'true'
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 启动 Emby-Proxy 高性能网关...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待 Go 代理引擎拉起网络端口 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}           Emby-Proxy 网关部署成功！              ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}代理公网入口地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}日志滚动安全策略 : local (最大 10MB * 5 自动截断，拒绝爆盘)${RESET}"
    echo -e "${YELLOW}安全沙箱防护     : BLOCK_PRIVATE_TARGETS=true (已拒绝探测内网)${RESET}"
    echo -e "${CYAN}🌐 使用方法: https://{你的反代域名}/{emby服务器协议}/{emby服务器地址}/{emby服务器端口}${RESET}"
    echo -e "${CYAN}💡 使用提示：请将客户端（如 Infuse、Emby App）连接地址指向此代理端口。${RESET}"
    echo -e "${CYAN}   网关将自动根据后台配置接管流量，实现公网播放与直链优化加速。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新服务
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在检查并拉取最新稳定版 Emby-Proxy 镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！Go 高性能流媒体代理网关已平滑重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并停止 Emby-Proxy 代理服务吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            rm -rf "$BASE_DIR"
            echo -e "${GREEN}网关已停止，相关编排配置目录已彻底清理。${RESET}"
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_translate() { docker logs -f --tail=100 "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态     : $status"
    echo -e "${YELLOW}网关镜像版本     : ${img_version}${RESET}"
    echo -e "${YELLOW}网关代理入口     : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}架构属性         : 高性能 Go 运行时 (状态无关/不占磁盘空间)${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}


# 9. 独立菜单：直接修改本机 Nginx 配置文件 (支持证书自定义路径)
setup_host_nginx() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${RED}错误: 请先执行选项 1 部署基础服务以确定本地映射端口！${RESET}"
        return
    fi

    # 自动获取当前容器在宿主机映射的实际端口
    local current_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
    [[ -z "$current_port" ]] && current_port="22567"

    echo -e "${CYAN}====== 宿主机独立 Nginx 自动化配置 ======${RESET}"
    echo -ne "${YELLOW}请输入您的反代域名 [默认: emby.eu.org]: ${RESET}"
    read -r custom_domain
    [[ -z "$custom_domain" ]] && custom_domain="emby.eu.org"

    # 1. 自动根据域名生成默认证书路径建议
    local default_cert_path="/etc/letsencrypt/live/${custom_domain}/fullchain.pem"
    local default_key_path="/etc/letsencrypt/live/${custom_domain}/privkey.pem"

    # 2. 允许用户交互修改或直接回车确认
    echo -e "\n${CYAN}====== 域名证书自定义路径配置 ======${RESET}"
    echo -e "${YELLOW}请输入证书 (fullchain.pem) 的宿主机绝对路径${RESET}"
    echo -ne "[默认: ${CYAN}${default_cert_path}${RESET}]: "
    read -r cert_path
    [[ -z "$cert_path" ]] && cert_path="$default_cert_path"

    echo -e "${YELLOW}请输入私钥 (privkey.pem) 的宿主机绝对路径${RESET}"
    echo -ne "[默认: ${CYAN}${default_key_path}${RESET}]: "
    read -r key_path
    [[ -z "$key_path" ]] && key_path="$default_key_path"

    # 定义宿主机 Nginx 网站配置路径
    local nginx_avail_file="/etc/nginx/sites-available/${custom_domain}"
    local nginx_enabled_file="/etc/nginx/sites-enabled/${custom_domain}"

    if [ ! -d "/etc/nginx/sites-available" ]; then
        echo -e "${RED}错误: 未在本机检测到 /etc/nginx/sites-available 目录，请确认本机是否正确安装并运行了 Nginx！${RESET}"
        return
    fi

    # 校验自定义输入的证书文件是否存在
    if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
        echo -e "\n${RED}警告: 宿主机未检测到指定的证书或私钥文件！${RESET}"
        echo -e "当前路径:\n证书: $cert_path\n私钥: $key_path"
        echo -ne "${YELLOW}是否强制继续生成 Nginx 站点配置？(y/n): ${RESET}"
        if [[ "$force_confirm" != "y" && "$force_confirm" != "Y" ]]; then
            return
        fi
    fi

    # 生成并写入宿主机的 Nginx 配置文件
    echo -e "\n${YELLOW}正在直接写入本机 Nginx 配置文件: ${CYAN}${nginx_avail_file}${RESET}"
    
    # 修复：这里改为 EOF 并不带单引号，代码块内部变量采用强转义规则，确保准确传给外部 Bash
    sudo bash -c "cat << EOF > ${nginx_avail_file}
# =================================================================
# Emby-Proxy-Go 高性能流媒体代理网关 - 本机 Nginx 自动化配置
# =================================================================

server {
    listen 80;
    listen [::]:80;
    server_name ${custom_domain};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\\\$host\\\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    
    server_name ${custom_domain};

    # 自定义指定的证书路径
    ssl_certificate ${cert_path};
    ssl_certificate_key ${key_path};
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    client_max_body_size 100M;

    location / {
        # 自动转发至本地 docker-compose 映射端口
        proxy_pass http://127.0.0.1:${current_port};
        
        proxy_set_header Host \\\$http_host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
        proxy_set_header X-Forwarded-Host \\\$http_host;

        # 禁用流媒体缓冲防止卡顿
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;

        # WebSocket 双向透传支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \\\$http_upgrade;
        proxy_set_header Connection \\"upgrade\\";

        proxy_read_timeout 360s;
        proxy_send_timeout 360s;
    }
}
EOF"

    # 创建软链接启用配置
    echo -e "${YELLOW}正在建立 Nginx sites-enabled 启用软链接...${RESET}"
    sudo ln -sf "$nginx_avail_file" "$nginx_enabled_file"

    # 测试 Nginx 配置并重载
    echo -e "${YELLOW}正在测试本机 Nginx 配置语法...${RESET}"
    if sudo nginx -t &>/dev/null; then
        echo -e "${YELLOW}语法正确，正在让本机 Nginx 平滑重载配置...${RESET}"
        sudo nginx -s reload
        echo -e "${GREEN}====================================================${RESET}"
        echo -e "${GREEN}      本机 Nginx 反向代理配置并重载成功！          ${RESET}"
        echo -e "${GREEN}====================================================${RESET}"
        echo -e "${YELLOW}外网 HTTPS 入口地址 : https://${custom_domain}${RESET}"
        echo -e "${YELLOW}已成功绑定外部证书  : ${cert_path}${RESET}"
        echo -e "${YELLOW}已成功将流量转发至  : 本地端口 ${current_port}${RESET}"
        echo -e "${GREEN}====================================================${RESET}"
    else
        echo -e "${RED}错误: Nginx 语法测试失败！${RESET}"
        echo -e "${RED}请检查证书文件是否有效或权限是否正确。站点配置已保存，您可以手动排查后执行 nginx -s reload。${RESET}"
        # 打印一下真实的报错，方便当场排查
        sudo nginx -t
    fi
}


menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈  Emby-Proxy-Go 管理面板  ◈ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态    :${RESET} $status"
    echo -e "${GREEN}端口    :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}9. 反向代理${RESET}"
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
        9) setup_host_nginx ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
