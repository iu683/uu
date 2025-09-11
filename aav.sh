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

# 移除系统自带的 default server 配置，避免冲突
remove_default_server() {
    echo -e "${YELLOW}清理系统自带的 default server 配置...${RESET}"
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-available/default
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
    [ ! -f "$DEFAULT_PATH" ] && cat > "$DEFAULT_PATH" <<EOF
server {
    listen 80 default_server;
    server_name _;
    return 403;
}
EOF
    ln -sf "$DEFAULT_PATH" /etc/nginx/sites-enabled/default_server_block
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
    if [ "$DOMAIN_IP" != "$VPS_IP" ]; then
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

    # 第一次删除系统自带 default 配置
    remove_default_server

    # 系统更新 & 升级，无交互
    DEBIAN_FRONTEND=noninteractive apt update
    DEBIAN_FRONTEND=noninteractive apt upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    # 安装依赖工具
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

    # 第二次删除系统自带 default 配置（升级/安装可能恢复的）
    remove_default_server

    # 创建自定义 default_server_block
    create_default_server

    configure_firewall
    systemctl daemon-reload
    systemctl enable --now nginx

    echo -ne "${GREEN}请输入邮箱地址: ${RESET}"; read EMAIL
    echo -ne "${GREEN}请输入域名: ${RESET}"; read DOMAIN
    check_domain_resolution "$DOMAIN"
    echo -ne "${GREEN}请输入反代目标: ${RESET}"; read TARGET
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n): ${RESET}"; read IS_WS

    certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS"
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

    certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS"
    create_default_server
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
    create_default_server
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
    echo -e "${YELLOW}卸载 Nginx 和相关组件...${RESET}"
    systemctl stop nginx || true
    apt purge -y nginx nginx-common nginx-core certbot python3-certbot-nginx || true
    apt autoremove -y
    rm -rf /etc/nginx /etc/letsencrypt
    remove_default_server
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
