#!/bin/bash
# =================================================================
# Pocket-ID 身份验证中心 集成管理面板 (含标准 sites-available 反代)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="pocket-id"
BASE_DIR="/opt/pocket-id"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 自动探测 Nginx 最佳配置目录
get_nginx_config_paths() {
    if [[ -d "/etc/nginx/sites-available" ]]; then
        NGINX_AVAILABLE_DIR="/etc/nginx/sites-available"
        NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
        USE_SITES_STRUCTURE=true
    else
        NGINX_AVAILABLE_DIR="/etc/nginx/conf.d"
        USE_SITES_STRUCTURE=false
    fi
}

# 检测基础依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态和端口
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
        [[ -z "$img_version" ]] && img_version="v2"

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "1411/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="1411"
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
# 1. 部署 Pocket-ID
install_utils() {
    check_dependencies
    mkdir -p "$BASE_DIR/data"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入本地监听端口 [默认: 1411]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="1411"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -e "${YELLOW}正在自动生成安全加密密钥 (ENCRYPTION_KEY)...${RESET}"
    if command -v openssl &> /dev/null; then
        auto_key=$(openssl rand -base64 32)
    else
        auto_key=$(date +%s | sha256sum | base64 | head -c 44)
    fi

    DETECT_IP=$(get_public_ip)
    echo -e "${YELLOW}正在生成环境变量文件 .env...${RESET}"
    cat <<EOF > "$ENV_FILE"
APP_URL=http://${DETECT_IP}:${custom_port}
ENCRYPTION_KEY=${auto_key}
TRUST_PROXY=true
MAXMIND_LICENSE_KEY=
GEOLITE_DB_PATH=data/GeoLite2-City.mmdb
PUID=1000
PGID=1000
LOG_LEVEL=info
LOG_JSON=true
ANALYTICS_DISABLED=true
ALLOW_USER_SIGNUPS=open
EOF

    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  pocket-id:
    image: ghcr.io/pocket-id/pocket-id:v2
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    env_file: .env
    ports:
      - "127.0.0.1:${custom_port}:1411"
    volumes:
      - "./data:/app/data"
    healthcheck:
      test: [ "CMD", "/app/pocket-id", "healthcheck" ]
      interval: 1m30s
      timeout: 5s
      retries: 2
      start_period: 10s
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Pocket-ID...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate
    sleep 5

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}      Pocket-ID 部署成功！      ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}本地安全监听端口 : 127.0.0.1:${custom_port}${RESET}"
    echo -e "${CYAN}提示: 当前容器仅监听在本机，请紧接着进入 [选项 9] 配置反向代理公网域名访问！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 2. 更新 Pocket-ID 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 部署！${RESET}"; return; fi
    cd "$BASE_DIR" && docker compose pull && docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！${RESET}"
}

# 3. 卸载 Pocket-ID
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 Pocket-ID 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            get_nginx_config_paths
            cd "$BASE_DIR" && docker compose down
            
            # 彻底清理可能留存的所有形式反代配置与软链
            if [[ -f "$ENV_FILE" ]]; then
                local d_name=$(grep -E '^APP_URL=' "$ENV_FILE" | cut -d'/' -f3)
                if [[ -n "$d_name" ]]; then
                    rm -f "/etc/nginx/sites-available/${d_name}"
                    rm -f "/etc/nginx/sites-enabled/${d_name}"
                    rm -f "/etc/nginx/conf.d/${d_name}.conf"
                    rm -f "$BASE_DIR/${d_name}.conf"
                fi
            fi
            rm -rf "$BASE_DIR"
            [[ -x "$(command -v nginx)" ]] && systemctl reload nginx 2>/dev/null
            echo -e "${GREEN}全套数据及反代环境已彻底清理。${RESET}"
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

# 9. 独立反向代理管理菜单
nginx_proxy_menu() {
    get_nginx_config_paths
    while true; do
        clear
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}  ◈  Nginx 反向代理管理菜单 ◈  ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}1. 自动配置/覆盖反向代理${RESET}"
        echo -e "${GREEN}2. 卸载/删除反向代理配置${RESET}"
        echo -e "${GREEN}3. 检查 Nginx 语法并重载${RESET}"
        echo -e "${GREEN}0. 返回主菜单${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -ne "${GREEN}请输入选项: ${RESET}"
        read -r n_choice
        case "$n_choice" in
            1)
                get_status_info
                if [[ "$webui_port" == "N/A" ]]; then
                    echo -e "${RED}错误：请先在主菜单部署 Pocket-ID 容器后再进行反代配置！${RESET}"
                    read -r; continue
                fi
                
                echo -ne "${YELLOW}请输入 Pocket-ID 规划域名 (如: id.66666.xyz): ${RESET}"
                read -r domain_name
                if [[ -z "$domain_name" ]]; then echo -e "${RED}错误: 域名不能为空！${RESET}"; read -r; continue; fi
                
                echo -ne "${YELLOW}请输入 SSL 证书 (.pem/.crt) 绝对路径: ${RESET}"
                read -r ssl_cert_path
                echo -ne "${YELLOW}请输入 SSL 私钥 (.key) 绝对路径: ${RESET}"
                read -r ssl_key_path
                if [[ -z "$ssl_cert_path" || -z "$ssl_key_path" ]]; then echo -e "${RED}错误: 证书或私钥路径不能为空！${RESET}"; read -r; continue; fi

                # 更新 .env
                if [[ -f "$ENV_FILE" ]]; then
                    sed -i "s|^APP_URL=.*|APP_URL=https://${domain_name}|g" "$ENV_FILE"
                    cd "$BASE_DIR" && docker compose up -d
                fi

                # 确立实际配置文件目标
                local nginx_conf_file=""
                if ! command -v nginx &> /dev/null; then
                    echo -e "${RED}未检测到 Nginx 环境，文件将输出至 $BASE_DIR/${domain_name}.conf${RESET}"
                    nginx_conf_file="$BASE_DIR/${domain_name}.conf"
                elif [ "$USE_SITES_STRUCTURE" = true ]; then
                    nginx_conf_file="${NGINX_AVAILABLE_DIR}/${domain_name}"
                else
                    nginx_conf_file="${NGINX_AVAILABLE_DIR}/${domain_name}.conf"
                fi
                
                cat <<EOF > "$nginx_conf_file"
server {
    listen 80;
    listen [::]:80;
    server_name ${domain_name};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain_name};

    ssl_certificate ${ssl_cert_path};
    ssl_certificate_key ${ssl_key_path};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ecdh_curve X25519:P-256:P-384;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-CHACHA20-POLY1305:ECDHE+AES128:RSA+AES128:ECDHE+AES256:RSA+AES256';
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    access_log /var/log/nginx/${domain_name}.access.log;
    error_log /var/log/nginx/${domain_name}.error.log;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;

    proxy_busy_buffers_size 512k;
    proxy_buffers 4 512k;
    proxy_buffer_size 256k;

    location / {
        proxy_pass http://127.0.0.1:${webui_port};
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$realip_remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
                # 如果是 sites-available 架构，自动创建软链激活
                if [ "$USE_SITES_STRUCTURE" = true ] && [ -d "$NGINX_ENABLED_DIR" ]; then
                    ln -sf "$nginx_conf_file" "${NGINX_ENABLED_DIR}/${domain_name}"
                    echo -e "${GREEN}已创建软链接激活配置: ${NGINX_ENABLED_DIR}/${domain_name}${RESET}"
                fi

                echo -e "${GREEN}配置文件已写入: $nginx_conf_file${RESET}"
                if command -v nginx &> /dev/null; then
                    nginx -t &>/dev/null && systemctl reload nginx && echo -e "${GREEN}Nginx 热重载成功！反代已生效。${RESET}" || echo -e "${RED}警告: Nginx 测试未通过，请检查证书路径！${RESET}"
                fi
                read -r; break
                ;;
            2)
                if [[ -f "$ENV_FILE" ]]; then
                    local d_name=$(grep -E '^APP_URL=' "$ENV_FILE" | cut -d'/' -f3)
                    if [[ -n "$d_name" ]]; then
                        rm -f "/etc/nginx/sites-available/${d_name}"
                        rm -f "/etc/nginx/sites-enabled/${d_name}"
                        rm -f "/etc/nginx/conf.d/${d_name}.conf"
                        rm -f "$BASE_DIR/${d_name}.conf"
                        [[ -x "$(command -v nginx)" ]] && systemctl reload nginx 2>/dev/null
                        echo -e "${GREEN}已成功删除域名为 ${d_name} 的全部反代配置文件及软链！${RESET}"
                        DETECT_IP=$(get_public_ip)
                        sed -i "s|^APP_URL=.*|APP_URL=http://${DETECT_IP}:${webui_port}|g" "$ENV_FILE"
                        cd "$BASE_DIR" && docker compose up -d
                    else
                        echo -e "${YELLOW}未检测到可清理的反代配置文件。${RESET}"
                    fi
                else
                    echo -e "${RED}错误：未找到环境文件，无法识别域名。${RESET}"
                fi
                read -r; break
                ;;
            3)
                if command -v nginx &> /dev/null; then
                    nginx -t && systemctl reload nginx && echo -e "${GREEN}重载成功！${RESET}"
                else
                    echo -e "${RED}当前服务器未安装原生 Nginx。${RESET}"
                fi
                read -r; break
                ;;
            0) return ;;
            *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
        esac
    done
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}当前镜像       : ${img_version}${RESET}"
    if [[ -f "$ENV_FILE" ]]; then
        local current_url=$(grep -E '^APP_URL=' "$ENV_FILE" | cut -d'=' -f2-)
        echo -e "${YELLOW}当前配置域名  : ${CYAN}${current_url}${RESET}"
    fi
    echo -e "${YELLOW}容器本地监听   : 127.0.0.1:${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Pocket-ID 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}127.0.0.1:${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新服务${RESET}"
    echo -e "${GREEN}3. 卸载服务${RESET}"
    echo -e "${GREEN}4. 启动服务${RESET}"
    echo -e "${GREEN}5. 停止服务${RESET}"
    echo -e "${GREEN}6. 重启服务${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}9. 反向代理${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_utils ;;
        2) update_utils ;;
        3) uninstall_utils ;;
        4) start_utils ;;
        5) stop_utils ;;
        6) restart_utils ;;
        7) logs_utils ;;
        8) show_info ;;
        9) nginx_proxy_menu ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
