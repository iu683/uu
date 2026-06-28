#!/bin/bash
# 随机图片多路径 API 管理脚本 (无损接入已有 Nginx 版)

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

BASE_DIR="/var/www/random"
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

# 安装依赖 (仅安装 PHP 相关，不再安装 Nginx 和 Certbot)
install_dependencies() {
    echo -e "${YELLOW}>>> 安装依赖 PHP + tree...${RESET}"
    apt update
    detect_php
    echo -e "${GREEN}>>> 检测到 PHP ${PHP_VERSION}${RESET}"
    apt install -y php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-common unzip curl tree
    systemctl enable --now php${PHP_VERSION}-fpm
}

# 安装多路径随机图片服务并修改已有配置
install_service() {
    detect_php
    
    read -p "请输入已有网站的 Nginx 配置文件绝对路径 (如 /etc/nginx/sites-enabled/default): " NGINX_CONF
    if [ ! -f "$NGINX_CONF" ]; then
        echo -e "${RED}文件不存在: $NGINX_CONF${RESET}"
        exit 1
    fi

    # 检查是否已经注入过
    if grep -q "RANDOM IMAGE API START" "$NGINX_CONF"; then
        echo -e "${YELLOW}该配置文件已包含随机图片 API 配置，请勿重复安装。${RESET}"
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

    # 备份原 Nginx 配置
    cp "$NGINX_CONF" "${NGINX_CONF}.bak"

    echo -e "${YELLOW}>>> 正在无损注入反向代理与路由配置...${RESET}"

    # 使用 awk 在第一个遇到的 server_name 后面追加配置
    awk -v sock="$PHP_FPM_SOCK" -v base="$BASE_DIR" '
    /server_name/ && !done {
        print $0
        print ""
        print "    # === RANDOM IMAGE API START ==="
        print "    # 以下是由脚本自动注入的随机图片精准路由配置"
        print "    location /images/ {"
        print "        root " base ";"
        print "    }"
        print "    location ~ ^/random([0-9]*)(|\\.json)$ {"
        print "        root " base ";"
        print "        include snippets/fastcgi-php.conf;"
        print "        fastcgi_pass unix:" sock ";"
        print "        fastcgi_param SCRIPT_FILENAME " base "/index.php;"
        print "    }"
        print "    # === RANDOM IMAGE API END ==="
        done = 1
        next
    }
    { print }
    ' "${NGINX_CONF}.bak" > "$NGINX_CONF"

    # 测试并重载 Nginx
    if nginx -t; then
        systemctl reload nginx
        echo -e "${GREEN}API 成功接入已有网站！${RESET}"
        echo -e "原配置已备份至: ${YELLOW}${NGINX_CONF}.bak${RESET}"
        echo -e "访问示例: ${YELLOW}https://你的域名/random${RESET}"
        echo -e "访问 JSON: ${YELLOW}https://你的域名/random.json${RESET}"
        echo -e "多路径目录: ${GREEN}${BASE_DIR}/images/random*, 例如 random1, random2${RESET}"
    else
        echo -e "${RED}Nginx 配置检查失败！正在自动还原备份...${RESET}"
        mv "${NGINX_CONF}.bak" "$NGINX_CONF"
        systemctl reload nginx
        echo -e "${YELLOW}已成功恢复原配置，请检查已有 Nginx 配置文件。${RESET}"
    fi
}

# 卸载 (无损恢复已有的 Nginx 配置并清理文件)
uninstall_service() {
    read -p "请输入已有网站的 Nginx 配置文件绝对路径: " NGINX_CONF
    if [ ! -f "$NGINX_CONF" ]; then
        echo -e "${RED}文件不存在: $NGINX_CONF${RESET}"
        exit 1
    fi

    echo -e "${YELLOW}>>> 正在移除 Nginx 中的 API 配置...${RESET}"
    # 移除标记之间的所有内容
    sed -i '/# === RANDOM IMAGE API START ===/,/# === RANDOM IMAGE API END ===/d' "$NGINX_CONF"

    # 删除图片及代码文件
    rm -rf $BASE_DIR

    if nginx -t; then
        systemctl reload nginx
        echo -e "${GREEN}卸载完成，Nginx 配置已无损恢复。${RESET}"
    else
        echo -e "${RED}Nginx 配置异常，请手动检查 $NGINX_CONF${RESET}"
    fi
}

# 查看状态
status_service() {
    echo -e "${GREEN}目录结构:${RESET}"
    if command -v tree >/dev/null 2>&1; then
        tree -L 2 $BASE_DIR
    else
        ls -R $BASE_DIR
    fi
}

# 菜单
while true; do
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈ 随机图片API ◈           ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1) 安装服务${RESET}"
    echo -e "${GREEN} 2) 卸载服务${RESET}"
    echo -e "${GREEN} 3) 查看状态${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    read -p "$(echo -e ${GREEN}请输入选项: ${RESET})" CHOICE
    case $CHOICE in
        1) install_dependencies; install_service ;;
        2) uninstall_service ;;
        3) status_service ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
done
