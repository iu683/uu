#!/bin/bash
# 随机图片服务管理脚本

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

NGINX_CONF="/etc/nginx/sites-available/random_image"
NGINX_LINK="/etc/nginx/sites-enabled/random_image"
WWW_DIR="/var/www/random"
PHP_VERSION=""
PHP_FPM_SOCK=""

# 自动检测 PHP 版本
detect_php_version() {
    if command -v php >/dev/null 2>&1; then
        PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
        if [ -S "/run/php/php${PHP_VERSION}-fpm.sock" ]; then
            PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
            return
        fi
    fi

    if apt-cache search php | grep -q "php8.3-fpm"; then
        PHP_VERSION="8.3"
    elif apt-cache search php | grep -q "php8.2-fpm"; then
        PHP_VERSION="8.2"
    else
        echo -e "${RED}未找到合适的 PHP 版本，请检查系统源${RESET}"
        exit 1
    fi
    PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
}

# 安装依赖
install_dependencies() {
    echo -e "${YELLOW}>>> 检查并安装依赖...${RESET}"
    apt update

    detect_php_version
    echo -e "${GREEN}>>> 使用 PHP ${PHP_VERSION}${RESET}"

    apt install -y nginx php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-common unzip curl certbot python3-certbot-nginx

    systemctl enable --now nginx
    systemctl enable --now php${PHP_VERSION}-fpm
}

# 安装随机图片服务
install_service() {
    read -p "请输入绑定的域名: " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}域名不能为空！${RESET}"
        exit 1
    fi

    mkdir -p $WWW_DIR/images

cat > $WWW_DIR/index.php <<'EOF'
<?php
$images_dir = __DIR__ . '/images/';
$images = glob($images_dir . '*.{jpg,jpeg,png,gif}', GLOB_BRACE);
if ($images) {
    $random_image = $images[array_rand($images)];
    $info = getimagesize($random_image);
    header('Content-type: ' . $info['mime']);
    readfile($random_image);
} else {
    header("HTTP/1.0 404 Not Found");
    echo "No images found.";
}
?>
EOF

cat > $NGINX_CONF <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root ${WWW_DIR};
    index index.php;

    location / {
        try_files \$uri /index.php;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCK};
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    ln -sf $NGINX_CONF $NGINX_LINK
    nginx -t && systemctl reload nginx

    echo -e "${YELLOW}>>> 配置 HTTPS 证书...${RESET}"
    certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m admin@${DOMAIN}

    echo -e "${GREEN}安装完成！${RESET}"
    echo -e "访问地址: ${YELLOW}https://${DOMAIN}/${RESET}"
    echo -e "上传图片目录: ${GREEN}${WWW_DIR}/images/${RESET}"
    echo -e "请将 JPG/PNG/GIF 文件放到该目录，刷新网页即可随机显示。"
}

# 卸载
uninstall_service() {
    echo -e "${YELLOW}>>> 正在卸载服务...${RESET}"
    rm -rf $WWW_DIR
    rm -f $NGINX_CONF $NGINX_LINK
    nginx -t && systemctl reload nginx
    echo -e "${GREEN}卸载完成${RESET}"
}

# 菜单
menu() {
    echo -e "${GREEN}======================${RESET}"
    echo -e "${GREEN}1. 安装随机图片服务${RESET}"
    echo -e "${GREEN}2. 卸载随机图片服务${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}======================${RESET}"
    read -p "请输入选项: " CHOICE
    case $CHOICE in
        1) install_dependencies; install_service ;;
        2) uninstall_service ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

menu
