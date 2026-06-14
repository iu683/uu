#!/bin/bash
set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 自定义证书存放基础归档目录
CUSTOM_SSL_BASE="/etc/nginx/custom_ssl"
mkdir -p "$CUSTOM_SSL_BASE"


# ✨ 终极双栈/纯v6 智能 IP 获取引擎
get_public_ip() {
    local mode=${1:-"v6"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        # 强制获取 IPv4
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        # 强制获取 IPv6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        # auto 模式：双栈环境优先获取 IPv4 (更适合大众网络)，纯 v6 环境自动fallback到 v6
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        # 如果获取 v4 失败，说明可能是纯 v6 机器，尝试获取 v6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    # 兜底处理：所有接口都失败时，直接输出 127.0.0.1，不报错
    echo "127.0.0.1" && return 0
}


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

# 删除系统自带 default 配置
remove_default_server() {
    echo -e "${YELLOW}清理系统自带 default 配置...${RESET}"
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-available/default
}

ensure_nginx_conf() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/modules-enabled

    # nginx.conf
    if [ ! -f /etc/nginx/nginx.conf ]; then
        cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events { worker_connections 768; }

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

    # mime.types
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

create_default_server() {
    DEFAULT_PATH="/etc/nginx/sites-available/default_server_block"
    if [ ! -f "$DEFAULT_PATH" ]; then
        cat > "$DEFAULT_PATH" <<EOF
server {
    listen [::]:80 default_server;
    server_name _;
    return 403;
}
EOF
        ln -sf "$DEFAULT_PATH" /etc/nginx/sites-enabled/default_server_block
    fi
}

fix_duplicate_default_server() {
    DEFAULT_FILES=($(grep -rl "default_server" /etc/nginx/sites-enabled/ || true))
    if [ ${#DEFAULT_FILES[@]} -gt 1 ]; then
        echo -e "${YELLOW}检测到重复 default_server 配置，自动修复中...${RESET}"
        for ((i=1; i<${#DEFAULT_FILES[@]}; i++)); do
            rm -f "${DEFAULT_FILES[i]}"
            echo -e "${YELLOW}已删除重复文件: ${DEFAULT_FILES[i]}${RESET}"
        done
    fi
}

generate_server_config() {
    DOMAIN=$1
    TARGET=$2
    IS_WS=$3
    MAX_SIZE=$4
    CERT_PATH=$5
    KEY_PATH=$6
    CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"

    MAX_SIZE=${MAX_SIZE:-200M}
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
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen [::]:443 ssl;
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
    VPS_IP=$(get_public_ip || echo "")
    DOMAIN_IP=$(dig AAAA +short "$DOMAIN" | tail -n1 || echo "")

    echo -e "${YELLOW}检测域名 AAAA 记录...${RESET}"
    echo -e "  ${GREEN}VPSIPv6:   ${RESET}$VPS_IP"
    echo -e "  ${GREEN}域名IPv6:  ${RESET}$DOMAIN_IP"

    if [ -z "$DOMAIN_IP" ]; then
        echo -e "${RED}错误: 域名 $DOMAIN 没有 AAAA 记录！${RESET}"
    elif [ "$DOMAIN_IP" != "$VPS_IP" ]; then
        echo -e "${RED}警告: 域名 $DOMAIN 解析为 $DOMAIN_IP, VPS IPv6 为 $VPS_IP${RESET}"
    else
        echo -e "${GREEN}域名 AAAA 记录解析正常 (IPv6)${RESET}"
    fi
}

# 辅助检查与授权函数：防止外部 ACME 路径导致的权限阻塞（已适配 Nginx）
fix_external_cert_permission() {
    local cert=$1
    local key=$2
    
    # 针对 root 目录的致命硬拦截
    if [[ "$cert" == /root/* ]] || [[ "$key" == /root/* ]]; then
        echo -e "${RED}❌ 致命拒绝: 检测到您的证书源文件位于 /root/ 目录下！${RESET}"
        echo -e "${YELLOW}原因分析: /root 目录权限极为严苛(700)，任何非root用户(包括 Nginx 的 www-data 用户组)均无权穿透。${RESET}"
        echo -e "${YELLOW}         即使脚本在这里使用了软链接，Nginx 在运行时依然无法越权读取源文件！${RESET}"
        echo -e "${GREEN}💡 权威推荐: 请在 acme.sh 脚本命令中加上安装指令(--install-cert)，将证书自动导出到公共目录（如 /etc/ssl/ 或 /etc/certs/ 文件夹下）再试。${RESET}"
        return 1
    fi

    # 针对其他公共目录，自动修复其上级路径及文件自身的读取权限
    local cert_dir=$(dirname "$cert")
    
    # 确保 Nginx 运行用户（www-data）有进入该目录的执行权限 (+x)
    chmod +x "$cert_dir" 2>/dev/null || true
    # 确保源文件本身可读
    chmod 644 "$cert" "$key" 2>/dev/null || true
    
    # 如果系统安装了 acl 工具，则使用更精准的 ACL 策略赋予 www-data 用户权限
    if command -v setfacl >/dev/null 2>&1; then
        setfacl -m u:www-data:rx "$cert_dir" 2>/dev/null || true
        setfacl -m u:www-data:r "$cert" "$key" 2>/dev/null || true
    fi
    return 0
}

install_nginx() {
    if command -v nginx >/dev/null 2>&1 && command -v certbot >/dev/null 2>&1; then
        echo -e "${YELLOW}提示: 检测到系统已安装 Nginx 与 Certbot，自动跳过安装。${RESET}"
        pause
        return
    fi

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

    echo -ne "${YELLOW}是否现在配置反向代理并申请证书？(Y/n,默认Y): ${RESET}"
    read CONFIRM
    CONFIRM=${CONFIRM:-Y}

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已跳过配置，返回主菜单。${RESET}"
        pause
        return
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
    echo -ne "${GREEN}请输入反代目标(例如:http://[2026:f92a:222:ffff::88]:8888): ${RESET}"; read TARGET
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n，回车默认 y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}

    echo -ne "${GREEN}请输入最大上传大小 (默认 200M): ${RESET}"
    read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE"

    nginx -t && systemctl reload nginx
    systemctl enable --now certbot.timer
    echo -e "${GREEN}安装并配置完成！访问: https://$DOMAIN${RESET}"
    pause
}

add_config() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    echo -ne "${GREEN}请输入域名(例如:example.com): ${RESET}"; read DOMAIN
    check_domain_resolution "$DOMAIN"
    echo -ne "${GREEN}请输入反代目标(例如:http://[2026:f92a:222:ffff::88]:8888): ${RESET}"; read TARGET

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

    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n，回车默认 y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}

    echo -ne "${GREEN}请输入最大上传大小 (默认 200M): ${RESET}"
    read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    [ -f "/etc/nginx/sites-available/$DOMAIN" ] && echo -e "${YELLOW}配置已存在${RESET}" && pause && return

    certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE"
    create_default_server
    nginx -t && systemctl reload nginx
    echo -e "${GREEN}添加完成！访问: https://$DOMAIN${RESET}"
    pause
}

add_custom_cert_config() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    echo -ne "${GREEN}请输入域名(例如:example.com): ${RESET}"; read DOMAIN
    check_domain_resolution "$DOMAIN"
    echo -ne "${GREEN}请输入反代目标(例如:http://[2026:f92a:222:ffff::88]:8888): ${RESET}"; read TARGET

    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n，回车默认 y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}

    echo -ne "${GREEN}请输入最大上传大小 (默认 200M): ${RESET}"
    read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    [ -f "/etc/nginx/sites-available/$DOMAIN" ] && echo -e "${YELLOW}配置已存在${RESET}" && pause && return

    local DIR_PATH="$CUSTOM_SSL_BASE/$DOMAIN"
    mkdir -p "$DIR_PATH"

    echo -e "${YELLOW}---------------------------------------------${RESET}"
    echo -e "${YELLOW}提示: 请提前将你的证书文件上传至服务器。${RESET}"
    echo -e "${YELLOW}---------------------------------------------${RESET}"
    echo -ne "${GREEN}请输入 证书公钥(fullchain.pem/crt) 的绝对路径: ${RESET}"; read USER_CERT
    echo -ne "${GREEN}请输入 证书私钥(privkey.pem/key) 的绝对路径: ${RESET}"; read USER_KEY

    # 转化为绝对路径，防止用户输入相对路径导致建立软链接后断开
    local ABS_CERT=$(readlink -f "$USER_CERT" 2>/dev/null || realpath "$USER_CERT" 2>/dev/null || echo "$USER_CERT")
    local ABS_KEY=$(readlink -f "$USER_KEY" 2>/dev/null || realpath "$USER_KEY" 2>/dev/null || echo "$USER_KEY")

    if [ ! -f "$ABS_CERT" ] || [ ! -f "$ABS_KEY" ]; then
        echo -e "${RED}错误: 证书文件路径不存在，添加失败！${RESET}"
        rm -rf "$DIR_PATH"
        pause && return
    fi

    # === 执行权限拦截与自动修复逻辑 ===
    if ! fix_external_cert_permission "$ABS_CERT" "$ABS_KEY"; then
        rm -rf "$DIR_PATH"
        pause && return
    fi

    # 核心机制重写：由 cp -f 改为 ln -sf 创建软链接
    rm -f "$DIR_PATH/fullchain.pem" "$DIR_PATH/privkey.pem"
    ln -sf "$ABS_CERT" "$DIR_PATH/fullchain.pem"
    ln -sf "$ABS_KEY" "$DIR_PATH/privkey.pem"

    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE" "$DIR_PATH/fullchain.pem" "$DIR_PATH/privkey.pem"
    create_default_server

    if nginx -t; then
        systemctl reload nginx
        echo -e "${GREEN}自定义证书反代站点添加完成！访问: https://$DOMAIN${RESET}"
    else
        echo -e "${RED}❌ Nginx 配置测试失败，已自动撤销更改。请检查自定义证书有效性。${RESET}"
        rm -f "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
        rm -rf "$DIR_PATH"
    fi
    pause
}

modify_config() {
    CONFIG_DIR="/etc/nginx/sites-available"
    [ ! -d "$CONFIG_DIR" ] && echo -e "${YELLOW}还没有任何配置文件！${RESET}" && pause && return

    DOMAINS=($(ls "$CONFIG_DIR" | grep -vE 'default|default_server_block' | sort))
    [ ${#DOMAINS[@]} -eq 0 ] && echo -e "${YELLOW}没有域名配置！${RESET}" && pause && return

    echo -e "${GREEN}现有配置的域名:${RESET}"
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
    echo -ne "${GREEN}请输入新反代目标(例如:http://[2026:f92a:222:ffff::88]:8888): ${RESET}"; read TARGET
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n，回车默认 y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}
    echo -ne "${GREEN}请输入最大上传大小 (默认 200M): ${RESET}"
    read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    if grep -q "$CUSTOM_SSL_BASE" "$CONFIG_PATH"; then
        generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE" "$CUSTOM_SSL_BASE/$DOMAIN/fullchain.pem" "$CUSTOM_SSL_BASE/$DOMAIN/privkey.pem"
    else
        echo -ne "${GREEN}是否更新邮箱? (y/n，回车默认 n): ${RESET}"; read c
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

    echo -e "${GREEN}可删除的域名:${RESET}"
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
        rm -rf "$CUSTOM_SSL_BASE/$DOMAIN"
        echo -e "${GREEN}自定义证书配置及本地归档文件已删除${RESET}"
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
        systemctl reload nginx
        echo -e "${GREEN}域名 $DOMAIN 已安全移除${RESET}"
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

    echo -e "${GREEN}请选择要模拟续期的托管域名编号:${RESET}"
    local idx=1
    local valid_domains=()
    for d in "${DOMAINS[@]}"; do
        if ! grep -q "$CUSTOM_SSL_BASE" "/etc/nginx/sites-available/$d"; then
            echo -e "${GREEN}${idx}) $d${RESET}"
            valid_domains+=("$d")
            idx=$((idx+1))
        fi
    done

    if [ ${#valid_domains[@]} -eq 0 ]; then
        echo -e "${YELLOW}当前全部站点均为自定义证书，无需通过 Certbot 续期。${RESET}"
        pause && return
    fi

    echo -ne "${GREEN}选择编号 (0 返回): ${RESET}"
    read choice
    if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ || "$choice" -eq 0 ]]; then return; fi
    if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#valid_domains[@]} ]; then
        echo -e "${RED}无效选择${RESET}"; pause; return
    fi

    DOMAIN="${valid_domains[$((choice-1))]}"
    echo -e "${GREEN}正在测试 $DOMAIN 的证书续期...${RESET}"
    certbot renew --dry-run --cert-name "$DOMAIN"
    pause
}

check_cert() {
    echo -e "${GREEN}1) 查看 Certbot 托管证书${RESET}"
    echo -e "${GREEN}2) 查看自定义证书${RESET}"
    echo -ne "${GREEN}请选择 [1-2]: ${RESET}"
    read c_choice

    if [ "$c_choice" == "1" ]; then
        local CERT_DIR="/etc/letsencrypt/live"
        [ ! -d "$CERT_DIR" ] && echo -e "${GREEN}没有托管证书${RESET}" && pause && return
        local DOMAINS=()
        for d in $(ls "$CERT_DIR"); do
            [ -f "$CERT_DIR/$d/fullchain.pem" ] && DOMAINS+=("$d")
        done
        [ ${#DOMAINS[@]} -eq 0 ] && echo -e "${GREEN}没有托管证书${RESET}" && pause && return
        for i in "${!DOMAINS[@]}"; do echo -e "${GREEN}$((i+1))) ${DOMAINS[$i]}${RESET}"; done
        echo -ne "${GREEN}请选择编号 (0 返回): ${RESET}"; read choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -eq 0 ] || [ "$choice" -gt ${#DOMAINS[@]} ]; then return; fi
        certbot certificates --cert-name "${DOMAINS[$((choice-1))]}"
    elif [ "$c_choice" == "2" ]; then
        if [ -d "$CUSTOM_SSL_BASE" ] && [ "$(ls -A $CUSTOM_SSL_BASE)" ]; then
            ls -lhR "$CUSTOM_SSL_BASE"
        else
            echo -e "${YELLOW}自定义证书归档目录为空。${RESET}"
        fi
    fi
    pause
}

check_domains_status() {
    clear
    echo -e "${YELLOW}========================================${RESET}"
    echo -e "${YELLOW}      ◈ 域名证书状态实时监控 ◈          ${RESET}"
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

update_nginx_software() {
    if ! command -v nginx >/dev/null 2>&1; then
        echo -e "${RED}❌ 系统未安装 Nginx，无法升级。请先选择选项 1 安装环境。${RESET}"
        pause && return
    fi
    
    local CURRENT_VER=$(nginx -v 2>&1 | awk -F/ '{print $2}' | awk '{print $1}')
    echo -e "${YELLOW}========================================${RESET}"
    echo -e "${YELLOW}     ◈ 正在执行 Nginx 软件版本升级 ◈    ${RESET}"
    echo -e "${YELLOW}========================================${RESET}"

    echo -e "${GREEN}当前系统安装的 Nginx 版本为: ${YELLOW}${CURRENT_VER}${RESET}"
    echo -ne "${YELLOW}是否要从官方源拉取检查并平滑升级？(y/N,默认N): ${RESET}"
    read up_choice
    if [[ ! "$up_choice" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消升级。${RESET}"
        return
    fi

    echo -e "${GREEN}正在进行安全配置备份...${RESET}"
    local BACKUP_DIR="/etc/nginxbackup/nginx_conf_backup_$(date +%Y%m%d)"
    mkdir -p "$BACKUP_DIR"
    [ -d "/etc/nginx/sites-available" ] && cp -r /etc/nginx/sites-available "$BACKUP_DIR/" || true
    [ -d "$CUSTOM_SSL_BASE" ] && cp -r "$CUSTOM_SSL_BASE" "$BACKUP_DIR/" || true
    echo -e "${GREEN}配置备份成功，已存入: ${BACKUP_DIR}${RESET}"

    echo -e "${GREEN}正在同步软件源并升级内核...${RESET}"
    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    
    if apt install --only-upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        nginx nginx-common nginx-core certbot python3-certbot-nginx; then
        
        systemctl daemon-reload
        systemctl restart nginx || systemctl start nginx
        
        local NEW_VER=$(nginx -v 2>&1 | awk -F/ '{print $2}' | awk '{print $1}')
        echo -e "${GREEN}✅ Nginx 与相关依赖组件平滑更新完成！${RESET}"
        echo -e "${GREEN}更新后当前版本为: ${YELLOW}${NEW_VER}${RESET}"
    else
        echo -e "${RED}❌ 软件更新期间发生异常，尝试恢复并启动现有 Nginx 服务...${RESET}"
        systemctl start nginx || true
    fi
    pause
}

uninstall_nginx() {
    echo -e "${YELLOW}【警告】此操作将彻底删除 Nginx、Certbot（SSL证书工具）以及所有网站配置文件和证书！${RESET}"
    read -r -p "你确定要彻底卸载相关环境吗？(y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}操作已取消。${RESET}"
        pause
        return 0
    fi

    echo -e "${YELLOW}卸载 Nginx 与证书组件...${RESET}"
    systemctl stop nginx || true
    apt purge -y nginx nginx-common nginx-core certbot python3-certbot-nginx || true
    apt autoremove -y
    rm -rf /etc/nginx /etc/letsencrypt "$CUSTOM_SSL_BASE"
    remove_default_server
    echo -e "${GREEN}已彻底卸载相关环境${RESET}"
    pause
}


# ============================================================
# 新增：GitHub 代理下载核心函数
# ============================================================
run_backup_restore() {
    clear
    # 用户提供的代理前缀列表
    local GITHUB_PROXY=(
        ''
        'https://v6.gh-proxy.org/'
        'https://gh-proxy.com/'
        'https://hub.glowp.xyz/'
        'https://proxy.vvvv.ee/'
        'https://ghproxy.lvedong.eu.org/'
    )
    
    local RAW_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/nginxbackup.sh"
    local TEMP_SCRIPT="/tmp/nginx_backup_restore_temp.sh"
    local success=false


    # 循环轮询代理列表
    for proxy in "${GITHUB_PROXY[@]}"; do
        local target_url="${proxy}${RAW_URL}"
        if [ -n "$proxy" ]; then
            echo
        else
            echo
        fi

        # 使用 curl 下载，设置 8 秒超时
        if curl -fsSL --connect-timeout 8 "$target_url" -o "$TEMP_SCRIPT"; then
            success=true
            break
        fi
        echo -e "${RED}❌ 当前连接失败，正在切换下一个节点...${RESET}"
    done

    # 判断是否下载成功并执行
    if [ "$success" = true ] && [ -f "$TEMP_SCRIPT" ]; then
        echo
        chmod +x "$TEMP_SCRIPT"
        
        # 真正执行备份恢复脚本
        bash "$TEMP_SCRIPT"
        
        # 执行完毕后清理临时文件
        rm -f "$TEMP_SCRIPT"
    else
        echo -e "${RED}❌ 致命错误：所有 GitHub 代理节点均无法连接，请检查您的 VPS 网络！${RESET}"
    fi
    pause
}
# ------------------------------
# 主菜单逻辑循环面板
# ------------------------------
while true; do
    clear
    
    if systemctl is-active --quiet nginx 2>/dev/null; then
        STATUS="${YELLOW}运行中${RESET}"
    else
        if command -v nginx >/dev/null 2>&1; then
            STATUS="${RED}已停止${RESET}"
        else
            STATUS="${RED}未安装${RESET}"
        fi
    fi

    if command -v nginx >/dev/null 2>&1; then
        VERSION_SHOW=$(nginx -v 2>&1 | awk -F/ '{print $2}' | awk '{print $1}')
    else
        VERSION_SHOW="无"
    fi

    if [ -d "/etc/nginx/sites-available" ]; then
        SITE_COUNT=$(ls /etc/nginx/sites-available | grep -vE 'default|default_server_block' | wc -l || echo "0")
    else
        SITE_COUNT="0"
    fi

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈ Nginx 反向代理管理面板 ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $STATUS"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}$VERSION_SHOW${RESET}"
    echo -e "${GREEN}站点   :${RESET} ${YELLOW}$SITE_COUNT 个${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 Nginx${RESET}"
    echo -e "${GREEN} 2. 添加配置(80申请证书)${RESET}"
    echo -e "${GREEN} 3. 添加配置(自定义证书)${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 删除配置${RESET}"
    echo -e "${GREEN} 6. 测试证书续期${RESET}"
    echo -e "${GREEN} 7. 查看证书信息${RESET}"
    echo -e "${GREEN} 8. 查看证书状态${RESET}"
    echo -e "${GREEN} 9. 重载配置${RESET}"
    echo -e "${GREEN}10. 更新 Nginx${RESET}"
    echo -e "${GREEN}11. 卸载 Nginx${RESET}"
    echo -e "${GREEN}12. 备份恢复${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN} 请选择:${RESET}"
    
    read choice
    case $choice in
        1)  install_nginx ;;
        2)  add_config ;;
        3)  add_custom_cert_config ;;
        4)  modify_config ;;
        5)  delete_config ;;
        6)  test_renew ;;
        7)  check_cert ;;
        8)  check_domains_status ;;
        9)  nginx -t && systemctl reload nginx && echo -e "${GREEN}Nginx 配置已重载成功${RESET}" || echo -e "${RED}配置检查失败，请修复后重试${RESET}"; pause ;;
        10) update_nginx_software ;;
        11) uninstall_nginx ;;
        12) run_backup_restore ;;
        0)  exit 0 ;;
        *)  echo -e "${RED}无效选项${RESET}" ; pause ;;
    esac
done
