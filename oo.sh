#!/bin/bash
# =================================================================
# Tinyauth 认证服务 + Nginx 反代 + Pocket-ID 联动管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="tinyauth"
BASE_DIR="/opt/tinyauth"
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
        [[ -z "$img_version" ]] && img_version="v4"

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3000"
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
    fi
}

# 1. 部署 Tinyauth
install_utils() {
    check_dependencies
    mkdir -p "$BASE_DIR/data"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入本地监听端口 [默认: 3000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3000"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -e "${YELLOW}====================================================${RESET}"
    echo -e "${CYAN}接下来将进入 Tinyauth 官方交互式用户创建向导。${RESET}"
    echo -e "${CYAN}请在提示中输入用户名、密码，并在格式(Format)中选择 ${GREEN}docker${RESET} 格式。${RESET}"
    echo -e "${YELLOW}====================================================${RESET}"
    echo -ne "${YELLOW}准备好了吗？按回车键启动创建器... ${RESET}"
    read -r

    local tmp_log="$BASE_DIR/user_create.log"
    docker run -i -t --rm ghcr.io/steveiliop56/tinyauth:v4 user create --interactive | tee "$tmp_log"

    local extracted_user=$(grep -a "User created user=" "$tmp_log" | awk -F'user=' '{print $2}' | tr -d '\r' | tr -d '\n')
    rm -f "$tmp_log"

    if [[ -z "$extracted_user" ]]; then
        echo -e "${RED}错误: 未能成功捕获到用户 Hash！${RESET}"
        echo -ne "${YELLOW}是否手动输入创建好的 USERS 字符串? (例如 UserName:\$\$2a\$\$10\$\$...): ${RESET}"
        read -r extracted_user
        if [[ -z "$extracted_user" ]]; then
            echo -e "${RED}部署终止。${RESET}"
            return
        fi
    fi

    echo -e "${GREEN}成功捕获用户配置: ${YELLOW}$extracted_user${RESET}"

    echo -e "${YELLOW}正在生成环境变量文件 .env...${RESET}"
    cat <<EOF > "$ENV_FILE"
APP_URL=http://127.0.0.1:${custom_port}
USERS=${extracted_user}
DISABLE_ANALYTICS=true
LOG_JSON=true
SECURE_COOKIE=true
EOF

    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  tinyauth:
    image: ghcr.io/steveiliop56/tinyauth:v4
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "127.0.0.1:${custom_port}:3000"
    env_file: .env
    volumes:
      - ./data:/data
    healthcheck:
      test: ["CMD", "tinyauth", "healthcheck"]
      interval: 30s
      timeout: 5s
      start_period: 5s
      retries: 3
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Tinyauth...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate
    sleep 3

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}      Tinyauth 部署启动成功！      ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}本地安全监听端口 : 127.0.0.1:${custom_port}${RESET}"
    echo -e "${CYAN}提示: 建议紧接着进入 [选项 9] 配置反代域名，随后进入 [选项 10] 联动 Pocket-ID！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 2. 更新 Tinyauth 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then echo -e "${RED}错误: 未检测到配置文件！${RESET}"; return; fi
    cd "$BASE_DIR" && docker compose pull && docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！${RESET}"
}

# 3. 卸载 Tinyauth
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 Tinyauth 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            get_nginx_config_paths
            cd "$BASE_DIR" && docker compose down
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

# 10. 联动 Pocket-ID (OAuth2 配置)
configure_pocketid_oauth() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}错误: 未检测到环境配置文件，请先执行选项 1 部署服务！${RESET}"
        return
    fi

    # 提取当前配置的 Tinyauth 域名
    local tiny_url=$(grep -E '^APP_URL=' "$ENV_FILE" | cut -d'=' -f2-)
    
    echo -e "${CYAN}====== Pocket-ID OAuth2 联动配置 ======${RESET}"
    echo -e "${YELLOW}当前 Tinyauth 根地址为: ${GREEN}${tiny_url}${RESET}"
    echo -e "${YELLOW}联动前，请先在 Pocket-ID 后台创建一个应用(Application)。${RESET}"
    echo -e "${CYAN}其中，口袋 ID 里的 Redirect URL 必须填写为: ${RESET}"
    echo -e "${GREEN}${tiny_url}/api/oauth/callback/pocketid${RESET}"
    echo -e "${YELLOW}----------------------------------------------------${RESET}"
    
    echo -ne "${YELLOW}请输入 Pocket-ID 服务的完整域名 (如 pocketid.your.domain 或带 https): ${RESET}"
    read -r p_domain
    if [[ -z "$p_domain" ]]; then echo -e "${RED}配置终止：域名不能为空。${RESET}"; return; fi
    
    # 规范化域名格式
    if [[ "$p_domain" != http* ]]; then
        p_domain="https://${p_domain}"
    fi
    p_domain=$(echo "$p_domain" | sed 's|/*$||') # 移除末尾斜杠

    echo -ne "${YELLOW}请输入 Pocket-ID 生成的 Client ID: ${RESET}"
    read -r client_id
    echo -ne "${YELLOW}请输入 Pocket-ID 生成的 Client Secret: ${RESET}"
    read -r client_secret

    if [[ -z "$client_id" || -z "$client_secret" ]]; then
        echo -e "${RED}错误: Client ID 或 Secret 不能为空！${RESET}"
        return
    fi

    echo -e "${YELLOW}正在清理旧的 Pocket-ID 联动配置...${RESET}"
    sed -i '/^PROVIDERS_POCKETID_/d' "$ENV_FILE"

    echo -e "${YELLOW}正在向环境文件追加新的 OAuth2 配置参数...${RESET}"
    cat <<EOF >> "$ENV_FILE"
PROVIDERS_POCKETID_CLIENT_ID=${client_id}
PROVIDERS_POCKETID_CLIENT_SECRET=${client_secret}
PROVIDERS_POCKETID_AUTH_URL=${p_domain}/authorize
PROVIDERS_POCKETID_TOKEN_URL=${p_domain}/api/oidc/token
PROVIDERS_POCKETID_USER_INFO_URL=${p_domain}/api/oidc/userinfo
PROVIDERS_POCKETID_REDIRECT_URL=${tiny_url}/api/oauth/callback/pocketid
PROVIDERS_POCKETID_SCOPES=openid email profile groups
PROVIDERS_POCKETID_NAME=Pocket ID
EOF

    echo -e "${YELLOW}正在重启 Tinyauth 容器以应用 OAuth2 联动配置...${RESET}"
    cd "$BASE_DIR" && docker compose up -d
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}      Pocket-ID 单点登录(SSO) 联动配置成功！      ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}联动提供商名称 : Pocket ID${RESET}"
    echo -e "${YELLOW}认证端点路径   : ${p_domain}/authorize${RESET}"
    echo -e "${CYAN}现在你可以打开 Tinyauth 登录页，享受便捷的 Pocket-ID 快捷登录了！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 9. 独立反向代理管理菜单
nginx_proxy_menu() {
    get_nginx_config_paths
    while true; do
        clear
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}    ◈  Nginx 反向代理管理菜单 ◈  ${RESET}"
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
                    echo -e "${RED}错误：请先在主菜单部署 Tinyauth 容器后再进行反代配置！${RESET}"
                    read -r; continue
                fi
                
                echo -ne "${YELLOW}请输入 Tinyauth 规划域名 (如: tinyauth.your.domain): ${RESET}"
                read -r domain_name
                if [[ -z "$domain_name" ]]; then echo -e "${RED}错误: 域名不能为空！${RESET}"; read -r; continue; fi
                
                echo -ne "${YELLOW}请输入 SSL 证书 (.pem/.crt) 绝对路径: ${RESET}"
                read -r ssl_cert_path
                echo -ne "${YELLOW}请输入 SSL 私钥 (.key) 绝对路径: ${RESET}"
                read -r ssl_key_path
                if [[ -z "$ssl_cert_path" || -z "$ssl_key_path" ]]; then echo -e "${RED}错误: 证书或私钥路径不能为空！${RESET}"; read -r; continue; fi

                # 更新环境配置文件的真实公网域名响应
                if [[ -f "$ENV_FILE" ]]; then
                    sed -i "s|^APP_URL=.*|APP_URL=https://${domain_name}|g" "$ENV_FILE"
                    # 如果已经配置了 Pocket-ID，联动重置 Redirect_URL
                    if grep -q "PROVIDERS_POCKETID_REDIRECT_URL" "$ENV_FILE"; then
                        sed -i "s|^PROVIDERS_POCKETID_REDIRECT_URL=.*|PROVIDERS_POCKETID_REDIRECT_URL=https://${domain_name}/api/oauth/callback/pocketid|g" "$ENV_FILE"
                    fi
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
    add_header Content-Security-Policy "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-eval';" always;

    proxy_set_header Host \$http_host;
    proxy_set_header X-Forwarded-For \$realip_remote_addr;

    location / {
        proxy_pass http://127.0.0.1:${webui_port};
        proxy_http_version 1.1;
    }
}
EOF
                if [ "$USE_SITES_STRUCTURE" = true ] && [ -d "$NGINX_ENABLED_DIR" ]; then
                    ln -sf "$nginx_conf_file" "${NGINX_ENABLED_DIR}/${domain_name}"
                fi

                echo -e "${GREEN}配置文件已成功写入: $nginx_conf_file${RESET}"
                if command -v nginx &> /dev/null; then
                    nginx -t &>/dev/null && systemctl reload nginx && echo -e "${GREEN}Nginx 重载成功！反代已生效。${RESET}" || echo -e "${RED}警告: Nginx 语法测试失败，请检查证书路径！${RESET}"
                fi
                read -r; break
                ;;
            2)
                if [[ -f "$ENV_FILE" ]]; then
                    local d_name=$(grep -E '^APP_URL=' "$ENV_FILE" | cut -d'/' -f3)
                    if [[ -n "$d_name" ]]; then
                        rm -f "/etc/nginx/sites-available/${d_name}" "/etc/nginx/sites-enabled/${d_name}" "/etc/nginx/conf.d/${d_name}.conf" "$BASE_DIR/${d_name}.conf"
                        [[ -x "$(command -v nginx)" ]] && systemctl reload nginx 2>/dev/null
                        echo -e "${GREEN}已删除域名为 ${d_name} 的反代配置文件！${RESET}"
                        sed -i "s|^APP_URL=.*|APP_URL=http://127.0.0.1:${webui_port}|g" "$ENV_FILE"
                        cd "$BASE_DIR" && docker compose up -d
                    fi
                fi
                read -r; break
                ;;
            3)
                nginx -t && systemctl reload nginx && echo -e "${GREEN}Nginx 重载应用成功！${RESET}"
                read -r; break
                ;;
            0) return ;;
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
        if grep -q "PROVIDERS_POCKETID_CLIENT_ID" "$ENV_FILE"; then
            echo -e "${YELLOW}Pocket-ID SSO  : ${GREEN}已连接 (OAuth2 已激活)${RESET}"
        else
            echo -e "${YELLOW}Pocket-ID SSO  : ${RED}未连接${RESET}"
        fi
    fi
    echo -e "${YELLOW}容器本地监听   : 127.0.0.1:${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Tinyauth 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}127.0.0.1:${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动 (全新安装)${RESET}"
    echo -e "${GREEN}2. 更新服务${RESET}"
    echo -e "${GREEN}3. 卸载服务${RESET}"
    echo -e "${GREEN}4. 启动服务${RESET}"
    echo -e "${GREEN}5. 停止服务${RESET}"
    echo -e "${GREEN}6. 重启服务${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看详细状态${RESET}"
    echo -e "${CYAN}9. 反向代理（Nginx）管理专属菜单${RESET}"
    echo -e "${YELLOW}10. 联动 Pocket-ID (连接 OAuth2 单点登录)${RESET}"
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
        10) configure_pocketid_oauth ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
