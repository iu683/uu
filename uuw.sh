#!/bin/bash
set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

pause() {
    echo -ne "${YELLOW}按回车返回菜单...${RESET}"
    read
}

configure_firewall() {
    for PORT in 80 443; do
        if command -v ufw >/dev/null 2>&1; then
            ufw allow $PORT/tcp || true
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
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen [::]:443 ssl;
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
    VPS_IP=$(curl -6 -s https://ifconfig.co)
    DOMAIN_IP=$(dig AAAA +short "$DOMAIN" | tail -n1)

    echo -e "${YELLOW}检测域名 AAAA 记录...${RESET}"
    echo -e "  ${GREEN}VPS IPv6:   ${RESET}$VPS_IP"
    echo -e "  ${GREEN}域名 IPv6:  ${RESET}$DOMAIN_IP"

    if [ -z "$DOMAIN_IP" ]; then
        echo -e "${RED}错误: 域名 $DOMAIN 没有 AAAA 记录！${RESET}"
    elif [ "$DOMAIN_IP" != "$VPS_IP" ]; then
        echo -e "${RED}警告: 域名 $DOMAIN 解析为 $DOMAIN_IP, VPS IPv6 为 $VPS_IP${RESET}"
    else
        echo -e "${GREEN}域名 AAAA 记录解析正常 (IPv6)${RESET}"
    fi
}

install_nginx() {
    ensure_nginx_conf

    # 第一次删除系统自带 default 配置
    remove_default_server

    # 系统更新 & 安装依赖
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
    fix_duplicate_default_server

    echo -ne "${GREEN}请输入域名: ${RESET}"; read DOMAIN
    check_domain_resolution "$DOMAIN"
    echo -ne "${GREEN}请输入反代目标: ${RESET}"; read TARGET
    echo -ne "${GREEN}请输入邮箱地址: ${RESET}"; read EMAIL
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n): ${RESET}"; read IS_WS

    [ -f "/etc/nginx/sites-available/$DOMAIN" ] && echo -e "${YELLOW}配置已存在${RESET}" && pause && return

    certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS"

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
    systemctl stop nginx || true
    apt purge -y nginx certbot python3-certbot-nginx
    apt autoremove -y
    rm -rf /etc/nginx /etc/letsencrypt
    echo -e "${GREEN}Nginx 和 Certbot 已卸载${RESET}"
    pause
}

# 主菜单
while true; do
    clear
    echo -e "${GREEN}===== Nginx IPv6-only 管理脚本 =====${RESET}"
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
