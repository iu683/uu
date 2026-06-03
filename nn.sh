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
# 顶层看板动态数据获取 (适配 OpenRC)
# ------------------------------
get_nginx_status() {
    if ! command -v nginx >/dev/null 2>&1; then
        STATUS="${RED}未安装${RESET}"
    elif rc-service nginx status >/dev/null 2>&1; then
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
    text/html  html htm shtml;
    text/css   css;
    text/xml   xml;
    image/gif  gif;
    image/jpeg jpeg jpg;
    application/javascript js;
    application/atom+xml atom;
    application/rss+xml rss;
}
EOF
    fi
}

create_default_server() {
    DEFAULT_PATH="/etc/nginx/sites-available/default_server_block"
    [ ! -f "$DEFAULT_PATH" ] && cat > "$DEFAULT_PATH" <<EOF
server {
    listen 80 default_server;
    server_name _;
    return 403;
}
EOF
    ln -sf "$DEFAULT_PATH" /etc/nginx/sites-enabled/default_server_block
}

# 核心重构：支持自定义外部端口监听
generate_server_config() {
    DOMAIN=$1
    TARGET=$2
    IS_WS=$3
    MAX_SIZE=$4
    CERT_PATH=$5    
    KEY_PATH=$6       
    LISTEN_PORT=$7  # 新增：外部监听端口参数
    CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"

    MAX_SIZE=${MAX_SIZE:-200M}
    CERT_PATH=${CERT_PATH:-"/etc/letsencrypt/live/$DOMAIN/fullchain.pem"}
    KEY_PATH=${KEY_PATH:-"/etc/letsencrypt/live/$DOMAIN/privkey.pem"}
    LISTEN_PORT=${LISTEN_PORT:-443} # 默认 443 端口

    if [ "$IS_WS" == "y" ]; then
        WS_HEADERS="proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"Upgrade\";"
    else
        WS_HEADERS=""
    fi

    # 动态写入监听配置
    cat > "$CONFIG_PATH" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host:${LISTEN_PORT}\$request_uri;
}

server {
    listen $LISTEN_PORT ssl;
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

check_domain_resolution() {
    DOMAIN=$1
    if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
    VPS_IP=$(curl -s https://ipinfo.io/ip)
    DOMAIN_IP=$(dig +short "$DOMAIN" | tail -n1)
    if [ -z "$DOMAIN_IP" ] || [ "$DOMAIN_IP" != "$VPS_IP" ]; then
        echo -e "${RED}警告: 域名 $DOMAIN 解析为 $DOMAIN_IP, VPS IP 为 $VPS_IP${RESET}"
    else
        echo -e "${GREEN}域名解析正常${RESET}"
    fi
}

install_nginx() {
    if command -v nginx >/dev/null 2>&1 && command -v certbot >/dev/null 2>&1; then
        echo -e "${YELLOW}提示: 检测到系统已安装 Nginx 与 Certbot，自动跳过安装。${RESET}"
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
        echo -e "${YELLOW}重新尝试安装...${RESET}"
        apk add nginx certbot certbot-nginx curl bind-tools || {
            echo -e "${RED}修复后安装仍然失败，请手动检查 Alpine 镜像源！${RESET}"
            pause
            return
        }
    fi

    remove_default_server
    create_default_server
    
    rc-update add nginx default
    rc-service nginx start
    
    echo
    echo -ne "${YELLOW}是否现在配置反向代理并申请证书？(y/n,默认y): ${RESET}"
    read CONFIRM

    CONFIRM=${CONFIRM:-y}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${RED}已取消配置退出${RESET}"
        exit 0
    fi

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

    echo -e "${GREEN}使用邮箱: ${EMAIL}${RESET}"
    echo "$EMAIL" >> "$EMAIL_FILE"
    sort -u "$EMAIL_FILE" -o "$EMAIL_FILE"
    echo -ne "${GREEN}请输入域名(例如:example.com): ${RESET}"; read DOMAIN
    check_domain_resolution "$DOMAIN"
    echo -ne "${GREEN}请输入公网访问端口 (直接回车默认 443): ${RESET}"; read LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-443}
    echo -ne "${GREEN}请输入反代目标(例如:http://127.0.0.1:5788): ${RESET}"; read TARGET
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n，默认 y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}

    echo -ne "${GREEN}请输入最大上传大小 (默认 200M): ${RESET}"
    read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    # 注意：Certbot 申请证书时必须依赖 80 端口，独立申请成功后，反代服务才会应用自定义端口
    certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE" "" "" "$LISTEN_PORT"
    nginx -t && rc-service nginx reload

    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 2 * * * certbot renew --quiet --post-hook 'rc-service nginx reload'") | crontab -
    fi

    echo -e "${GREEN}安装完成！访问: https://$DOMAIN:$LISTEN_PORT${RESET}"
    pause
}

add_config() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    echo -ne "${GREEN}请输入域名(例如:example.com): ${RESET}"
    read DOMAIN
    check_domain_resolution "$DOMAIN"

    echo -ne "${GREEN}请输入公网访问端口 (直接回车默认 443): ${RESET}"
    read LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-443}

    echo -ne "${GREEN}请输入反代目标(例如:http://127.0.0.1:5788): ${RESET}"
    read TARGET

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

    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n，回车默认 y): ${RESET}"
    read IS_WS
    IS_WS=${IS_WS:-y}

    echo -ne "${GREEN}请输入最大上传大小 (默认 200M): ${RESET}"
    read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    if [ -f "/etc/nginx/sites-available/$DOMAIN" ]; then
        echo -e "${YELLOW}配置已存在${RESET}"
        pause
        return
    fi

    certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE" "" "" "$LISTEN_PORT"
    create_default_server
    nginx -t && rc-service nginx reload
    echo -e "${GREEN}添加完成！访问: https://$DOMAIN:$LISTEN_PORT${RESET}"
    pause
}

modify_config() {
    CONFIG_DIR="/etc/nginx/sites-available"
    [ ! -d "$CONFIG_DIR" ] && echo -e "${YELLOW}还没有任何配置文件！${RESET}" && pause && return

    DOMAINS=($(ls "$CONFIG_DIR" | grep -vE 'default|default_server_block' | sort))
    [ ${#DOMAINS[@]} -eq 0 ] && echo -e "${YELLOW}没有域名配置！${RESET}" && pause && return

    echo -e "${GREEN}现有配置的域名/IP:${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo -e "${GREEN}$((i+1))) ${DOMAINS[$i]}${RESET}"
    done

    echo -ne "${GREEN}请输入编号 (0 返回): ${RESET}"
    read choice
    if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}已取消${RESET}"; return
    fi
    if [ "$choice" -eq 0 ]; then return; fi
    if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效选择${RESET}"; pause; return
    fi

    DOMAIN="${DOMAINS[$((choice-1))]}"
    CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"
    
    # 提取旧配置里的自定义端口
    local old_port=$(grep "listen " "$CONFIG_PATH" | grep "ssl" | awk '{print $2}' | tr -d ';')
    old_port=${old_port:-443}

    echo -ne "${GREEN}请输入新公网访问端口 (直接回车保持原样: ${old_port}): ${RESET}"
    read LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-$old_port}

    echo -ne "${GREEN}请输入新反代目标(例如:http://127.0.0.1:5788): ${RESET}"; read TARGET
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n，回车默认 y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}
    echo -ne "${GREEN}请输入最大上传大小 (默认 200M): ${RESET}"
    read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    if grep -q "$CUSTOM_SSL_BASE" "$CONFIG_PATH"; then
        local current_cert=$(grep "ssl_certificate " "$CONFIG_PATH" | awk '{print $2}' | tr -d ';')
        local current_key=$(grep "ssl_certificate_key " "$CONFIG_PATH" | awk '{print $2}' | tr -d ';')
        generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE" "$current_cert" "$current_key" "$LISTEN_PORT"
    else
        echo -ne "${GREEN}是否更新邮箱? (y/n，回车默认 n): ${RESET}"
        read c
        c=${c:-n}
        if [[ "$c" == "y" ]]; then
            DEFAULT_EMAIL=$(generate_random_email)
            echo -ne "${GREEN}请输入新邮箱 (回车默认: ${DEFAULT_EMAIL}): ${RESET}"
            read EMAIL
            EMAIL=${EMAIL:-$DEFAULT_EMAIL}
            if ! validate_email "$EMAIL"; then
                echo -e "${RED}邮箱格式不正确${RESET}"; pause; return
            fi
            certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
        fi
        generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE" "" "" "$LISTEN_PORT"
    fi

    create_default_server
    nginx -t && rc-service nginx reload
    echo -e "${GREEN}修改完成！访问: https://$DOMAIN:$LISTEN_PORT${RESET}"
    pause
}

delete_config() {
    CONFIG_DIR="/etc/nginx/sites-available"
    [ ! -d "$CONFIG_DIR" ] && echo -e "${YELLOW}没有配置文件！${RESET}" && pause && return

    DOMAINS=($(ls "$CONFIG_DIR" | grep -vE 'default|default_server_block' | sort))
    [ ${#DOMAINS[@]} -eq 0 ] && echo -e "${YELLOW}没有域名配置！${RESET}" && pause && return

    echo -e "${GREEN}可删除的域名/IP:${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo -e "${GREEN}$((i+1))) ${DOMAINS[$i]}${RESET}"
    done

    echo -ne "${GREEN}请选择编号 (0 返回): ${RESET}"
    read choice
    if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}已取消${RESET}"; return
    fi
    if [ "$choice" -eq 0 ]; then return; fi
    if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效选择${RESET}"; pause; return
    fi

    DOMAIN="${DOMAINS[$((choice-1))]}"
    CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"

    if grep -q "$CUSTOM_SSL_BASE" "$CONFIG_PATH"; then
        rm -f "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
        echo -ne "${YELLOW}是否同时删除自定义证书源文件？(y/N): ${RESET}"
        read del_cust
        if [[ "$del_cust" =~ ^[Yy]$ ]]; then
            rm -rf "$CUSTOM_SSL_BASE/$DOMAIN"
            echo -e "${GREEN}自定义证书源文件已删除${RESET}"
        fi
    else
        rm -f "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
        echo -ne "${YELLOW}是否同时删除托管的 Certbot 证书 $DOMAIN ? (y/N): ${RESET}"
        read del_cert
        if [[ "$del_cert" =~ ^[Yy]$ ]]; then
            certbot delete --cert-name "$DOMAIN" || true
            echo -e "${GREEN}Certbot 证书已删除${RESET}"
        else
            echo -e "${YELLOW}证书保留${RESET}"
        fi
    fi

    if nginx -t; then
        rc-service nginx reload
        echo -e "${GREEN}站点 $DOMAIN 已完全删除${RESET}"
    else
        echo -e "${RED}Nginx 配置测试失败，请检查！${RESET}"
    fi
    pause
}

test_renew() {
    CONFIG_DIR="/etc/nginx/sites-available"
    [ ! -d "$CONFIG_DIR" ] && echo -e "${YELLOW}没有配置文件${RESET}" && pause && return

    DOMAINS=($(ls "$CONFIG_DIR" | grep -vE 'default|default_server_block' | sort))
    [ ${#DOMAINS[@]} -eq 0 ] && echo -e "${YELLOW}没有域名配置！${RESET}" && pause && return

    local valid_count=0
    for d in "${DOMAINS[@]}"; do
        if ! grep -q "$CUSTOM_SSL_BASE" "/etc/nginx/sites-available/$d"; then
            valid_count=$((valid_count+1))
        fi
    done

    if [ $valid_count -eq 0 ]; then
        echo -e "${YELLOW}当前全部站点均为自定义证书，无需通过 Certbot 续期。${RESET}"
        pause && return
    fi

    echo -e "${GREEN}以下为可执行 Certbot 续期测试的托管站点:${RESET}"
    local idx=1
    local mapped_domains=()
    for d in "${DOMAINS[@]}"; do
        if ! grep -q "$CUSTOM_SSL_BASE" "/etc/nginx/sites-available/$d"; then
            echo -e "${GREEN}${idx}) $d${RESET}"
            mapped_domains+=("$d")
            idx=$((idx+1))
        fi
    done

    echo -ne "${GREEN}选择编号 (0 返回): ${RESET}"
    read choice
    if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ || "$choice" -eq 0 ]]; then return; fi
    if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#mapped_domains[@]} ]; then
        echo -e "${RED}无效选择${RESET}"; pause; return
    fi

    DOMAIN="${mapped_domains[$((choice-1))]}"
    echo -e "${GREEN}正在测试 $DOMAIN 的证书续期...${RESET}"
    certbot renew --dry-run --cert-name "$DOMAIN"
    pause
}

check_cert() {
    echo -e "${GREEN}1) 查看Certbot托管证书${RESET}"
    echo -e "${GREEN}2) 查看自定义证书${RESET}"
    echo -ne "${GREEN}请选择 [1-2]: ${RESET}"
    read c_choice
    if [ "$c_choice" == "1" ]; then
        Bronze_DIR="/etc/letsencrypt/live"
        [ ! -d "$Bronze_DIR" ] && echo -e "${GREEN}没有托管证书${RESET}" && pause && return
        DOMAINS=()
        for DOMAIN in $(ls "$Bronze_DIR"); do
            [ -f "$Bronze_DIR/$DOMAIN/fullchain.pem" ] && DOMAINS+=("$DOMAIN")
        done
        if [ ${#DOMAINS[@]} -eq 0 ]; then echo -e "${GREEN}没有有效托管证书${RESET}"; pause; return; fi
        for i in "${!DOMAINS[@]}"; do echo -e "${GREEN}$((i+1))) ${DOMAINS[$i]}${RESET}"; done
        echo -ne "${GREEN}请选择编号 (0 返回): ${RESET}"; read choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -eq 0 ] || [ "$choice" -gt ${#DOMAINS[@]} ]; then return; fi
        certbot certificates --cert-name "${DOMAINS[$((choice-1))]}"
    elif [ "$c_choice" == "2" ]; then
        if [ -d "$CUSTOM_SSL_BASE" ]; then
            ls -lR "$CUSTOM_SSL_BASE"
        fi
    fi
    pause
}

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
    echo -e "${YELLOW}警告: 此操作将卸载 Nginx 并删除所有相关配置文件和证书！${RESET}"
    read -r -p "你确定要卸载 Nginx 吗？(y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}操作已取消。${RESET}"
        pause
        return 0
    fi

    echo -e "${YELLOW}正在卸载 Nginx (Alpine)...${RESET}"
    rc-service nginx stop || true
    rc-update del nginx default || true
    apk del nginx certbot certbot-nginx || true
    rm -rf /etc/nginx /etc/letsencrypt "$CUSTOM_SSL_BASE" /var/log/nginx
    remove_default_server
    
    crontab -l 2>/dev/null | grep -v "certbot renew" | crontab - 2>/dev/null || true
    
    echo -e "${GREEN}已成功卸载${RESET}"
    pause
}

fix_external_cert_permission() {
    local cert=$1
    local key=$2
    
    if [[ "$cert" == /root/* ]] || [[ "$key" == /root/* ]]; then
        echo -e "${RED}❌ 致命拒绝: 检测到您的证书源文件位于 /root/ 目录下！${RESET}"
        echo -e "${YELLOW}原因分析: /root 目录权限极为严苛(700)，任何非root用户(包括 Nginx 的 nginx 组)均无权穿透。${RESET}"
        echo -e "${YELLOW}         即使这里使用了软链接，Nginx 依然无法越权读取源文件！${RESET}"
        echo -e "${GREEN}💡 权威推荐: 请在 acme.sh 脚本命令中加上安装指令(--install-cert)，将证书自动导出到公共目录（如 /etc/ssl/ 或 /etc/certs/ 文件夹下）再试。${RESET}"
        return 1
    fi

    local cert_dir=$(dirname "$cert")
    chmod +x "$cert_dir" 2>/dev/null || true
    chmod 644 "$cert" "$key" 2>/dev/null || true
    
    if command -v setfacl >/dev/null 2>&1; then
        setfacl -m u:nginx:rx "$cert_dir" 2>/dev/null || true
        setfacl -m u:nginx:r "$cert" "$key" 2>/dev/null || true
    fi
    return 0
}

add_custom_cert_config() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    echo -ne "${GREEN}请输入您的自定义域名或公网IP(例如:example.com): ${RESET}"; read DOMAIN
    [ -z "$DOMAIN" ] && return

    echo -ne "${GREEN}请输入公网访问端口 (直接回车默认 443): ${RESET}"
    read LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-443}

    echo -ne "${GREEN}请输入反代目标(例如：http://127.0.0.1:5788): ${RESET}"; read TARGET
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n, 默认y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}
    echo -ne "${GREEN}请输入最大上传大小 (默认 200M): ${RESET}"; read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    local DIR_PATH="$CUSTOM_SSL_BASE/$DOMAIN"
    mkdir -p "$DIR_PATH"

    echo -e "${YELLOW}---------------------------------------------${RESET}"
    echo -e "${YELLOW}请提供您的自定义 SSL 证书文件绝对路径。${RESET}"
    echo -e "${YELLOW}---------------------------------------------${RESET}"
    
    echo -ne "${GREEN}请输入 证书公钥(fullchain/crt) 文件的路径: ${RESET}"; read USER_CERT
    echo -ne "${GREEN}请输入 证书私钥(privkey/key) 文件的路径: ${RESET}"; read USER_KEY

    local ABS_CERT=$(readlink -f "$USER_CERT" 2>/dev/null || realpath "$USER_CERT" 2>/dev/null || echo "$USER_CERT")
    local ABS_KEY=$(readlink -f "$USER_KEY" 2>/dev/null || realpath "$USER_KEY" 2>/dev/null || echo "$USER_KEY")

    if [ ! -f "$ABS_CERT" ] || [ ! -f "$ABS_KEY" ]; then
        red "错误: 您输入的证书文件路径不存在，请核实后再试！"
        rm -rf "$DIR_PATH"
        pause && return
    fi

    if ! fix_external_cert_permission "$ABS_CERT" "$ABS_KEY"; then
        rm -rf "$DIR_PATH"
        pause && return
    fi

    rm -f "$DIR_PATH/fullchain.pem" "$DIR_PATH/privkey.pem"
    ln -sf "$ABS_CERT" "$DIR_PATH/fullchain.pem"
    ln -sf "$ABS_KEY" "$DIR_PATH/privkey.pem"

    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE" "$DIR_PATH/fullchain.pem" "$DIR_PATH/privkey.pem" "$LISTEN_PORT"
    create_default_server
    
    if nginx -t; then
        rc-service nginx reload
        echo -e "${GREEN}✅ 自定义证书反代站点 https://$DOMAIN:$LISTEN_PORT 添加成功！${RESET}"
    else
        echo -e "${RED}❌ Nginx 配置语法错误，已自动撤销，请检查证书有效性。${RESET}"
        rm -f "/etc/nginx/sites-enabled/$DOMAIN"
        rm -rf "$DIR_PATH"
    fi
    pause
}

# ------------------------------------------------------------
# 优化重构：适配新版 Nginx (HTTP/2 改为标准 http2 on 指令)
# ------------------------------------------------------------
generate_emby_normal_conf() {
    local DOMAIN=$1
    local TARGET=$2
    local CERT_PATH=$3
    local KEY_PATH=$4
    local CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"
    local TARGET_HOST=$(echo $TARGET | awk -F[/:] '{print $4}')

    CERT_PATH=${CERT_PATH:-"/etc/letsencrypt/live/$DOMAIN/fullchain.pem"}
    KEY_PATH=${KEY_PATH:-"/etc/letsencrypt/live/$DOMAIN/privkey.pem"}

    cat > "$CONFIG_PATH" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name $DOMAIN;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;

    client_max_body_size 5000M;

    location / {
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, DELETE, PUT' always;
        add_header 'Access-Control-Allow-Headers' 'X-Emby-Authorization, Content-Type, Authorization, X-Requested-With' always;
        if (\$request_method = 'OPTIONS') { return 204; }

        proxy_pass $TARGET;
        proxy_ssl_server_name on;
        proxy_set_header Host $TARGET_HOST;
        proxy_pass_request_headers on;

        proxy_set_header X-Real-IP "";
        proxy_set_header X-Forwarded-For "";
        proxy_set_header CF-Connecting-IP "";
        proxy_set_header X-Forwarded-Proto https;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;

        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
}
EOF
    ln -sf "$CONFIG_PATH" "/etc/nginx/sites-enabled/$DOMAIN"
}

generate_emby_stream_conf() {
    local DOMAIN=$1
    local T_MAIN=$2
    local T_STREAM=$3
    local CERT_PATH=$4
    local KEY_PATH=$5
    local CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"
    local MAIN_HOST=$(echo $T_MAIN | awk -F[/:] '{print $4}')
    local STREAM_HOST=$(echo $T_STREAM | awk -F[/:] '{print $4}')

    CERT_PATH=${CERT_PATH:-"/etc/letsencrypt/live/$DOMAIN/fullchain.pem"}
    KEY_PATH=${KEY_PATH:-"/etc/letsencrypt/live/$DOMAIN/privkey.pem"}

    cat > "$CONFIG_PATH" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name $DOMAIN;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;

    client_max_body_size 5000M;

    location / {
        proxy_pass $T_MAIN;
        proxy_ssl_server_name on;
        proxy_set_header Host $MAIN_HOST;
        proxy_pass_request_headers on;

        proxy_set_header X-Real-IP "";
        proxy_set_header X-Forwarded-For "";
        proxy_set_header CF-Connecting-IP "";
        proxy_set_header X-Forwarded-Proto https;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;

        proxy_read_timeout 86400;
        proxy_send_timeout 86400;

        proxy_redirect $T_STREAM/ /s1/;
        proxy_redirect $T_STREAM /s1/;
    }

    location /s1/ {
        rewrite ^/s1(/.*)$ \$1 break;
        proxy_pass $T_STREAM;
        proxy_ssl_server_name on;
        proxy_set_header Host $STREAM_HOST;
        proxy_pass_request_headers on;

        proxy_set_header X-Real-IP "";
        proxy_set_header X-Forwarded-For "";
        proxy_set_header CF-Connecting-IP "";
        proxy_set_header X-Forwarded-Proto https;

        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;

        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;

        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
}
EOF
    ln -sf "$CONFIG_PATH" "/etc/nginx/sites-enabled/$DOMAIN"
}

emby_menu() {
    clear
    echo -e "${GREEN}===== Emby 反向代理配置 =====${RESET}"
    echo -e "${GREEN}1.普通反代(Certbot托管)${RESET}"
    echo -e "${GREEN}2.主站+推流路径重定向(Certbot托管)${RESET}"
    echo -e "${GREEN}3.普通反代(自定义证书)${RESET}"
    echo -e "${0}.返回主菜单${RESET}"
    echo -ne "${GREEN}请选择 [0-3]: ${RESET}"
    read emby_choice

    case $emby_choice in
        1)
            echo -ne "${GREEN}请输入您的域名: ${RESET}"; read DOMAIN
            check_domain_resolution "$DOMAIN"
            echo -ne "${GREEN}请输入Emby地址(例如: https://emby.com): ${RESET}"; read TARGET
            EMAIL=$(generate_random_email)
            certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
            generate_emby_normal_conf "$DOMAIN" "$TARGET"
            nginx -t && rc-service nginx reload
            echo -e "${GREEN}========================================${RESET}"
            echo -e "${GREEN}✅ 普通模式配置成功!${RESET}"
            echo -e "${GREEN}🌐 访问地址: https://$DOMAIN${RESET}"
            echo -e "${GREEN}========================================${RESET}"
            pause ;;
        2)
            echo -ne "${GREEN}请输入您的域名: ${RESET}"; read DOMAIN
            check_domain_resolution "$DOMAIN"
            echo -ne "${GREEN}请输入Emby主站地址(例如: https://emby1.com): ${RESET}"; read T_MAIN
            echo -ne "${GREEN}请输入推流后端地址(例如: https://emby2.com): ${RESET}"; read T_STREAM
            EMAIL=$(generate_random_email)
            certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
            generate_emby_stream_conf "$DOMAIN" "$T_MAIN" "$T_STREAM"
            nginx -t && rc-service nginx reload
            echo -e "${GREEN}========================================${RESET}"
            echo -e "${GREEN}✅ 分流重定向模式配置成功!${RESET}"
            echo -e "${GREEN}🌐 主站访问地址: https://$DOMAIN${RESET}"
            echo -e "${GREEN}🚀 推流重定向路径: https://$DOMAIN/s1/${RESET}"
            echo -e "${YELLOW}提示: 所有发往 $T_STREAM 的请求已自动劫持至 /s1/${RESET}"
            echo -e "${GREEN}========================================${RESET}"
            pause ;;
        3)
            echo -ne "${GREEN}请输入您的域名: ${RESET}"; read DOMAIN
            check_domain_resolution "$DOMAIN"
            echo -ne "${GREEN}请输入Emby地址(例如: https://emby.com): ${RESET}"; read TARGET
            local DIR_PATH="$CUSTOM_SSL_BASE/$DOMAIN"
            mkdir -p "$DIR_PATH"
           
            echo -e "${YELLOW}---------------------------------------------${RESET}"
            echo -e "${YELLOW}请提供您的自定义 SSL 证书文件绝对路径。${RESET}"
            echo -e "${YELLOW}---------------------------------------------${RESET}"

            echo -ne "${GREEN}请输入 证书公钥(fullchain/crt) 文件的绝对路径: ${RESET}"; read USER_CERT
            echo -ne "${GREEN}请输入 证书私钥(privkey/key) 文件的绝对路径: ${RESET}"; read USER_KEY

            local ABS_CERT=$(readlink -f "$USER_CERT" 2>/dev/null || realpath "$USER_CERT" 2>/dev/null || echo "$USER_CERT")
            local ABS_KEY=$(readlink -f "$USER_KEY" 2>/dev/null || realpath "$USER_KEY" 2>/dev/null || echo "$USER_KEY")

            if [ ! -f "$ABS_CERT" ] || [ ! -f "$ABS_KEY" ]; then red "文件不存在"; rm -rf "$DIR_PATH"; pause; return; fi
            
            if ! fix_external_cert_permission "$ABS_CERT" "$ABS_KEY"; then rm -rf "$DIR_PATH"; pause; return; fi

            rm -f "$DIR_PATH/fullchain.pem" "$DIR_PATH/privkey.pem"
            ln -sf "$ABS_CERT" "$DIR_PATH/fullchain.pem"
            ln -sf "$ABS_KEY" "$DIR_PATH/privkey.pem"

            generate_emby_normal_conf "$DOMAIN" "$TARGET" "$DIR_PATH/fullchain.pem" "$DIR_PATH/privkey.pem"
            nginx -t && rc-service nginx reload
            echo -e "${GREEN}========================================${RESET}"
            echo -e "${GREEN}✅ 普通模式配置成功!${RESET}"
            echo -e "${GREEN}🌐 访问地址: https://$DOMAIN${RESET}"
            echo -e "${GREEN}========================================${RESET}"
            pause ;;
        0) return ;;
        *) echo -e "${RED}无效输入!${RESET}", sleep 1; emby_menu ;;
    esac
}

update_nginx_software() {
    clear
    echo -e "${YELLOW}========================================${RESET}"
    echo -e "${YELLOW}    ◈ 正在执行 Nginx 软件版本升级 (Alpine) ◈    ${RESET}"
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
    echo -e "${GREEN}  ├─ 备份成功，备份路径: ${BACKUP_DIR}${RESET}"

    echo -e "${GREEN}  ├─ [2/3] 正在从系统源拉取最新 Nginx 软件包...${RESET}"
    apk update
    
    if apk add --upgrade nginx certbot certbot-nginx; then
        echo -e "${GREEN}  ├─ [3/3] 正在验证配置并平滑重载新版本服务...${RESET}"
        if nginx -t >/dev/null 2>&1; then
            rc-service nginx reload
            local NEW_VER=$(nginx -v 2>&1 | awk -F/ '{print $2}')
            echo -e "${GREEN}  └─ 🎉 升级成功！当前版本从 ${YELLOW}${CURRENT_VER}${RESET} 变为 ${GREEN}${NEW_VER}${RESET}"
        else
            echo -e "${RED}❌ Nginx 配置验证失败！旧服务继续维持运行，请检查配置。${RESET}"
        fi
    else
        echo -e "${RED}❌ 从 Alpine 软件源升级失败，请检查网络！${RESET}"
    fi
    pause
}

# ------------------------------
# 主菜单逻辑
# ------------------------------
main_menu() {
    while true; do
        get_nginx_status
        get_nginx_version
        get_site_count
        clear
        echo -e "${GREEN}========================================${RESET}"
        echo -e "${GREEN}       ◈ Nginx 反向代理管理面板 (Alpine) ◈   ${RESET}"
        echo -e "${GREEN}========================================${RESET}"
        echo -e "${GREEN} Nginx 状态: ${STATUS}     |  Nginx 版本: ${YELLOW}${VERSION_SHOW}${RESET}"
        echo -e "${GREEN} 已配站点数: ${YELLOW}${SITE_COUNT}${RESET}"
        echo -e "${GREEN}========================================${RESET}"
        echo -e "${GREEN} 1. 安装 Nginx 和 Certbot环境${RESET}"
        echo -e "${GREEN} 2. 添加 反代站点配置 (Certbot 托管SSL - 可自定义端口)${RESET}"
        echo -e "${GREEN} 3. 添加 反代站点配置 (自定义本地SSL - 可自定义端口)${RESET}"
        echo -e "${GREEN} 4. 修改 现有站点反代目标和端口${RESET}"
        echo -e "${GREEN} 5. 删除 现有反代站点配置${RESET}"
        echo -e "${GREEN} 6. 检查 所有域名证书到期天数${RESET}"
        echo -e "${GREEN} 7. 测试 托管证书手动续期 (Dry-Run)${RESET}"
        echo -e "${GREEN} 8. 查看 现有证书详情路径${RESET}"
        echo -e "${GREEN} 9. 独立面板: Emby 流媒体高级代理配置${RESET}"
        echo -e "${GREEN}10. 平滑升级 Nginx 软件版本${RESET}"
        echo -e "${RED}11. 彻底卸载 Nginx 环境${RESET}"
        echo -e "${GREEN} 0. 退出脚本${RESET}"
        echo -e "${GREEN}========================================${RESET}"
        echo -ne "${GREEN}请输入操作编号 [0-11]: ${RESET}"
        read choice

        case $choice in
            1) install_nginx ;;
            2) add_config ;;
            3) add_custom_cert_config ;;
            4) modify_config ;;
            5) delete_config ;;
            6) check_domains_status ;;
            7) test_renew ;;
            8) check_cert ;;
            9) emby_menu ;;
           10) update_nginx_software ;;
           11) uninstall_nginx ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入，请重新选择！${RESET}"; sleep 1 ;;
        esac
    done
}

# 运行主菜单
main_menu
