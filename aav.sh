#!/bin/bash

# ============ 颜色 ============
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

pause() {
    read -p "按回车继续..." _
}
# ============ 自动开放 80/443 ============
open_ports() {
    echo -e "${YELLOW}正在检测防火墙并开放 80/443 端口...${RESET}"

    # Ubuntu/Debian 常用 UFW
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 80/tcp
        ufw allow 443/tcp
        echo -e "${GREEN}已通过 UFW 开放 80/443${RESET}"
    fi

    # RHEL 系 firewalld
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        firewall-cmd --reload
        echo -e "${GREEN}已通过 firewalld 开放 80/443${RESET}"
    fi

    # 直接 iptables（万一没有防火墙）
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 443 -j ACCEPT
        echo -e "${GREEN}已通过 iptables 开放 80/443${RESET}"
    fi
}

# ============ 安装 Nginx + Certbot ============
install_nginx() {
    echo -e "${GREEN}正在安装 Nginx 和 Certbot...${RESET}"
    apt update -y
    DEBIAN_FRONTEND=noninteractive \
    apt install -y nginx certbot python3-certbot-nginx dnsutils --no-install-recommends \
    -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Options::="--force-confdef"

    systemctl enable nginx
    systemctl start nginx
    open_ports
    echo -e "${GREEN}Nginx 和 Certbot 安装完成${RESET}"
}
# ============ 默认 server 去重 ============
create_default_server() {
    local default_conf="/etc/nginx/sites-enabled/default"
    if [ -f "$default_conf" ]; then
        sed -i 's/default_server//g' "$default_conf"
    fi
}

# ============ 修复 Nginx 配置 ============
fix_nginx_config() {
    echo -e "${YELLOW}开始检测并修复 Nginx 配置...${RESET}"

    # 确保 mime.types 存在
    if [ ! -f "/etc/nginx/mime.types" ]; then
        echo -e "${RED}/etc/nginx/mime.types 丢失，正在修复...${RESET}"
        cat > /etc/nginx/mime.types <<EOF
types {
    text/html                             html htm shtml;
    text/css                              css;
    text/xml                              xml;
    image/gif                             gif;
    image/jpeg                            jpeg jpg;
    application/javascript                js;
    application/atom+xml                  atom;
    application/rss+xml                   rss;
    text/plain                            txt;
    image/png                             png;
    image/x-icon                          ico;
    image/webp                            webp;
}
EOF
        echo -e "${GREEN}mime.types 修复完成${RESET}"
    fi

    # 确保目录存在
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d

    # 检查 nginx.conf 是否包含 sites-enabled
    if ! grep -q "include /etc/nginx/sites-enabled/\*;" /etc/nginx/nginx.conf; then
        echo -e "${YELLOW}nginx.conf 未包含 sites-enabled，自动添加...${RESET}"
        sed -i '/http {/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
    fi

    # 检查配置文件语法
    if ! nginx -t 2>/dev/null; then
        echo -e "${RED}Nginx 配置存在错误，请手动检查: nginx -t${RESET}"
    else
        echo -e "${GREEN}Nginx 配置检测通过，正在重载...${RESET}"
        systemctl restart nginx
    fi
}

# ============ 添加反代配置 ============
add_config() {
    read -p "请输入邮箱地址: " EMAIL
    read -p "请输入域名: " DOMAIN
    read -p "请输入反代目标: " TARGET
    read -p "是否为 WebSocket 反代? (y/n): " IS_WS

    # 检查 DNS
    if ! dig +short "$DOMAIN" > /dev/null; then
        echo -e "${RED}域名未解析或无法解析${RESET}"
        return
    fi

    CONF_PATH="/etc/nginx/sites-available/$DOMAIN.conf"
    ln -sf "$CONF_PATH" "/etc/nginx/sites-enabled/$DOMAIN.conf"

    if [[ "$IS_WS" == "y" ]]; then
        cat > "$CONF_PATH" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location / {
        proxy_pass $TARGET;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF
    else
        cat > "$CONF_PATH" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location / {
        proxy_pass $TARGET;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    fi

    nginx -t && systemctl reload nginx
    certbot --nginx --non-interactive --agree-tos -m "$EMAIL" -d "$DOMAIN"
    echo -e "${GREEN}安装完成！访问: https://$DOMAIN${RESET}"

    fix_nginx_config
}

# ============ 修改配置 ============
modify_config() {
    echo -e "${GREEN}现有配置:${RESET}"
    ls /etc/nginx/sites-available/
    read -p "请输入要修改的域名: " DOMAIN
    nano "/etc/nginx/sites-available/$DOMAIN.conf"
    nginx -t && systemctl reload nginx
}

# ============ 测试续期 ============
test_renew() {
    certbot renew --dry-run
}

# ============ 查看证书 ============
check_cert() {
    read -p "请输入域名: " DOMAIN
    openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -noout -dates
}

# ============ 卸载 ============
uninstall_nginx() {
    systemctl stop nginx
    apt purge -y nginx certbot python3-certbot-nginx
    rm -rf /etc/nginx /etc/letsencrypt
    echo -e "${GREEN}Nginx 与证书已卸载${RESET}"
}

# ============ 菜单 ============
while true; do
    clear
    echo -e "${GREEN}=== Nginx + Certbot 管理工具 ===${RESET}"
    echo -e "${GREEN}1) 安装 Nginx + Certbot${RESET}"
    echo -e "${GREEN}2) 添加反代配置并申请证书${RESET}"
    echo -e "${GREEN}3) 修改现有配置${RESET}"
    echo -e "${GREEN}4) 测试证书续期${RESET}"
    echo -e "${GREEN}5) 查看证书有效期${RESET}"
    echo -e "${GREEN}6) 卸载 Nginx + 证书${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -ne "${GREEN}请选择 [0-6]: ${RESET}"
    read choice
    case $choice in
        1) install_nginx; create_default_server; fix_nginx_config; pause ;;
        2) add_config; pause ;;
        3) modify_config; pause ;;
        4) test_renew; pause ;;
        5) check_cert; pause ;;
        6) uninstall_nginx; pause ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ; pause ;;
    esac
done
