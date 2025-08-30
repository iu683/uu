#!/bin/bash
# =========================================
# 一键部署/管理脚本（菜单化增强版）
# 适配 Debian
# =========================================

WEB_ROOT="/var/www/html"
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

show_menu() {
    clear
    echo -e "${GREEN}=========================================${RESET}"
    echo -e "${GREEN}            脚本管理菜单             ${RESET}"
    echo -e "${GREEN}=========================================${RESET}"
    echo -e "${GREEN}1) 安装/部署脚本${RESET}"
    echo -e "${GREEN}2) 卸载/清除脚本${RESET}"
    echo -e "${GREEN}3) 升级/更新脚本${RESET}"
    echo -e "${GREEN}4) 退出${RESET}"
    echo -e "${GREEN}=========================================${RESET}"
}

install_tim() {
    read -p "请输入你的域名： " DOMAIN
    read -p "请输入脚本 URL： " TIM_URL
    read -p "请输入你的邮箱（用于 HTTPS）： " EMAIL
    read -p "请输入 VPS 本地脚本存放目录（默认 /root/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/root/tim}

    echo -e "${GREEN}安装依赖: nginx, curl, certbot...${RESET}"
    apt update
    apt install -y nginx curl certbot python3-certbot-nginx

    # 创建目录
    [ ! -d /etc/nginx/sites-available ] && mkdir -p /etc/nginx/sites-available
    [ ! -d /etc/nginx/sites-enabled ] && mkdir -p /etc/nginx/sites-enabled
    mkdir -p "$WEB_ROOT"
    mkdir -p "$LOCAL_DIR"
    chmod 700 "$LOCAL_DIR"

    # 下载 tim 脚本
    curl -fsSL "$TIM_URL" -o "$WEB_ROOT/index.sh"
    chmod +x "$WEB_ROOT/index.sh"
    curl -fsSL "$TIM_URL" -o "$LOCAL_DIR/tim"
    chmod +x "$LOCAL_DIR/tim"

    # 配置 Nginx
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root $WEB_ROOT;

    location / {
        default_type text/plain;
        try_files /index.sh =404;
    }
}
EOF

    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    nginx -t && systemctl restart nginx

    # 申请 HTTPS
    echo -e "${GREEN}申请 HTTPS 证书...${RESET}"
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" || {
        echo -e "${RED}HTTPS 安装失败，请检查 DNS 或 Nginx 配置后重试:${RESET}"
        echo "certbot install --cert-name $DOMAIN"
    }

    echo -e "${GREEN}==========================================${RESET}"
    echo -e "${GREEN}部署完成！${RESET}"
    echo -e "${GREEN}1. 可通过域名访问：bash <(curl -sL https://$DOMAIN)${RESET}"
    echo -e "${GREEN}2. 本地脚本已下载到：$LOCAL_DIR/tim${RESET}"
    echo -e "${GREEN}3. HTTPS 已启用（如安装成功）https://$DOMAIN${RESET}"
    echo -e "${GREEN}==========================================${RESET}"
}

uninstall_tim() {
    read -p "请输入你的域名： " DOMAIN
    read -p "请输入 VPS 本地脚本存放目录（默认 /root/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/root/tim}

    echo -e "${GREEN}停止 Nginx...${RESET}"
    systemctl stop nginx

    echo -e "${GREEN}删除 Nginx 配置...${RESET}"
    rm -f /etc/nginx/sites-available/"$DOMAIN"
    rm -f /etc/nginx/sites-enabled/"$DOMAIN"

    echo -e "${GREEN}删除本地脚本...${RESET}"
    rm -rf "$LOCAL_DIR"

    echo -e "${GREEN}删除网页根目录脚本...${RESET}"
    rm -f "$WEB_ROOT/index.sh"

    echo -e "${GREEN}删除 HTTPS 证书...${RESET}"
    certbot delete --cert-name "$DOMAIN" --non-interactive || echo "证书可能不存在"

    echo -e "${GREEN}重启 Nginx...${RESET}"
    systemctl restart nginx

    echo -e "${GREEN}==========================================${RESET}"
    echo -e "${GREEN}卸载完成！${RESET}"
    echo -e "${GREEN}==========================================${RESET}"
}

update_tim() {
    read -p "请输入最新 tim 脚本 URL： " TIM_URL
    read -p "请输入 VPS 本地脚本存放目录（默认 /root/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/root/tim}

    echo -e "${GREEN}更新 tim 脚本...${RESET}"
    curl -fsSL "$TIM_URL" -o "$WEB_ROOT/index.sh"
    chmod +x "$WEB_ROOT/index.sh"
    curl -fsSL "$TIM_URL" -o "$LOCAL_DIR/tim"
    chmod +x "$LOCAL_DIR/tim"

    echo -e "${GREEN}更新完成！${RESET}"
    echo -e "${GREEN}网页根目录和本地脚本已同步最新版本${RESET}"
}

while true; do
    show_menu
    read -p "请选择操作 [1-4]：" choice
    case $choice in
        1) install_tim ;;
        2) uninstall_tim ;;
        3) update_tim ;;
        4) exit 0 ;;
        *) echo -e "${RED}请输入有效选项 [1-4]${RESET}" ;;
    esac
    read -p "按回车返回菜单..."
done
