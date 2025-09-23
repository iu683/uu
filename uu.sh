#!/bin/bash
# 随机图片 API 管理脚本 (支持自动安装 PHP + SSL 证书)
# 系统支持: Debian/Ubuntu

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

NGINX_CONF_DIR="/etc/nginx/sites-available"
NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
PHP_VERSION="8.2"
PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请用 root 用户运行${RESET}"
    exit 1
fi

# 安装依赖
install_dependencies() {
    echo -e "${YELLOW}>>> 安装 Nginx, PHP, Certbot...${RESET}"
    apt update
    apt install -y nginx php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-common unzip curl certbot python3-certbot-nginx
    systemctl enable --now nginx
    systemctl enable --now php${PHP_VERSION}-fpm
}

# 安装随机图片服务
install_random() {
    read -p "请输入你的域名 (例如 api.qhola.com): " DOMAIN
    WEB_ROOT="/var/www/$DOMAIN"
    PHP_FILE="$WEB_ROOT/random.php"
    IMG_DIR="$WEB_ROOT/images"
    CONF_FILE="$NGINX_CONF_DIR/$DOMAIN.conf"

    echo -e "${YELLOW}>>> 安装随机图片服务，域名: $DOMAIN${RESET}"

    mkdir -p "$IMG_DIR"

    # 写 PHP 脚本
    cat > "$PHP_FILE" <<'EOF'
<?php
$images_dir = __DIR__ . '/images/';
$images = glob($images_dir . '*.{jpg,jpeg,png,gif,webp}', GLOB_BRACE);

header("Cache-Control: no-store, no-cache, must-revalidate, max-age=0");
header("Pragma: no-cache");

if ($images) {
    $random_image = $images[array_rand($images)];
    $info = getimagesize($random_image);
    header('Content-Type: ' . $info['mime']);
    readfile($random_image);
} else {
    header("HTTP/1.0 404 Not Found");
    echo "No images found.";
}
EOF

    # 写 Nginx 配置
    cat > "$CONF_FILE" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root $WEB_ROOT;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location /random {
        rewrite ^/random\$ /random.php last;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:$PHP_FPM_SOCK;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

    ln -sf "$CONF_FILE" "$NGINX_ENABLED_DIR/$DOMAIN.conf"
    nginx -t && systemctl reload nginx

    # 自动申请 SSL 证书
    echo -e "${YELLOW}>>> 申请 Let's Encrypt SSL 证书...${RESET}"
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" --redirect

    echo -e "${GREEN}安装完成！${RESET}"
    echo -e "图片目录: $IMG_DIR"
    echo -e "访问地址: https://$DOMAIN/random"
    echo -e "${YELLOW}>>> 请把图片放到: $IMG_DIR${RESET}"
}

# 卸载
uninstall_random() {
    read -p "请输入要卸载的域名: " DOMAIN
    WEB_ROOT="/var/www/$DOMAIN"
    CONF_FILE="$NGINX_CONF_DIR/$DOMAIN.conf"

    echo -e "${YELLOW}>>> 卸载随机图片服务，域名: $DOMAIN${RESET}"

    certbot delete --cert-name "$DOMAIN"
    rm -rf "$WEB_ROOT"
    rm -f "$CONF_FILE"
    rm -f "$NGINX_ENABLED_DIR/$DOMAIN.conf"

    nginx -t && systemctl reload nginx
    echo -e "${RED}已卸载 $DOMAIN${RESET}"
}

# 状态
status_random() {
    read -p "请输入要查看的域名: " DOMAIN
    WEB_ROOT="/var/www/$DOMAIN"
    PHP_FILE="$WEB_ROOT/random.php"
    IMG_DIR="$WEB_ROOT/images"

    if [ -f "$PHP_FILE" ]; then
        echo -e "${GREEN}$DOMAIN 已安装随机图片服务${RESET}"
        echo "网站目录: $WEB_ROOT"
        echo "脚本文件: $PHP_FILE"
        echo "图片目录: $IMG_DIR"
        count=$(ls "$IMG_DIR" 2>/dev/null | wc -l)
        echo "图片数量: $count"
    else
        echo -e "${RED}$DOMAIN 未安装${RESET}"
    fi
}

# 菜单
while true; do
    echo -e "${GREEN}======================${RESET}"
    echo -e "${GREEN} 随机图片 API 管理菜单${RESET}"
    echo -e "${GREEN}======================${RESET}"
    echo -e "${GREEN}1) 安装依赖 (Nginx + PHP + Certbot)${RESET}"
    echo -e "${GREEN}2) 安装随机图片服务 (输入域名)${RESET}"
    echo -e "${GREEN}3) 卸载随机图片服务 (输入域名)${RESET}"
    echo -e "${GREEN}4) 查看状态 (输入域名)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -n "请输入选项: "
    read choice

    case "$choice" in
        1) install_dependencies ;;
        2) install_random ;;
        3) uninstall_random ;;
        4) status_random ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
done
