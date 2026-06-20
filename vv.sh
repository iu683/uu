#!/bin/bash
# =================================================================
# Tinyauth v4.1.0+ 全能管理脚本 (基于最新 OAuth Broker 统一驱动)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
MAGENTA="\033[35m"
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
        [[ -z "$img_version" ]] && img_version="v4.1.0"

        if [[ -f "$ENV_FILE" ]]; then
            local env_url=$(grep -E '^APP_URL=' "$ENV_FILE" | cut -d'=' -f2-)
            webui_port=$(echo "$env_url" | awk -F':' '{print $3}' | cut -d'/' -f1)
            if [[ -z "$webui_port" ]]; then
                webui_port=$(echo "$env_url" | awk -F':' '{print $2}' | sed 's|//||' | cut -d'/' -f1)
            fi
        fi
        
        if [[ -z "$webui_port" || ! "$webui_port" =~ ^[0-9]+$ ]]; then
            webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
            [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        fi
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
        echo -ne "${YELLOW}请手动输入刚才创建好的 USERS 字符串 (例如 iucsy:\$2a\$10\$...): ${RESET}"
        read -r extracted_user
        if [[ -z "$extracted_user" ]]; then return; fi
    fi

    local safe_users_string=$(echo "$extracted_user" | sed 's/\$/\$\$/g')

    cat <<EOF > "$ENV_FILE"
APP_URL=http://127.0.0.1:${custom_port}
USERS=${safe_users_string}
DISABLE_ANALYTICS=true
LOG_JSON=true
SECURE_COOKIE=true
EOF

    cat <<EOF > "$COMPOSE_FILE"
services:
  tinyauth:
    image: ghcr.io/steveiliop56/tinyauth:latest
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

    cd "$BASE_DIR" && docker compose up -d --force-recreate
    sleep 2
}

# 10. 联动 Pocket-ID
configure_pocketid_oauth() {
    if [[ ! -f "$ENV_FILE" ]]; then echo -e "${RED}错误: 请先安装部署主程序！${RESET}"; return; fi
    local tiny_url=$(grep -E '^APP_URL=' "$ENV_FILE" | cut -d'=' -f2-)
    
    echo -e "${CYAN}====== Pocket-ID OAuth2 联动配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Pocket-ID 服务完整域名 (如 pocketid.your.domain): ${RESET}"
    read -r p_domain
    [[ -z "$p_domain" ]] && return
    [[ "$p_domain" != http* ]] && p_domain="https://${p_domain}"
    p_domain=$(echo "$p_domain" | sed 's|/*$||')

    echo -ne "${YELLOW}请输入 Client ID: ${RESET}"
    read -r client_id
    echo -ne "${YELLOW}请输入 Client Secret: ${RESET}"
    read -r client_secret

    # 针对 v4.1.0 统一重构环境变量命名空间
    sed -i '/^PROVIDERS_POCKETID_/d' "$ENV_FILE"
    sed -i '/^OAUTH_AUTO_REDIRECT=/d' "$ENV_FILE"
    cat <<EOF >> "$ENV_FILE"
PROVIDERS_POCKETID_CLIENT_ID=${client_id}
PROVIDERS_POCKETID_CLIENT_SECRET=${client_secret}
PROVIDERS_POCKETID_AUTH_URL=${p_domain}/authorize
PROVIDERS_POCKETID_TOKEN_URL=${p_domain}/api/oidc/token
PROVIDERS_POCKETID_USER_INFO_URL=${p_domain}/api/oidc/userinfo
PROVIDERS_POCKETID_REDIRECT_URL=${tiny_url}/api/oauth/callback/pocketid
PROVIDERS_POCKETID_SCOPES=openid email profile groups
PROVIDERS_POCKETID_NAME=Pocket ID
OAUTH_AUTO_REDIRECT=pocketid
EOF
    cd "$BASE_DIR" && docker compose up -d
    echo -e "${GREEN}Pocket-ID 联动配置已更新，且已激活自动重定向！${RESET}"
}

# 11. 智能配置第三方应用前置鉴权守卫 (auth_request)
configure_app_guard() {
    get_status_info
    if [[ ! -f "$ENV_FILE" ]]; then echo -e "${RED}错误：请先部署主服务！${RESET}"; return; fi
    get_nginx_config_paths
    local current_sso_url=$(grep -E '^APP_URL=' "$ENV_FILE" | cut -d'=' -f2-)
    
    echo -e "${CYAN}====== 配置第三方应用 Nginx 前置鉴权守卫 ======${RESET}"
    echo -ne "${YELLOW}请输入被保护应用的规划域名 (如: app.otg.dpdns.org): ${RESET}"
    read -r app_domain
    if [[ -z "$app_domain" ]]; then echo -e "${RED}域名不能为空！${RESET}"; return; fi

    echo -ne "${YELLOW}请输入被保护应用的本地后端地址 [默认 http://127.0.0.1:8082]: ${RESET}"
    read -r app_backend
    [[ -z "$app_backend" ]] && app_backend="http://127.0.0.1:8082"

    local default_cert="/etc/letsencrypt/live/${app_domain}/fullchain.pem"
    local default_key="/etc/letsencrypt/live/${app_domain}/privkey.pem"

    echo -ne "${YELLOW}请输入 SSL 证书路径 [直接回车使用默认: ${default_cert}]: ${RESET}"
    read -r app_cert
    [[ -z "$app_cert" ]] && app_cert="$default_cert"

    echo -ne "${YELLOW}请输入 SSL 私钥路径 [直接回车使用默认: ${default_key}]: ${RESET}"
    read -r app_key
    [[ -z "$app_key" ]] && app_key="$default_key"

    local guard_conf_file="${NGINX_AVAILABLE_DIR}/${app_domain}"
    [[ "$USE_SITES_STRUCTURE" = false ]] && guard_conf_file="${guard_conf_file}.conf"

    cat <<EOF > "$guard_conf_file"
server {
    listen 80;
    listen [::]:80;
    server_name ${app_domain};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${app_domain};

    ssl_certificate ${app_cert};
    ssl_certificate_key ${app_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    access_log /var/log/nginx/${app_domain}.access.log;
    error_log /var/log/nginx/${app_domain}.error.log;

    location = /manifest.json { proxy_pass ${app_backend}; }
    location = /favicon.ico { proxy_pass ${app_backend}; }
    location ^~ /assets/ { proxy_pass ${app_backend}; }

    location ^~ / {
        proxy_pass ${app_backend};

        auth_request /_tinyauth_check;
        error_page 401 = @tinyauth_login;

        auth_request_set \$ta_user \$upstream_http_remote_user;
        proxy_set_header Remote-User \$ta_user;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header REMOTE-HOST \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_http_version 1.1;
        add_header Cache-Control no-cache;
    }

    location = /_tinyauth_check {
        internal;
        proxy_pass http://127.0.0.1:${webui_port}/api/auth/nginx;
        proxy_set_header x-forwarded-proto \$scheme;
        proxy_set_header x-forwarded-host  \$host;
        proxy_set_header x-forwarded-uri   \$request_uri;
    }

    location @tinyauth_login {
        return 302 ${current_sso_url}/login?redirect_uri=\$scheme://\$host\$request_uri;
    }
}
EOF

    if [ "$USE_SITES_STRUCTURE" = true ] && [ -d "$NGINX_ENABLED_DIR" ]; then
        ln -sf "$guard_conf_file" "${NGINX_ENABLED_DIR}/${app_domain}"
    fi

    echo -e "${GREEN}守护者配置文件已成功写入: $guard_conf_file${RESET}"
    if nginx -t &>/dev/null; then
        systemctl reload nginx
        echo -e "${GREEN}Nginx 热重载成功！前置守护拦截已全面生效。${RESET}"
    else
        echo -e "${RED}警告: Nginx 语法测试失败！请确保刚刚填充的证书链路径文件真实存在！${RESET}"
    fi
}

# 12. 联动 Casdoor / 通用 Generic OAuth2 认证 (全面对齐 v4 规范)
configure_casdoor_oauth() {
    if [[ ! -f "$ENV_FILE" ]]; then echo -e "${RED}错误: 请先安装部署 Tinyauth 主程序！${RESET}" ; return; fi
    local tiny_url=$(grep -E '^APP_URL=' "$ENV_FILE" | cut -d'=' -f2-)

    echo -e "${CYAN}====== Casdoor / 通用 Generic OAuth2 单点登录联动 ======${RESET}"
    echo -e "${YELLOW}当前 Tinyauth 中央认证根地址为: ${GREEN}${tiny_url}${RESET}"
    
    # 根据 v4.1.0 核心工厂，通用适配器的路由标识是 generic
    local computed_redirect="${tiny_url}/callback/generic"
    echo -e "${GREEN}请提前在你的 Casdoor 权限应用后台，将回调 URL 注册为: ${MAGENTA}${computed_redirect}${RESET}"
    echo -e "${YELLOW}-------------------------------------------------------------------------${RESET}"

    echo -ne "${YELLOW}请输入 Casdoor 按钮显示名称 [默认: Casdoor]: ${RESET}"
    read -r generic_name
    [[ -z "$generic_name" ]] && generic_name="Casdoor"

    echo -ne "${YELLOW}请输入 Casdoor Client ID: ${RESET}"
    read -r client_id
    echo -ne "${YELLOW}请输入 Casdoor Client Secret: ${RESET}"
    read -r client_secret

    echo -ne "${YELLOW}请输入 Casdoor 认证 URL (Authorize URL): ${RESET}"
    read -r auth_url
    echo -ne "${YELLOW}请输入 Casdoor 令牌 URL (Token URL): ${RESET}"
    read -r token_url
    echo -ne "${YELLOW}请输入 Casdoor 用户信息 URL (User Info URL): ${RESET}"
    read -r user_url

    echo -ne "${YELLOW}请输入授权作用域 Scope [默认: openid profile email]: ${RESET}"
    read -r scopes
    [[ -z "$scopes" ]] && scopes="openid profile email"

    # 清理旧的 Generic/Casdoor 环境变量，防止重合干扰
    sed -i '/^GENERIC_/d' "$ENV_FILE"
    sed -i '/^OAUTH_AUTO_REDIRECT=/d' "$ENV_FILE"

    # 精准写入官方标准 Generic 变量组
    cat <<EOF >> "$ENV_FILE"
GENERIC_NAME=${generic_name}
GENERIC_CLIENT_ID=${client_id}
GENERIC_CLIENT_SECRET=${client_secret}
GENERIC_AUTH_URL=${auth_url}
GENERIC_TOKEN_URL=${token_url}
GENERIC_USER_URL=${user_url}
GENERIC_REDIRECT_URL=${computed_redirect}
GENERIC_SCOPE=${scopes}
OAUTH_AUTO_REDIRECT=generic
EOF

    cd "$BASE_DIR" && docker compose up -d
    echo -e "${GREEN}Casdoor (Generic 托管驱动) 联动配置成功，并已开启全局自动重定向！${RESET}"
}

# 13. 独立核心：GitHub & Google 官方原生 OAuth2 快捷登录绑定
configure_big_tech_oauth() {
    if [[ ! -f "$ENV_FILE" ]]; then echo -e "${RED}错误: 请先安装部署 Tinyauth 主程序！${RESET}" ; return; fi
    local tiny_url=$(grep -E '^APP_URL=' "$ENV_FILE" | cut -d'=' -f2-)

    while true; do
        clear
        echo -e "${CYAN}====== GitHub & Google 官方快捷登录配置面板 ======${RESET}"
        echo -e "${GREEN}1. 启用/配置 GitHub 快捷登录${RESET}"
        echo -e "${GREEN}2. 启用/配置 Google 快捷登录${RESET}"
        echo -e "${GREEN}3. 一键注销/禁用大厂快捷登录${RESET}"
        echo -e "${GREEN}0. 返回主菜单${RESET}"
        echo -e "${CYAN}==================================================${RESET}"
        echo -ne "${GREEN}请做出选择: ${RESET}"
        read -r tech_choice
        
        case "$tech_choice" in
            1)
                local github_redirect="${tiny_url}/callback/github"
                echo -e "\n${YELLOW}[GitHub OAuth 配置说明]${RESET}"
                echo -e "请到 GitHub 开发者设置中创建一个全新的 OAuth App："
                echo -e "主页地址填: ${GREEN}${tiny_url}${RESET}"
                echo -e "Authorization callback URL 必须填: ${MAGENTA}${github_redirect}${RESET}\n"
                
                echo -ne "${YELLOW}请输入 GitHub Client ID: ${RESET}"
                read -r gh_id
                echo -ne "${YELLOW}请输入 GitHub Client Secret: ${RESET}"
                read -r gh_secret
                
                if [[ -n "$gh_id" && -n "$gh_secret" ]]; then
                    sed -i '/^PROVIDER_GITHUB_/d' "$ENV_FILE"
                    sed -i '/^GITHUB_/d' "$ENV_FILE" # 双防兼容旧规
                    cat <<EOF >> "$ENV_FILE"
GITHUB_CLIENT_ID=${gh_id}
GITHUB_CLIENT_SECRET=${gh_secret}
GITHUB_REDIRECT_URI=${github_redirect}
EOF
                    cd "$BASE_DIR" && docker compose up -d
                    echo -e "${GREEN}GitHub 快捷登录驱动已成功激活并应用！${RESET}"
                fi
                read -r; break
                ;;
            2)
                local google_redirect="${tiny_url}/callback/google"
                echo -e "\n${YELLOW}[Google OAuth 配置说明]${RESET}"
                echo -e "请前往 Google Cloud Console 凭据中心创建 Web 应用程序 OAuth ID："
                echo -e "已授权的重定向 URI 必须添加: ${MAGENTA}${google_redirect}${RESET}\n"
                
                echo -ne "${YELLOW}请输入 Google Client ID: ${RESET}"
                read -r gg_id
                echo -ne "${YELLOW}请输入 Google Client Secret: ${RESET}"
                read -r gg_secret
                
                if [[ -n "$gg_id" && -n "$gg_secret" ]]; then
                    sed -i '/^PROVIDER_GOOGLE_/d' "$ENV_FILE"
                    sed -i '/^GOOGLE_/d' "$ENV_FILE"
                    cat <<EOF >> "$ENV_FILE"
GOOGLE_CLIENT_ID=${gg_id}
GOOGLE_CLIENT_SECRET=${gg_secret}
GOOGLE_REDIRECT_URI=${google_redirect}
EOF
                    cd "$BASE_DIR" && docker compose up -d
                    echo -e "${GREEN}Google 快捷登录驱动已成功激活并应用！${RESET}"
                fi
                read -r; break
                ;;
            3)
                sed -i '/^PROVIDER_GITHUB_/d' "$ENV_FILE"
                sed -i '/^GITHUB_/d' "$ENV_FILE"
                sed -i '/^PROVIDER_GOOGLE_/d' "$ENV_FILE"
                sed -i '/^GOOGLE_/d' "$ENV_FILE"
                cd "$BASE_DIR" && docker compose up -d
                echo -e "${GREEN}第三方大厂快捷登录配置清理完成！${RESET}"
                read -r; break
                ;;
            0) return ;;
        esac
    done
}

# 9. 独立反向代理管理菜单
nginx_proxy_menu() {
    get_nginx_config_paths
    while true; do
        clear
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}    ◈  Nginx 反向代理管理菜单 ◈  ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}1. 自动配置/覆盖 Tinyauth 自身反代${RESET}"
        echo -e "${GREEN}2. 卸载/删除反向代理配置${RESET}"
        echo -e "${GREEN}3. 检查 Nginx 语法并重载${RESET}"
        echo -e "${0}. 返回主菜单${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -ne "${GREEN}请输入选项: ${RESET}"
        read -r n_choice
        case "$n_choice" in
            1)
                get_status_info
                if [[ "$webui_port" == "N/A" ]]; then echo -e "${RED}错误：请先部署容器！${RESET}"; read -r; continue; fi
                echo -ne "${YELLOW}请输入 Tinyauth 规划域名 (如: faaas.otg.dpdns.org): ${RESET}"
                read -r domain_name
                echo -ne "${YELLOW}请输入 SSL 证书 (.pem/.crt) 绝对路径: ${RESET}"
                read -r ssl_cert_path
                echo -ne "${YELLOW}请输入 SSL 私钥 (.key) 绝对路径: ${RESET}"
                read -r ssl_key_path
                
                if [[ -f "$ENV_FILE" ]]; then
                    sed -i "s|^APP_URL=.*|APP_URL=https://${domain_name}|g" "$ENV_FILE"
                    sed -i "s|^PROVIDERS_POCKETID_REDIRECT_URL=.*|PROVIDERS_POCKETID_REDIRECT_URL=https://${domain_name}/api/oauth/callback/pocketid|g" "$ENV_FILE" 2>/dev/null
                    sed -i "s|^GENERIC_REDIRECT_URL=.*|GENERIC_REDIRECT_URL=https://${domain_name}/callback/generic|g" "$ENV_FILE" 2>/dev/null
                    sed -i "s|^GITHUB_REDIRECT_URI=.*|GITHUB_REDIRECT_URI=https://${domain_name}/callback/github|g" "$ENV_FILE" 2>/dev/null
                    sed -i "s|^GOOGLE_REDIRECT_URI=.*|GOOGLE_REDIRECT_URI=https://${domain_name}/callback/google|g" "$ENV_FILE" 2>/dev/null
                    cd "$BASE_DIR" && docker compose up -d
                fi

                local nginx_conf_file="${NGINX_AVAILABLE_DIR}/${domain_name}"
                [[ "$USE_SITES_STRUCTURE" = false ]] && nginx_conf_file="${nginx_conf_file}.conf"
                
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
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_prefer_server_ciphers off;
    
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    location / {
        proxy_pass http://127.0.0.1:${webui_port};
        proxy_http_version 1.1;
    }
}
EOF
                [[ "$USE_SITES_STRUCTURE" = true ]] && ln -sf "$nginx_conf_file" "${NGINX_ENABLED_DIR}/${domain_name}"
                nginx -t &>/dev/null && systemctl reload nginx && echo -e "${GREEN}反代配置成功！${RESET}"
                read -r; break
                ;;
            2)
                if [[ -f "$ENV_FILE" ]]; then
                    local d_name=$(grep -E '^APP_URL=' "$ENV_FILE" | cut -d'/' -f3)
                    rm -f "/etc/nginx/sites-available/${d_name}" "/etc/nginx/sites-enabled/${d_name}" "/etc/nginx/conf.d/${d_name}.conf"
                    systemctl reload nginx 2>/dev/null
                    echo -e "${GREEN}主服务反代配置已清理。${RESET}"
                fi
                read -r; break
                ;;
            3)
                nginx -t && systemctl reload nginx && echo -e "${GREEN}重载成功！${RESET}"
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
    echo -e "${YELLOW}容器本地监听   : 127.0.0.1:${webui_port}${RESET}"
    [[ -f "$ENV_FILE" ]] && echo -e "${YELLOW}SSO 根域名     : ${CYAN}$(grep -E '^APP_URL=' "$ENV_FILE" | cut -d'=' -f2-)${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Tinyauth 管理面板  ◈     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}127.0.0.1:${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 部署启动 (全新安装)${RESET}"
    echo -e "${GREEN} 2. 更新服务${RESET}"
    echo -e "${GREEN} 3. 卸载服务${RESET}"
    echo -e "${GREEN} 4. 启动服务${RESET}"
    echo -e "${GREEN} 5. 停止服务${RESET}"
    echo -e "${GREEN} 6. 重启服务${RESET}"
    echo -e "${GREEN} 7. 查看日志${RESET}"
    echo -e "${GREEN} 8. 查看配置${RESET}"
    echo -e "${GREEN} 9. 反向代理${RESET}"
    echo -e "${GREEN}10. 联动 Pocket-ID (连接 OAuth2 单点登录)${RESET}"
    echo -e "${GREEN}11. 配置第三方应用前置鉴权守卫 (智能 auth_request 模式)${RESET}"
    echo -e "${GREEN}12. 联动 Casdoor (连接通用 Generic 单点登录)${RESET}"
    echo -e "${GREEN}13. 配置 GitHub & Google 第三方快捷登录${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
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
        11) configure_app_guard ;;
        12) configure_casdoor_oauth ;;
        13) configure_big_tech_oauth ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
