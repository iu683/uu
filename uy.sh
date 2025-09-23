#!/bin/bash
# 随机图片多路径 API 管理脚本
# 系统支持: Ubuntu 22.04/24.04

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

BASE_DIR="/var/www/random"
NGINX_CONF_DIR="/etc/nginx/sites-available"
NGINX_LINK_DIR="/etc/nginx/sites-enabled"
NGINX_CONF_FILE="$NGINX_CONF_DIR/random_image.conf"
PHP_VERSION=""
PHP_FPM_SOCK=""

# 检查 root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请用 root 用户运行${RESET}"
    exit 1
fi

# 自动检测 PHP 版本
detect_php() {
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
    echo -e "${YELLOW}>>> 安装依赖 Nginx + PHP + Certbot...${RESET}"
    apt update
    detect_php
    echo -e "${GREEN}>>> 检测到 PHP ${PHP_VERSION}${RESET}"
    apt install -y nginx php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-common unzip curl certbot python3-certbot-nginx
    systemctl enable --now nginx
    systemctl enable --now php${PHP_VERSION}-fpm
}

# 安装多路径随机图片服务
install_service() {
    read -p "请输入你的域名 (例如 api.qhola.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}域名不能为空${RESET}"
        exit 1
    fi

    # 创建基础目录
    mkdir -p $BASE_DIR/images/random
    mkdir -p $BASE_DIR/images/random1
    mkdir -p $BASE_DIR/images/random2

    # 创建 PHP 脚本
    cat > $BASE_DIR/index.php <<'EOF'
<?php
$base_dir = __DIR__ . '/images/';
$request_uri = $_SERVER['REQUEST_URI'];
$path = basename(parse_url($request_uri, PHP_URL_PATH), ".json");
$is_json = str_ends_with($request_uri, '.json');
$image_dir = $base_dir . $path . '/';
if (!is_dir($image_dir)) { $image_dir = $base_dir . 'random/'; $path='random'; }
$images = glob($image_dir . '*.{jpg,jpeg,png,gif,webp}', GLOB_BRACE);
$protocol = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS']!=='off')?"https://":"http://";
$host = $_SERVER['HTTP_HOST'];
if ($images) {
    $random_image = $images[array_rand($images)];
    $image_url = $protocol . $host . '/images/' . $path . '/' . basename($random_image);
    if($is_json){ header('Content-Type: application/json'); echo json_encode(["url"=>$image_url],JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE); exit; }
    $ext = strtolower(pathinfo($random_image,PATHINFO_EXTENSION));
    $mime_types=['jpg'=>'image/jpeg','jpeg'=>'image/jpeg','png'=>'image/png','gif'=>'image/gif','webp'=>'image/webp'];
    $mime=$mime_types[$ext]??'application/octet-stream';
    header("Content-Type: $mime"); header("Content-Length: ".filesize($random_image)); readfile($random_image); exit;
} else {
    header("HTTP/1.0 404 Not Found");
    if($is_json){ header('Content-Type: application/json'); echo json_encode(["error"=>"No images found for $path"],JSON_UNESCAPED_UNICODE); }
    else { echo "No images found for $path"; }
}
EOF

    # 创建 Nginx 配置
    cat > $NGINX_CONF_FILE <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root ${BASE_DIR};
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

    ln -sf $NGINX_CONF_FILE $NGINX_LINK_DIR/random_image.conf
    nginx -t && systemctl reload nginx

    # 自动申请 HTTPS
    echo -e "${YELLOW}>>> 申请 HTTPS 证书...${RESET}"
    certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m admin@${DOMAIN}

    echo -e "${GREEN}安装完成！${RESET}"
    echo -e "访问地址: ${YELLOW}https://${DOMAIN}/random${RESET}"
    echo -e "访问 JSON 地址: ${YELLOW}https://${DOMAIN}/random.json${RESET}"
    echo -e "多路径目录: ${GREEN}${BASE_DIR}/images/random*, 例如 random1, random2${RESET}"
    echo -e "请上传 JPG/PNG/GIF/WEBP 图片到对应目录"
}

# 卸载
uninstall_service() {
    read -p "请输入域名: " DOMAIN
    echo -e "${YELLOW}>>> 卸载服务...${RESET}"
    certbot delete --cert-name "$DOMAIN"
    rm -rf $BASE_DIR
    rm -f $NGINX_CONF_FILE $NGINX_LINK_DIR/random_image.conf
    nginx -t && systemctl reload nginx
    echo -e "${GREEN}卸载完成${RESET}"
}

# 查看状态
status_service() {
    echo -e "${GREEN}目录结构:${RESET}"
    tree -L 2 $BASE_DIR
}

# 菜单
while true; do
    echo -e "${GREEN}======================${RESET}"
    echo -e "${GREEN} 1) 安装依赖 & 随机图片服务${RESET}"
    echo -e "${GREEN} 2) 卸载服务${RESET}"
    echo -e "${GREEN} 3) 查看状态${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    echo -e "${GREEN}======================${RESET}"
    read -p "请输入选项: " CHOICE
    case $CHOICE in
        1) install_dependencies; install_service ;;
        2) uninstall_service ;;
        3) status_service ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
done
