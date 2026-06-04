#!/bin/bash
set +e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

red() { echo -e "${RED}$1${RESET}"; }
green() { echo -e "${GREEN}$1${RESET}"; }
yellow() { echo -e "${YELLOW}$1${RESET}"; }

# 默认自定义证书存放归档目录
CUSTOM_SSL_BASE="/etc/nginx/custom_ssl"
mkdir -p "$CUSTOM_SSL_BASE"

# ------------------------------
# 顶层看板动态数据获取
# ------------------------------
get_nginx_status() {
    if ! command -v nginx >/dev/null 2>&1; then
        STATUS="${RED}未安装${RESET}"
    elif pgrep -f "nginx: master" >/dev/null 2>&1; then
        STATUS="${YELLOW}运行中${RESET}"
    else
        STATUS="${RED}已停止${RESET}"
    fi
}

get_nginx_version() {
    if command -v nginx >/dev/null 2>&1; then
        local nginx_out
        nginx_out=$(nginx -v 2>&1)
        
        if [[ $nginx_out =~ /([0-9.]+) ]]; then
            VERSION_SHOW="${BASH_REMATCH[1]}"
        else
            VERSION_SHOW="未知"
        fi
    else
        VERSION_SHOW="无"
    fi
}

get_site_count() {
    CONFIG_DIR="/etc/nginx/sites-available"
    if [ -d "$CONFIG_DIR" ]; then
        SITE_COUNT=$(ls "$CONFIG_DIR" | grep -vE 'default|default_server_block' | wc -l | tr -d ' ')
    else
        SITE_COUNT="0"
    fi
}

# 专门获取本地公网 IPv6 地址
get_ipv6_status() {
    VPS_IPV6=$(curl -s6 https://ipinfo.io/ip || echo "")
    if [ -n "$VPS_IPV6" ]; then
        IPV6_STATUS="${GREEN}${VPS_IPV6}${RESET}"
    else
        IPV6_STATUS="${RED}未检测到公网 IPv6 (请检查本地网络)${RESET}"
    fi
}

# 强力重启 Nginx
restart_nginx() {
    echo -e "${GREEN}正在验证 Nginx 配置语法...${RESET}"
    
    if nginx -t; then
        echo -e "${GREEN}语法验证通过，正在执行标准安全重启...${RESET}"
        
        rc-service nginx stop >/dev/null 2>&1 || true
        killall -9 nginx >/dev/null 2>&1 || true
        rc-service nginx zap >/dev/null 2>&1 || true
        
        if rc-service nginx start; then
            echo -e "${GREEN}✅ Nginx 服务已通过 OpenRC 成功拉起，开机自启已就绪！${RESET}"
            return 0
        else
            echo -e "${RED}❌ 致命错误：通过 OpenRC 启动 Nginx 失败，尝试裸流降级启动...${RESET}"
            if nginx; then
                echo -e "${YELLOW}⚠️ 警告：已通过裸二进制应急启动。${RESET}"
                return 0
            else
                echo -e "${RED}❌ 彻底失败：Nginx 二进制文件无法运行！${RESET}"
                return 1
            fi
        fi
    else
        echo -e "${RED}❌ Nginx 配置语法错误！未执行重启，请检查上方的错误提示。${RESET}"
        return 1
    fi
}

# 优雅重载 Nginx 配置 (无缝热重载)
reload_nginx() {
    echo -e "${GREEN}正在验证 Nginx 配置语法...${RESET}"
    if nginx -t; then
        echo -e "${GREEN}语法验证通过，正在热重载配置 (Reload)...${RESET}"
        if command -v rc-service >/dev/null 2>&1 && rc-service nginx status >/dev/null 2>&1; then
            rc-service nginx reload
        else
            nginx -s reload
        fi
        echo -e "${GREEN}✅ Nginx 配置重载成功！${RESET}"
    else
        echo -e "${RED}❌ Nginx 配置语法错误！放弃重载，请检查上方错误信息。${RESET}"
    fi
    pause
}

# 升级 Nginx 软件及相关组件
update_nginx_software() {
    clear
    echo -e "${YELLOW}========================================${RESET}"
    echo -e "${YELLOW}    ◈ 正在执行 Nginx 软件版本升级 ◈    ${RESET}"
    echo -e "${YELLOW}========================================${RESET}"

    if ! command -v nginx >/dev/null 2>&1; then
        echo -e "${RED}❌ 系统未安装 Nginx，无法更新。请先使用主菜单选项安装。${RESET}"
        pause && return
    fi
    local CURRENT_VER=$(nginx -v 2>&1 | awk -F/ '{print $2}')
    echo -e "${GREEN}◈ 当前 Nginx 版本: ${RESET}${YELLOW}${CURRENT_VER}${RESET}"
    echo -e "${YELLOW}----------------------------------------${RESET}"

    echo -ne "${YELLOW}是否开始检查更新并平滑升级？(y/N,默认N): ${RESET}"
    read up_choice
    if [[ ! "$up_choice" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}⏭ 已取消升级。${RESET}"
        pause && return
    fi

    echo -e "${GREEN}  ├─ [1/3] 正在安全备份现有的反代配置与证书...${RESET}"
    local BACKUP_DIR="/etc/nginxbackup/nginx_backup_$(date +%Y%m%d%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    [ -d "/etc/nginx/sites-available" ] && cp -r /etc/nginx/sites-available "$BACKUP_DIR/" || true
    [ -d "$CUSTOM_SSL_BASE" ] && cp -r "$CUSTOM_SSL_BASE" "$BACKUP_DIR/" || true
    [ -f "/etc/nginx/nginx.conf" ] && cp "/etc/nginx/nginx.conf" "$BACKUP_DIR/" || true
    echo -e "${GREEN}  ├─ 备份成功，备份路径: ${BACKUP_DIR}${RESET}"

    echo -e "${GREEN}  ├─ [2/3] 正在从系统源拉取最新 Nginx 软件包...${RESET}"
    apk update
    
    if apk add --upgrade nginx certbot certbot-nginx; then
        echo -e "${GREEN}  ├─ [3/3] 正在验证配置并平滑重载新版本服务...${RESET}"
        if nginx -t >/dev/null 2>&1; then
            nginx -t && nginx -s reload
            local NEW_VER=$(nginx -v 2>&1 | awk -F/ '{print $2}')
            echo -e "${GREEN}  └─ 🎉 升级成功！当前版本从 ${YELLOW}${CURRENT_VER}${RESET} 变为 ${GREEN}${NEW_VER}${RESET}"
        else
            echo -e "${RED}❌ Nginx 配置验证失败！旧服务继续维持运行，请检查配置。${RESET}"
        fi
    else
        echo -e "${RED}❌ 从 Alpine 软件源升级失败，请检查 network！${RESET}"
    fi
    pause
}

# ------------------------------
# 核心功能函数
# ------------------------------
generate_random_email() {
    RAND_STR=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
    echo "${RAND_STR}@gmail.com"
}

validate_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

pause() {
    echo -ne "${YELLOW}按回车返回菜单...${RESET}"
    read
}

configure_firewall() {
    local PORT=$1
    if [ -n "$PORT" ]; then
        if command -v ufw >/dev/null 2>&1; then
            ufw allow $PORT/tcp || true
        elif command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port=$PORT/tcp || true
            firewall-cmd --reload || true
        fi
    fi
}

remove_default_server() {
    echo -e "${YELLOW}清理系统自带的 default server 配置...${RESET}"
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-available/default
    rm -f /etc/nginx/http.d/default.conf 2>/dev/null || true 
}

ensure_nginx_conf() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    if [ ! -f /etc/nginx/nginx.conf ]; then
        cat > /etc/nginx/nginx.conf <<'EOF'
user nginx;
worker_processes auto;
pcre_jit on;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    gzip on;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    fi

    if [ ! -f /etc/nginx/mime.types ]; then
        cat > /etc/nginx/mime.types <<'EOF'
types {
    text/html   html htm shtml;
    text/css    css;
    text/xml    xml;
    image/gif   gif;
    image/jpeg  jpeg jpg;
    application/javascript js;
    application/atom+xml atom;
    application/rss+xml rss;
}
EOF
    fi
}

# 默认空配置拦截：仅监听并阻断 IPv6 恶意直连
create_default_server() {
    DEFAULT_PATH="/etc/nginx/sites-available/default_server_block"
    [ ! -f "$DEFAULT_PATH" ] && cat > "$DEFAULT_PATH" <<EOF
server {
    listen [::]:80 default_server ipv6only=on;
    server_name _;
    return 403;
}
EOF
    ln -sf "$DEFAULT_PATH" /etc/nginx/sites-enabled/default_server_block
}

# 生成专门的纯 IPv6 站点反代配置
generate_server_config() {
    DOMAIN=$1
    TARGET=$2
    IS_WS=$3
    MAX_SIZE=$4
    CERT_PATH=$5    
    KEY_PATH=$6       
    LISTEN_PORT=$7  
    CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"

    MAX_SIZE=${MAX_SIZE:-200M}
    CERT_PATH=${CERT_PATH:-"/etc/letsencrypt/live/$DOMAIN/fullchain.pem"}
    KEY_PATH=${KEY_PATH:-"/etc/letsencrypt/live/$DOMAIN/privkey.pem"}
    LISTEN_PORT=${LISTEN_PORT:-443} 

    if [ "$IS_WS" == "y" ]; then
        WS_HEADERS="proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"Upgrade\";"
    else
        WS_HEADERS=""
    fi

    cat > "$CONFIG_PATH" <<EOF
server {
    listen [::]:80 ipv6only=on;
    server_name $DOMAIN;
    return 301 https://\$host:${LISTEN_PORT}\$request_uri;
}

server {
    listen [::]:$LISTEN_PORT ssl ipv6only=on;
    server_name $DOMAIN;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;

    location / {
        client_max_body_size $MAX_SIZE;

        proxy_pass $TARGET;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        $WS_HEADERS
    }
}
EOF
    ln -sf "$CONFIG_PATH" "/etc/nginx/sites-enabled/$DOMAIN"
    configure_firewall "$LISTEN_PORT"
    if [ "$LISTEN_PORT" != "443" ]; then
        configure_firewall "443"
    fi
    configure_firewall "80"
}

# 专门校验域名的 IPv6 (AAAA记录) 解析
check_domain_resolution() {
    DOMAIN=$1
    if [[ "$DOMAIN" =~ ^\[.*\]$ ]] || [[ "$DOMAIN" =~ : ]]; then
        return 0
    fi

    VPS_IPV6=$(curl -s6 https://ipinfo.io/ip || echo "")
    DOMAIN_IPV6=$(dig +short AAAA "$DOMAIN" | tail -n1)

    if [ -z "$DOMAIN_IPV6" ]; then
        echo -e "${RED}警告: 域名 $DOMAIN 未检测到任何 IPv6 (AAAA) 解析记录！${RESET}"
    elif [ "$DOMAIN_IPV6" != "$VPS_IPV6" ]; then
        echo -e "${RED}警告: 域名解析的 IPv6 ($DOMAIN_IPV6) 与本机公网 IPv6 ($VPS_IPV6) 不一致！${RESET}"
    else
        echo -e "${GREEN}域名 IPv6 解析匹配成功 ($DOMAIN_IPV6)${RESET}"
    fi
}

install_nginx() {
    if command -v nginx >/dev/null 2>&1 && command -v certbot >/dev/null 2>&1; then
        echo -e "${YELLOW}提示: 系统已存在 Nginx 与 Certbot，跳过安装。${RESET}"
        pause
        return
    fi
    
    ensure_nginx_conf
    remove_default_server

    echo -e "${GREEN}开始安装依赖和 Nginx 组件 (Alpine APK)...${RESET}"
    apk update
    if ! apk add nginx certbot certbot-nginx curl bind-tools; then
        echo -e "${RED}安装失败，尝试自动修复...${RESET}"
        uninstall_nginx
        apk add nginx certbot certbot-nginx curl bind-tools || {
            echo -e "${RED}安装失败，请手动检查 Alpine 镜像源！${RESET}"
            pause
            return
        }
    fi

    remove_default_server
    create_default_server
    
    rc-update add nginx default
    restart_nginx

    echo
    echo -ne "${YELLOW}是否现在配置反向代理并申请证书？(y/n,默认y): ${RESET}"
    read CONFIRM

    CONFIRM=${CONFIRM:-y}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${RED}已取消配置退出${RESET}"
        exit 0
    fi

    killall nginx >/dev/null 2>&1      
    rc-service nginx zap >/dev/null 2>&1 

    EMAIL_FILE="/etc/nginx/.cert_emails"
    if [ -f "$EMAIL_FILE" ] && [ -s "$EMAIL_FILE" ]; then
        DEFAULT_EMAIL=$(head -n1 "$EMAIL_FILE")
    else
        DEFAULT_EMAIL=$(generate_random_email)
    fi

    echo -ne "${GREEN}请输入邮箱地址 (回车自动生成: ${DEFAULT_EMAIL}): ${RESET}"
    read EMAIL
    EMAIL=${EMAIL:-$DEFAULT_EMAIL}

    if ! validate_email "$EMAIL"; then
        echo -e "${RED}邮箱格式不正确${RESET}"
        pause
        return
    fi

    echo "$EMAIL" >> "$EMAIL_FILE"
    sort -u "$EMAIL_FILE" -o "$EMAIL_FILE"
    echo -ne "${GREEN}请输入域名(例如:v6.example.com): "
    read DOMAIN
    check_domain_resolution "$DOMAIN"
    echo -ne "${GREEN}请输入公网访问端口 (直接回车默认 443): ${RESET}"
    read LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-443}
    echo -ne "${GREEN}请输入反代目标(例如: http://[::1]:5788): ${RESET}"
    read TARGET
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n，默认 y): ${RESET}"
    read IS_WS
    IS_WS=${IS_WS:-y}

    echo -ne "${GREEN}请输入最大上传大小 (默认 200M): ${RESET}"
    read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    echo -e "${GREEN}正在通过 --nginx 模式向 Let's Encrypt 申请证书...${RESET}"
    
    certbot certonly --nginx \
        --nginx-server-root /etc/nginx \
        --nginx-ctl /usr/sbin/nginx \
        -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"

    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        echo -e "${GREEN}✅ 证书申请成功！正在生成业务配置文件...${RESET}"
        
        generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE" "" "" "$LISTEN_PORT"

        killall nginx >/dev/null 2>&1      
        rc-service nginx zap >/dev/null 2>&1  
 
        echo -e "${GREEN}正在启动 Nginx 服务...${RESET}"
        restart_nginx
        
        if nginx -t; then
            nginx -s reload
            echo -e "${GREEN}安装完成！配置已生效。${RESET}"
            echo -e "${GREEN}访问地址: https://[$DOMAIN]:$LISTEN_PORT${RESET}"
        else
            echo -e "${RED}❌ 错误: Nginx 配置测试失败，执行安全回滚！${RESET}"
            rm -f "/etc/nginx/sites-enabled/$DOMAIN" 2>/dev/null
            nginx -s reload
        fi
    else
        echo -e "${RED}❌ 错误: Certbot 证书申请失败！请确保您的域名已成功解析 AAAA 记录到本机的 IPv6 地址。${RESET}"
    fi

    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 2 * * * certbot renew --quiet --post-hook 'rc-service nginx reload'") | crontab -
    fi

    pause
}

add_config() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    echo -ne "${GREEN}请输入域名(例如:v6.example.com): ${RESET}"; read DOMAIN
    check_domain_resolution "$DOMAIN"
    echo -ne "${GREEN}请输入公网访问端口 (默认 443): ${RESET}"; read LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-443}
    echo -ne "${GREEN}请输入反代目标(例如: http://[::1]:5788): ${RESET}"; read TARGET

    EMAIL_FILE="/etc/nginx/.cert_emails"
    DEFAULT_EMAIL=$(head -n1 "$EMAIL_FILE" 2>/dev/null || generate_random_email)
    echo -ne "${GREEN}请输入邮箱地址 (默认: ${DEFAULT_EMAIL}): ${RESET}"; read EMAIL
    EMAIL=${EMAIL:-$DEFAULT_EMAIL}

    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n, 默认y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}
    echo -ne "${GREEN}最大上传大小 (默认 200M): ${RESET}"; read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE" "" "" "$LISTEN_PORT"
    create_default_server
    nginx -t && nginx -s reload
    echo -e "${GREEN}添加完成！访问: https://$DOMAIN:$LISTEN_PORT${RESET}"
    pause
}

modify_config() {
    CONFIG_DIR="/etc/nginx/sites-available"
    [ ! -d "$CONFIG_DIR" ] && echo -e "${YELLOW}没有配置文件！${RESET}" && pause && return
    DOMAINS=($(ls "$CONFIG_DIR" | grep -vE 'default|default_server_block' | sort))
    [ ${#DOMAINS[@]} -eq 0 ] && echo -e "${YELLOW}没有域名配置！${RESET}" && pause && return

    echo -e "${GREEN}现有配置的域名/IP:${RESET}"
    for i in "${!DOMAINS[@]}"; do echo -e "${GREEN}$((i+1))) ${DOMAINS[$i]}${RESET}"; done
    echo -ne "${GREEN}请输入编号 (0 返回): ${RESET}"; read choice
    if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ || "$choice" -eq 0 ]]; then return; fi

    DOMAIN="${DOMAINS[$((choice-1))]}"
    CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"
    local old_port=$(grep "listen " "$CONFIG_PATH" | grep "ssl" | awk '{print $2}' | tr -d ';')

    echo -ne "${GREEN}新访问端口 (默认: ${old_port}): ${RESET}"; read LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-$old_port}
    echo -ne "${GREEN}新反代目标(例如: http://[::1]:5788): ${RESET}"; read TARGET
    echo -ne "${GREEN}WebSocket? (y/n, 默认y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}
    echo -ne "${GREEN}最大上传大小 (默认 200M): ${RESET}"; read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    if grep -q "$CUSTOM_SSL_BASE" "$CONFIG_PATH"; then
        local current_cert=$(grep "ssl_certificate " "$CONFIG_PATH" | awk '{print $2}' | tr -d ';')
        local current_key=$(grep "ssl_certificate_key " "$CONFIG_PATH" | awk '{print $2}' | tr -d ';')
        generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE" "$current_cert" "$current_key" "$LISTEN_PORT"
    else
        generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE" "" "" "$LISTEN_PORT"
    fi
    nginx -t && nginx -s reload
    pause
}

delete_config() {
    CONFIG_DIR="/etc/nginx/sites-available"
    DOMAINS=($(ls "$CONFIG_DIR" | grep -vE 'default|default_server_block' | sort 2>/dev/null))
    [ ${#DOMAINS[@]} -eq 0 ] && echo -e "${YELLOW}没有站点配置！${RESET}" && pause && return

    for i in "${!DOMAINS[@]}"; do echo -e "${GREEN}$((i+1))) ${DOMAINS[$i]}${RESET}"; done
    echo -ne "${GREEN}请选择删除编号 (0 返回): ${RESET}"; read choice
    if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ || "$choice" -eq 0 ]]; then return; fi

    DOMAIN="${DOMAINS[$((choice-1))]}"
    rm -f "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
    certbot delete --cert-name "$DOMAIN" || true
    nginx -t && nginx -s reload
    pause
}

test_renew() {
    certbot renew --dry-run
    pause
}

check_cert() {
    certbot certificates
    pause
}

# 升级版：域名证书状态实时监控
check_domains_status() {
    clear
    echo -e "${YELLOW}========================================${RESET}"
    echo -e "${YELLOW}        ◈ 域名证书状态实时监控 ◈          ${RESET}"
    echo -e "${YELLOW}========================================${RESET}"

    CONFIG_DIR="/etc/nginx/sites-available"
    local has_site=0

    if [ -d "$CONFIG_DIR" ]; then
        for DOMAIN in $(ls "$CONFIG_DIR" | grep -vE 'default|default_server_block' | sort); do
            CONFIG_PATH="$CONFIG_DIR/$DOMAIN"
            CERT_PATH=$(grep "ssl_certificate " "$CONFIG_PATH" | awk '{print $2}' | tr -d ';')
            
            if [ -f "$CERT_PATH" ]; then
                has_site=1
                TYPE="托管 (Certbot)"
                [[ "$CERT_PATH" =~ "$CUSTOM_SSL_BASE" ]] && TYPE="自定义证书"

                END_DATE=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
                END_TS=$(date -d "$END_DATE" +%s)
                NOW_TS=$(date +%s)
                DAYS_LEFT=$(( (END_TS - NOW_TS) / 86400 ))

                if [ $DAYS_LEFT -ge 30 ]; then
                    STATUS_COLOR="${GREEN}"
                    STATUS_TEXT="正常有效"
                elif [ $DAYS_LEFT -ge 0 ]; then
                    STATUS_COLOR="${YELLOW}"
                    STATUS_TEXT="即将过期 (请注意)"
                else
                    STATUS_COLOR="${RED}"
                    STATUS_TEXT="已过期 (请立即更新)"
                fi

                echo -e "${YELLOW}◈ 域名: ${RESET}${YELLOW}${DOMAIN}${RESET}"
                echo -e "  ├─ ${YELLOW}证书类型: ${RESET}${TYPE}"
                echo -e "  ├─ ${YELLOW}到期时间: ${RESET}$(date -d "$END_DATE" +"%Y-%m-%d")"
                echo -e "  ├─ ${YELLOW}剩余天数: ${RESET}${STATUS_COLOR}${DAYS_LEFT} 天${RESET}"
                echo -e "  └─ ${YELLOW}运行状态: ${RESET}${STATUS_COLOR}${STATUS_TEXT}${RESET}"
                echo -e "${YELLOW}----------------------------------------${RESET}"
            fi
        done
    fi

    if [ $has_site -eq 0 ]; then
        echo -e "${RED} ❌ 当前系统未检测到任何反代站点配置。${RESET}"
        echo -e "${YELLOW}----------------------------------------${RESET}"
    fi
    pause
}

uninstall_nginx() {

    echo -ne "${RED}确定要完全卸载 Nginx 及所有站点证书吗？(y/N, 默认N): ${RESET}"
    read un_choice
    if [[ ! "$un_choice" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}⏭ 已取消卸载，未做任何变更。${RESET}"
        pause && return
    fi

    echo -e "${RED}正在完全卸载 Nginx ...${RESET}"
    rc-service nginx stop >/dev/null 2>&1 || true
    apk del nginx certbot certbot-nginx 2>/dev/null || true
    rm -rf /etc/nginx /etc/letsencrypt "$CUSTOM_SSL_BASE"
    echo -e "${GREEN}卸载完成。${RESET}"
    pause
}

add_custom_cert_config() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    echo -ne "${GREEN}请输入您的自定义域名(例如:v6.example.com): ${RESET}"; read DOMAIN
    echo -ne "${GREEN}访问端口 (默认 443): ${RESET}"; read LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-443}
    echo -ne "${GREEN}反代目标(例如: http://[::1]:5788): ${RESET}"; read TARGET
    echo -ne "${GREEN}WebSocket? (y/n, 默认y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}
    echo -ne "${GREEN}最大上传 (默认 200M): ${RESET}"; read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    local DIR_PATH="$CUSTOM_SSL_BASE/$DOMAIN"
    mkdir -p "$DIR_PATH"
    echo -ne "${GREEN}请输入公钥文件 (fullchain.pem/crt) 的路径: ${RESET}"; read USER_CERT
    echo -ne "${GREEN}请输入密钥文件 (privkey.pem/key) 的路径: ${RESET}"; read USER_KEY

    if [ -f "$USER_CERT" ] && [ -f "$USER_KEY" ]; then
        ln -sf "$USER_CERT" "$DIR_PATH/fullchain.pem"
        ln -sf "$USER_KEY" "$DIR_PATH/privkey.pem"
        generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE" "$DIR_PATH/fullchain.pem" "$DIR_PATH/privkey.pem" "$LISTEN_PORT"
        nginx -t && nginx -s reload
        echo -e "${GREEN}✅ 配置成功！🌐 访问地址: https://$DOMAIN:$LISTEN_PORT${RESET}"
    else
        red "路径错误或文件不存在！"
    fi
    pause
}

generate_emby_normal_conf() {
    local DOMAIN=$1, TARGET=$2, CERT_PATH=$3, KEY_PATH=$4, LISTEN_PORT=$5
    local CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"
    local TARGET_HOST=$(echo "$TARGET" | awk -F[/:] '{print $4}' | tr -d '[]')

    CERT_PATH=${CERT_PATH:-"/etc/letsencrypt/live/$DOMAIN/fullchain.pem"}
    KEY_PATH=${KEY_PATH:-"/etc/letsencrypt/live/$DOMAIN/privkey.pem"}

    cat > "$CONFIG_PATH" <<EOF
server {
    listen [::]:$LISTEN_PORT ssl ipv6only=on;
    http2 on;
    server_name $DOMAIN;
    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    client_max_body_size 5000M;

    location / {
        proxy_pass $TARGET;
        proxy_ssl_server_name on;
        proxy_set_header Host "$TARGET_HOST";
        proxy_pass_request_headers on;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
EOF
    ln -sf "$CONFIG_PATH" "/etc/nginx/sites-enabled/$DOMAIN"
}

emby_menu() {
    clear
    echo -e "${GREEN}===== Emby 纯 IPv6 反向代理 =====${RESET}"
    echo -ne "${GREEN}请输入您的域名(例如:v6.example.com): ${RESET}"; read DOMAIN
    echo -ne "${GREEN}访问端口 (默认 443): ${RESET}"; read LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-443}
    echo -ne "${GREEN}请输入Emby内网地址 (例如: http://[::1]:8096): ${RESET}"; read TARGET
    
    EMAIL=$(generate_random_email)
    certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    generate_emby_normal_conf "$DOMAIN" "$TARGET" "" "" "$LISTEN_PORT"
    nginx -t && nginx -s reload
    echo -e "${GREEN}✅ Emby 反代配置成功！🌐 访问地址: https://$DOMAIN:$LISTEN_PORT${RESET}"
    pause
}

# ------------------------------
# 主循环控制看板菜单
# ------------------------------
while true; do
    get_nginx_status
    get_nginx_version
    get_site_count

    clear
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}     ◈ Nginx 反向代理管理面板 ◈     ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN} 状态 :${RESET}  $STATUS "
    echo -e "${GREEN} 版本 :${RESET}  ${YELLOW}${VERSION_SHOW}${RESET}"
    echo -e "${GREEN} 站点 :${RESET}  ${YELLOW}${SITE_COUNT} 个${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN} 1. 安装 Nginx${RESET}"
    echo -e "${GREEN} 2. 添加配置 (Certbot托管)${RESET}"
    echo -e "${GREEN} 3. 添加配置 (自定义证书)${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 删除配置${RESET}"
    echo -e "${GREEN} 6. 测试证书续期${RESET}"
    echo -e "${GREEN} 7. 查看证书信息${RESET}"
    echo -e "${GREEN} 8. 查看证书状态${RESET}"
    echo -e "${GREEN} 9. Emby反代配置${RESET}"
    echo -e "${GREEN}10. 重载Nginx${RESET}"
    echo -e "${GREEN}11. 更新Nginx${RESET}"
    echo -e "${GREEN}12. 卸载Nginx${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -ne " 请选择 : "
    read choice

    case $choice in
        1) install_nginx ;;
        2) add_config ;;
        3) add_custom_cert_config ;;
        4) modify_config ;;
        5) delete_config ;;
        6) test_renew ;;
        7) check_cert ;;
        8) check_domains_status ;;
        9) emby_menu ;;
        10) reload_nginx ;;
        11) update_nginx_software ;;
        12) uninstall_nginx ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入有误！${RESET}"; sleep 1 ;;
    esac
done
