#!/bin/bash
set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# ------------------------------
# 工具函数
# ------------------------------
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

ensure_nginx_conf() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/modules-enabled
    # 创建最小 nginx.conf 避免安装报错
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

    # 创建 mime.types
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
    if [ ! -f "$DEFAULT_PATH" ]; then
        cat > "$DEFAULT_PATH" <<EOF
server {
    listen 80 default_server;
    server_name _;
    return 403;
}
EOF
    fi
    [ ! -L "/etc/nginx/sites-enabled/default_server_block" ] && ln -sf "$DEFAULT_PATH" /etc/nginx/sites-enabled/default_server_block
}

fix_default_server_conflict() {
    # 查找所有包含 "default_server" 的配置文件
    DEFAULT_FILES=($(grep -Rl "listen 80 default_server" /etc/nginx/sites-enabled/))
    COUNT=${#DEFAULT_FILES[@]}

    if [ $COUNT -le 1 ]; then
        return 0
    fi

    echo -e "${YELLOW}检测到 $COUNT 个默认服务器，正在自动修复...${RESET}"

    # 保留第一个，其余删除软链接
    for ((i=1;i<COUNT;i++)); do
        FILE="${DEFAULT_FILES[$i]}"
        if [ -L "$FILE" ]; then
            rm -f "$FILE"
            echo -e "${YELLOW}禁用重复默认服务器: $FILE${RESET}"
        fi
    done

    # 测试配置
    if nginx -t; then
        echo -e "${GREEN}默认服务器冲突已修复${RESET}"
    else
        echo -e "${RED}修复后 Nginx 配置仍有错误，请手动检查${RESET}"
    fi
}

generate_server_config() {
    DOMAIN=$1
    TARGET=$2
    IS_WS=$3
    CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"

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

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
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
    VPS_IP=$(curl -s https://ipinfo.io/ip)
    DOMAIN_IP=$(dig +short "$DOMAIN" | tail -n1)
    if [ -z "$DOMAIN_IP" ]; then
        echo -e "${RED}无法解析域名 $DOMAIN${RESET}"
    elif [ "$DOMAIN_IP" != "$VPS_IP" ]; then
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
    create_default_server
    fix_default_server_conflict
    apt update && apt upgrade -y
    apt install -y nginx certbot python3-certbot-nginx
    configure_firewall
    systemctl daemon-reload

    if nginx -t; then
        systemctl enable --now nginx || echo -e "${RED}Nginx 启动失败，请检查配置${RESET}"
    else
        echo -e "${RED}Nginx 配置测试失败，请先手动修复${RESET}"
        pause
    fi

    echo -ne "${GREEN}请输入邮箱地址: ${RESET}"; read EMAIL
    echo -ne "${GREEN}请输入域名: ${RESET}"; read DOMAIN
    check_domain_resolution "$DOMAIN"
    echo -ne "${GREEN}请输入反代目标: ${RESET}"; read TARGET
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n): ${RESET}"; read IS_WS

    if ! certbot certificates | grep -q "$DOMAIN"; then
        certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    else
        echo -e "${YELLOW}证书已存在，跳过申请${RESET}"
    fi

    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS"
    fix_default_server_conflict
    nginx -t && systemctl reload nginx
    systemctl enable --now certbot.timer
    echo -e "${GREEN}安装完成！访问: https://$DOMAIN${RESET}"
    pause
}

add_config() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    echo -ne "${GREEN}请输入域名: ${RESET}"; read DOMAIN
    check_domain_resolution "$DOMAIN"
    echo -ne "${GREEN}请输入反代目标: ${RESET}"; read TARGET
    echo -ne "${GREEN}请输入邮箱地址: ${RESET}"; read EMAIL
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n): ${RESET}"; read IS_WS

    [ -f "/etc/nginx/sites-available/$DOMAIN" ] && echo -e "${YELLOW}配置已存在${RESET}" && pause && return

    if ! certbot certificates | grep -q "$DOMAIN"; then
        certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    else
        echo -e "${YELLOW}证书已存在，跳过申请${RESET}"
    fi

    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS"
    fix_default_server_conflict
    [ ! -L "/etc/nginx/sites-enabled/default_server_block" ] && create_default_server
    nginx -t && systemctl reload nginx
    echo -e "${GREEN}添加完成！访问: https://$DOMAIN${RESET}"
    pause
}

modify_config() {
    [ ! -d "/etc/nginx/sites-available" ] && echo -e "${YELLOW}还没有任何配置文件！${RESET}" && pause && return
    echo -e "${GREEN}现有配置的域名:${RESET}"
    ls /etc/nginx/sites-available/
    echo -ne "${GREEN}请输入要修改的域名: ${RESET}"; read DOMAIN
    CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"
    [ ! -f "$CONFIG_PATH" ] && echo -e "${RED}配置不存在${RESET}" && pause && return

    echo -ne "${GREEN}请输入新反代目标: ${RESET}"; read TARGET
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n): ${RESET}"; read IS_WS
    echo -ne "${GREEN}是否更新邮箱? (y/n): ${RESET}"; read choice
    if [[ "$choice" == "y" ]]; then
        echo -ne "${GREEN}新邮箱: ${RESET}"; read EMAIL
        certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    fi

    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS"
    fix_default_server_conflict
    [ ! -L "/etc/nginx/sites-enabled/default_server_block" ] && create_default_server
    nginx -t && systemctl reload nginx
    echo -e "${GREEN}修改完成！访问: https://$DOMAIN${RESET}"
    pause
}

test_renew() {
    certbot renew --dry-run
    echo -e "${GREEN}证书续期测试完成！${RESET}"
    pause
}

check_cert() {
    certbot certificates
    pause
}

uninstall_nginx() {
    echo -ne "${YELLOW}将删除所有 Nginx 配置和证书，确认? (y/n): ${RESET}"; read ans
    [ "$ans" != "y" ] && return

    systemctl stop nginx || true
    apt purge -y nginx certbot python3-certbot-nginx
    apt autoremove -y
    rm -rf /etc/nginx /etc/letsencrypt
    echo -e "${GREEN}Nginx 和 Certbot 已卸载${RESET}"
    pause
}

# ------------------------------
# 主菜单
# ------------------------------
while true; do
    clear
    echo -e "${GREEN}===== Nginx 管理脚本 =====${RESET}"
    echo -e "${GREEN}1) 安装 Nginx + 证书${RESET}"
    echo -e "${GREEN}2) 添加配置${RESET}"
    echo -e "${GREEN}3) 修改配置${RESET}"
    echo -e "${GREEN}4) 测试证书续期${RESET}"
    echo -e "${GREEN}5) 查看证书有效期${RESET}"
    echo -e "${GREEN}6) 卸载 Nginx + 证书${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -ne "${GREEN}请选择 [0-6]: ${RESET}"
    read choice
    case $choice in
        1) install_nginx ;;
        2) add_config ;;
        3) modify_config ;;
        4) test_renew ;;
        5) check_cert ;;
        6) uninstall_nginx ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ; pause ;;
    esac
done
