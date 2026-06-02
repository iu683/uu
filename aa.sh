#!/bin/bash
set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 默认自定义证书存放归档目录
CUSTOM_SSL_BASE="/etc/nginx/custom_ssl"
mkdir -p "$CUSTOM_SSL_BASE"

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
    for PORT in 80 443; do
        if command -v ufw >/dev/null 2>&1; then
            ufw allow $PORT || true
        elif command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port=$PORT/tcp || true
            firewall-cmd --reload || true
        fi
    done
}

remove_default_server() {
    echo -e "${YELLOW}清理系统自带的 default server 配置...${RESET}"
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-available/default
}

ensure_nginx_conf() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/modules-enabled
    if [ ! -f /etc/nginx/nginx.conf ]; then
        cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
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

# 核心增强：支持指定证书路径
generate_server_config() {
    DOMAIN=$1
    TARGET=$2
    IS_WS=$3
    MAX_SIZE=$4
    CERT_PATH=$5    
    KEY_PATH=$6       
    CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"

    MAX_SIZE=${MAX_SIZE:-200M}

    # 如果没传入证书路径，默认回退到 Certbot 官方路径
    CERT_PATH=${CERT_PATH:-"/etc/letsencrypt/live/$DOMAIN/fullchain.pem"}
    KEY_PATH=${KEY_PATH:-"/etc/letsencrypt/live/$DOMAIN/privkey.pem"}

    if [ "$IS_WS" == "y" ]; then
        WS_HEADERS="proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"Upgrade\";"
    else
        WS_HEADERS=""
    fi

    cat > "$CONFIG_PATH" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
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
}

check_domain_resolution() {
    DOMAIN=$1
    # 兼容IP证书，如果输入本身就是IP，跳过解析检查
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

# ------------------------------
# 功能函数
# ------------------------------

install_nginx() {
    ensure_nginx_conf
    remove_default_server

    DEBIAN_FRONTEND=noninteractive apt update
    DEBIAN_FRONTEND=noninteractive apt upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    DEBIAN_FRONTEND=noninteractive apt install -y curl dnsutils \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    echo -e "${GREEN}开始安装 Nginx 和 Certbot...${RESET}"
    if ! DEBIAN_FRONTEND=noninteractive apt install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        nginx certbot python3-certbot-nginx; then
        echo -e "${RED}安装失败，尝试自动修复...${RESET}"
        uninstall_nginx
        echo -e "${YELLOW}重新尝试安装...${RESET}"
        DEBIAN_FRONTEND=noninteractive apt install -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            nginx certbot python3-certbot-nginx || {
            echo -e "${RED}修复后安装仍然失败，请手动检查系统环境！${RESET}"
            pause
            return
        }
    fi

    remove_default_server
    create_default_server
    configure_firewall
    systemctl daemon-reload
    systemctl enable --now nginx
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
    echo -ne "${GREEN}请输入域名: ${RESET}"; read DOMAIN
    check_domain_resolution "$DOMAIN"
    echo -ne "${GREEN}请输入反代目标(例如:http://127.0.0.1:5788): ${RESET}"; read TARGET
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n，默认 y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}

    echo -ne "${GREEN}请输入最大上传大小 (默认 200M): ${RESET}"
    read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE"
    nginx -t && systemctl reload nginx
    systemctl enable --now certbot.timer
    echo -e "${GREEN}安装完成！访问: https://$DOMAIN${RESET}"
    pause
}

add_config() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    echo -ne "${GREEN}请输入域名/IP: ${RESET}"
    read DOMAIN
    check_domain_resolution "$DOMAIN"

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
    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE"
    create_default_server
    nginx -t && systemctl reload nginx
    echo -e "${GREEN}添加完成！访问: https://$DOMAIN${RESET}"
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
    echo -ne "${GREEN}请输入新反代目标(例如:http://127.0.0.1:5788): ${RESET}"; read TARGET
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n，回车默认 y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}
    echo -ne "${GREEN}请输入最大上传大小 (默认 200M): ${RESET}"
    read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    # 允许修改自定义证书站点的配置而不触碰 Certbot
    if grep -q "$CUSTOM_SSL_BASE" "$CONFIG_PATH"; then
        # 如果是自定义证书站点，保留其原有的证书路径定义
        local current_cert=$(grep "ssl_certificate " "$CONFIG_PATH" | awk '{print $2}' | tr -d ';')
        local current_key=$(grep "ssl_certificate_key " "$CONFIG_PATH" | awk '{print $2}' | tr -d ';')
        generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE" "$current_cert" "$current_key"
    else
        # 否则依然按 Certbot 流程走
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
        generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE"
    fi

    create_default_server
    nginx -t && systemctl reload nginx
    echo -e "${GREEN}修改完成！访问: https://$DOMAIN${RESET}"
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
        # 自定义证书站点清理
        rm -f "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
        echo -ne "${YELLOW}是否同时删除本地自定义证书源文件？(y/N): ${RESET}"
        read del_cust
        if [[ "$del_cust" =~ ^[Yy]$ ]]; then
            rm -rf "$CUSTOM_SSL_BASE/$DOMAIN"
            echo -e "${GREEN}自定义证书源文件已删除${RESET}"
        fi
    else
        # Certbot 站点清理
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
        systemctl reload nginx
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

    # 过滤掉自定义证书站点，自定义证书不参与 Certbot 续期测试
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
    # 合并查看托管证书与自定义证书
    echo -e "${GREEN}1) 查看托管证书${RESET}"
    echo -e "${GREEN}2) 查看自定义证${RESET}"
    echo -ne "${GREEN}请选择 [1-2]: ${RESET}"
    read c_choice
    if [ "$c_choice" == "1" ]; then
        CERT_DIR="/etc/letsencrypt/live"
        [ ! -d "$CERT_DIR" ] && echo -e "${GREEN}没有托管证书${RESET}" && pause && return
        DOMAINS=()
        for DOMAIN in $(ls "$CERT_DIR"); do
            [ -f "$CERT_DIR/$DOMAIN/fullchain.pem" ] && DOMAINS+=("$DOMAIN")
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
    # 修复了表格头部输出的格式化问题
    printf "${GREEN}%-25s %-10s %-15s %-10s${RESET}\n" "域名/IP" "类型" "到期时间" "剩余天数"
    echo -e "${GREEN}------------------------------------------------------------${RESET}"

    CONFIG_DIR="/etc/nginx/sites-available"
    if [ -d "$CONFIG_DIR" ]; then
        for DOMAIN in $(ls "$CONFIG_DIR" | grep -vE 'default|default_server_block' | sort); do
            CONFIG_PATH="$CONFIG_DIR/$DOMAIN"
            CERT_PATH=$(grep "ssl_certificate " "$CONFIG_PATH" | awk '{print $2}' | tr -d ';')
            
            if [ -f "$CERT_PATH" ]; then
                TYPE="托管"
                [[ "$CERT_PATH" =~ "$CUSTOM_SSL_BASE" ]] && TYPE="自定义"

                END_DATE=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
                END_TS=$(date -d "$END_DATE" +%s)
                NOW_TS=$(date +%s)
                
                # 修复核心：确保两个变量都是大写
                DAYS_LEFT=$(( (END_TS - NOW_TS) / 86400 ))

                if [ $DAYS_LEFT -ge 30 ]; then STATUS="有效"
                elif [ $DAYS_LEFT -ge 0 ]; then STATUS="即期"
                else STATUS="已过期"; fi

                # 优化了列宽对齐，保证中文和字母混合时不会错位
                printf "%-25s %-10s %-15s %-10s\n" \
                    "$DOMAIN" "$TYPE" "$(date -d "$END_DATE" +"%Y-%m-%d")" "$DAYS_LEFT 天"
            fi
        done
    fi
    pause
}

uninstall_nginx() {
    echo -e "${YELLOW}卸载 Nginx...${RESET}"
    systemctl stop nginx || true
    apt purge -y nginx nginx-common nginx-core certbot python3-certbot-nginx || true
    apt autoremove -y
    rm -rf /etc/nginx /etc/letsencrypt "$CUSTOM_SSL_BASE"
    remove_default_server
    echo -e "${GREEN}已卸载${RESET}"
    pause
}

# ==========================================
#自定义证书添加专属模块
# ==========================================
add_custom_cert_config() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    echo -ne "${GREEN}请输入您的自定义域名或公网IP: ${RESET}"; read DOMAIN
    [ -z "$DOMAIN" ] && return

    echo -ne "${GREEN}请输入反代目标(例如：http://127.0.0.1:8080): ${RESET}"; read TARGET
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n, 默认y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}
    echo -ne "${GREEN}请输入最大上传大小 (默认 200M): ${RESET}"; read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    # 创建独立的证书物理存储目录
    local DIR_PATH="$CUSTOM_SSL_BASE/$DOMAIN"
    mkdir -p "$DIR_PATH"

    echo -e "${YELLOW}---------------------------------------------${RESET}"
    echo -e "${YELLOW}请提供您的自定义 SSL 证书文件绝对路径。${RESET}"
    echo -e "${YELLOW}（例如你在别处用 acme.sh 申请好的公钥和私钥路径）${RESET}"
    echo -e "${YELLOW}---------------------------------------------${RESET}"
    
    echo -ne "${GREEN}请输入 证书公钥(fullchain/crt) 文件的绝对路径: ${RESET}"; read USER_CERT
    echo -ne "${GREEN}请输入 证书私钥(privkey/key) 文件的绝对路径: ${RESET}"; read USER_KEY

    if [ ! -f "$USER_CERT" ] || [ ! -f "$USER_KEY" ]; then
        red "错误: 您输入的证书文件路径不存在，请核实后再试！"
        rm -rf "$DIR_PATH"
        pause && return
    fi

    # 拷贝并格式化命名到 custom 存储库
    cp -f "$USER_CERT" "$DIR_PATH/fullchain.pem"
    cp -f "$USER_KEY" "$DIR_PATH/privkey.pem"

    # 调用核心生成配置函数，传入特定路径参数
    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE" "$DIR_PATH/fullchain.pem" "$DIR_PATH/privkey.pem"
    create_default_server
    
    if nginx -t; then
        systemctl reload nginx
        echo -e "${GREEN}✅ 自定义证书反代站点 https://$DOMAIN 添加成功！${RESET}"
    else
        echo -e "${RED}❌ Nginx 配置语法错误，已自动撤销软链接，请检查证书有效性。${RESET}"
        rm -f "/etc/nginx/sites-enabled/$DOMAIN"
    fi

    pause


}

# ==========================================
# Emby 专项
# ==========================================
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
    listen 443 ssl http2;
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
    listen 443 ssl http2;
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
    echo -e "${GREEN}===== Emby 反向代理专项配置 =====${RESET}"
    echo -e "${GREEN}1) 普通反代${RESET}"
    echo -e "${GREEN}2) 主站+推流路径重定向${RESET}"
    echo -e "${GREEN}3) 普通反代(自定义证书)${RESET}"
    echo -e "${GREEN}0) 返回主菜单${RESET}"
    echo -ne "${GREEN}请选择 [0-3]: ${RESET}"
    read emby_choice

    case $emby_choice in
        1)
            echo -ne "${GREEN}请输入您的域名: ${RESET}"; read DOMAIN
            check_domain_resolution "$DOMAIN"
            echo -ne "${GREEN}请输入 Emby 地址 (例: https://emby.com): ${RESET}"; read TARGET
            EMAIL=$(generate_random_email)
            certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
            generate_emby_normal_conf "$DOMAIN" "$TARGET"
            nginx -t && systemctl reload nginx
            pause ;;
        2)
            echo -ne "${GREEN}请输入您的域名: ${RESET}"; read DOMAIN
            check_domain_resolution "$DOMAIN"
            echo -ne "${GREEN}请输入 Emby 主站地址: ${RESET}"; read T_MAIN
            echo -ne "${GREEN}请输入推流后端地址: ${RESET}"; read T_STREAM
            EMAIL=$(generate_random_email)
            certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
            generate_emby_stream_conf "$DOMAIN" "$T_MAIN" "$T_STREAM"
            nginx -t && systemctl reload nginx
            pause ;;
        3)
            echo -ne "${GREEN}请输入您的域名: ${RESET}"; read DOMAIN
            check_domain_resolution "$DOMAIN"
            echo -ne "${GREEN}请输入 Emby 地址: ${RESET}"; read TARGET
            local DIR_PATH="$CUSTOM_SSL_BASE/$DOMAIN"
            mkdir -p "$DIR_PATH"
            echo -ne "${GREEN}证书公钥(crt/pem)绝对路径: ${RESET}"; read USER_CERT
            echo -ne "${GREEN}证书私钥(key/pem)绝对路径: ${RESET}"; read USER_KEY
            if [ ! -f "$USER_CERT" ] || [ ! -f "$USER_KEY" ]; then red "文件不存在"; rm -rf "$DIR_PATH"; pause; return; fi
            cp -f "$USER_CERT" "$DIR_PATH/fullchain.pem"
            cp -f "$USER_KEY" "$DIR_PATH/privkey.pem"
            generate_emby_normal_conf "$DOMAIN" "$TARGET" "$DIR_PATH/fullchain.pem" "$DIR_PATH/privkey.pem"
            nginx -t && systemctl reload nginx
            pause ;;
        0) return ;;
        *) echo -e "${RED}无效输入!${RESET}"; sleep 1; emby_menu ;;
    esac
}

# ------------------------------
# 主菜单
# ------------------------------
while true; do
    clear
    echo -e "${GREEN}======= Nginx 管理菜单 =======${RESET}"
    echo -e "${GREEN} 1) 安装Nginx${RESET}"
    echo -e "${GREEN} 2) 添加配置${RESET}"
    echo -e "${GREEN} 3) 添加配置(自定义证书)${RESET}"
    echo -e "${GREEN} 4) 修改配置${RESET}"
    echo -e "${GREEN} 5) 删除配置${RESET}"
    echo -e "${GREEN} 6) 测试证书续期${RESET}"
    echo -e "${GREEN} 7) 查看证书文件${RESET}"
    echo -e "${GREEN} 8) 查看证书状态${RESET}"
    echo -e "${GREEN} 9) Emby反代${RESET}"
    echo -e "${GREEN}10) 重载Nginx配置${RESET}"
    echo -e "${GREEN}11) 卸载Nginx${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    echo -ne "${GREEN} 请选择[0-11]:${RESET}"
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
        10) nginx -t && systemctl reload nginx && echo -e "${GREEN}Nginx 配置已重载成功${RESET}" || echo -e "${RED}配置检查失败，请修复后重试${RESET}"; pause ;;
        11) uninstall_nginx ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ; pause ;;
    esac
done
