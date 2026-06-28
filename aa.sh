#!/bin/bash
# 随机图片多路径 API 管理脚本

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

# 安装依赖 (仅安装 PHP 相关)
install_dependencies() {
    echo -e "${YELLOW}>>> 安装依赖 PHP + tree...${RESET}"
    apt update
    detect_php
    echo -e "${GREEN}>>> 检测到 PHP ${PHP_VERSION}${RESET}"
    apt install -y php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-common unzip curl tree
    systemctl enable --now php${PHP_VERSION}-fpm
}

# 刷新权限函数
refresh_permissions() {
    echo -e "${YELLOW}>>> 正在刷新图片目录权限...${RESET}"
    if [ -d "$BASE_DIR" ]; then
        chown -R www-data:www-data $BASE_DIR
        chmod -R 755 $BASE_DIR
        echo -e "${GREEN}>>> 权限刷新成功！${RESET}"
    else
        echo -e "${RED}>>> 基础目录 $BASE_DIR 不存在，无法刷新权限。${RESET}"
    fi
}

# 安装多路径随机图片服务并修改已有配置
install_service() {
    detect_php
    
    read -p "请输入已有网站的 Nginx 配置文件绝对路径 (如 /etc/nginx/sites-available/img.eu.org): " NGINX_CONF
    if [ ! -f "$NGINX_CONF" ]; then
        echo -e "${RED}文件不存在: $NGINX_CONF${RESET}"
        return
    fi

    # 检查是否已经注入过
    if grep -q "RANDOM IMAGE API START" "$NGINX_CONF"; then
        echo -e "${YELLOW}该配置文件已包含随机图片 API 配置，请勿重复安装。${RESET}"
        return
    fi

    # 创建基础目录和默认分类目录
    mkdir -p $BASE_DIR/images/random
    mkdir -p $BASE_DIR/images/random1
    mkdir -p $BASE_DIR/images/random2

    # 注入最新的无感降级、自带Debug天眼的 PHP 核心代码
    cat > $BASE_DIR/index.php <<'EOF'
<?php
$base_dir = __DIR__ . '/images/';
$request_uri = $_SERVER['REQUEST_URI'] ?? '/random';
$path_only = parse_url($request_uri, PHP_URL_PATH);

if (preg_match('/(random[0-9]*)/', $path_only, $matches)) {
    $path = $matches[1];
} else {
    $path = 'random';
}

$is_json = str_ends_with(strtolower($path_only), '.json');
$image_dir = $base_dir . $path . '/';

if (!is_dir($image_dir)) { 
    header("HTTP/1.1 200 OK");
    echo "<h3>❌ 【图片分类错误】物理文件夹不存在！</h3>";
    echo "系统尝试寻找的物理路径为: <code style='color:red'>" . htmlspecialchars($image_dir) . "</code><br><br>";
    echo "<b>解决办法：</b>请在服务器端创建该目录：<br>";
    echo "<pre style='background:#eee;padding:10px'>mkdir -p " . htmlspecialchars($image_dir) . "</pre>";
    exit;
}

$images = glob($image_dir . '*.{jpg,jpeg,png,gif,webp,JPG,JPEG,PNG,GIF,WEBP}', GLOB_BRACE);
$protocol = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? "https://" : "http://";
$host = $_SERVER['HTTP_HOST'] ?? 'localhost';

if (!empty($images)) {
    $random_image = $images[array_rand($images)];
    $image_url = $protocol . $host . '/images/' . $path . '/' . basename($random_image);
    if ($is_json) { 
        header('Content-Type: application/json; charset=utf-8'); 
        echo json_encode(["url" => $image_url], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE); 
        exit; 
    }
    $ext = strtolower(pathinfo($random_image,PATHINFO_EXTENSION));
    $mime_types=['jpg'=>'image/jpeg','jpeg'=>'image/jpeg','png'=>'image/png','gif'=>'image/gif','webp'=>'image/webp'];
    $mime=$mime_types[$ext]??'application/octet-stream';
    if (ob_get_level()) ob_end_clean();
    header("Content-Type: $mime"); header("Content-Length: ".filesize($random_image)); readfile($random_image); exit;
} else {
    header("HTTP/1.1 200 OK");
    echo "<h3>⚠️ 【图片分类错误】该分类文件夹下没有放入任何图片！</h3>";
    echo "当前检测的物理路径为: <code style='color:orange'>" . htmlspecialchars($image_dir) . "</code><br><br>";
    echo "<b>解决办法：</b>请将你的图片上传到上述路径中。";
    exit;
}
EOF

    # ==========================================
    # 【核心修改】提取 Nginx 文件名，并安全备份到 /tmp
    # ==========================================
    CONF_NAME=$(basename "$NGINX_CONF")
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    TEMP_BAK="/tmp/${CONF_NAME}_bak_${TIMESTAMP}"
    
    cp "$NGINX_CONF" "$TEMP_BAK"
    echo -e "${YELLOW}>>> 已将原配置安全备份至: ${TEMP_BAK}${RESET}"

    echo -e "${YELLOW}>>> 正在无损注入专属全量接管路由配置...${RESET}"

    # 注入全新的通用 try_files 规则，从根本上杜绝 404
    awk -v sock="$PHP_FPM_SOCK" -v base="$BASE_DIR" '
    /server_name/ && !done {
        print $0
        print ""
        print "    # === RANDOM IMAGE API START ==="
        print "    # 以下是由脚本自动注入的专属全量路由接管配置"
        print "    location = /favicon.ico {"
        print "        log_not_found off;"
        print "        access_log off;"
        print "        return 404;"
        print "    }"
        print "    location /images/ {"
        print "        expires 30d;"
        print "        add_header Cache-Control \"public, no-transform\";"
        print "    }"
        print "    location / {"
        print "        try_files $uri $uri/ /index.php?$query_string;"
        print "    }"
        print "    location ~ \\.php$ {"
        print "        include snippets/fastcgi-php.conf;"
        print "        fastcgi_pass unix:" sock ";"
        print "        fastcgi_param SCRIPT_FILENAME " base "$fastcgi_script_name;"
        print "        fastcgi_param REQUEST_URI $request_uri;"
        print "    }"
        print "    # === RANDOM IMAGE API END ==="
        done = 1
        next
    }
    { print }
    ' "$TEMP_BAK" > "$NGINX_CONF"

    # 统一刷新一下权限
    refresh_permissions

    # 测试并重启 Nginx
    if nginx -t; then
        systemctl restart nginx
        echo -e "${GREEN}API 成功全量接入当前网站！${RESET}"
        echo -e "原配置安全存放在: ${GREEN}${TEMP_BAK}${RESET}"
        echo -e "分类访问示例: ${YELLOW}https://你的域名${RESET}"
        echo -e "分类访问示例: ${YELLOW}https://你的域名/random1${RESET}"
        echo -e "分类 JSON 示例: ${YELLOW}https://你的域名/random1.json${RESET}"
    else
        echo -e "${RED}Nginx 配置检查失败！正在从 /tmp 自动还原原始配置...${RESET}"
        cp "$TEMP_BAK" "$NGINX_CONF"
        systemctl restart nginx
        echo -e "${YELLOW}已成功恢复原配置，请检查已有 Nginx 配置文件。${RESET}"
    fi
}

# 卸载 (无损恢复已有的 Nginx 配置并清理文件)
uninstall_service() {
    read -p "请输入已有网站的 Nginx 配置文件绝对路径: " NGINX_CONF
    if [ ! -f "$NGINX_CONF" ]; then
        echo -e "${RED}文件不存在: $NGINX_CONF${RESET}"
        return
    fi

    # 卸载前同样做好备份
    CONF_NAME=$(basename "$NGINX_CONF")
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    TEMP_BAK="/tmp/${CONF_NAME}_before_uninstall_${TIMESTAMP}"
    cp "$NGINX_CONF" "$TEMP_BAK"
    echo -e "${YELLOW}>>> 卸载前已将当前配置备份至: ${TEMP_BAK}${RESET}"

    echo -e "${YELLOW}>>> 正在移除 Nginx 中的 API 配置...${RESET}"
    # 移除标记之间的所有内容
    sed -i '/# === RANDOM IMAGE API START ===/,/# === RANDOM IMAGE API END ===/d' "$NGINX_CONF"

    # 删除图片及代码文件
    rm -rf $BASE_DIR

    if nginx -t; then
        systemctl restart nginx
        echo -e "${GREEN}卸载完成，Nginx 配置已无损恢复。${RESET}"
    else
        echo -e "${RED}Nginx 配置异常！正在从 /tmp 还原备份...${RESET}"
        cp "$TEMP_BAK" "$NGINX_CONF"
        systemctl restart nginx
    fi
}

# 查看状态
status_service() {
    echo -e "${GREEN}目录结构:${RESET}"
    if [ -d "$BASE_DIR" ]; then
        if command -v tree >/dev/null 2>&1; then
            tree -L 3 $BASE_DIR
        else
            ls -R $BASE_DIR
        fi
    else
        echo -e "${RED}服务未安装，基础目录 $BASE_DIR 不存在${RESET}"
    fi
}

# 菜单循环
while true; do
    clear
    # 动态检测是否安装了服务
    if [ -d "$BASE_DIR/images" ]; then
        STATUS_TEXT="${YELLOW}[已安装]${RESET}"
    else
        STATUS_TEXT="${RED}[未安装]${RESET}"
    fi
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈   随机图片 API   ◈      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}当前状态: ${STATUS_TEXT}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1) 安装服务${RESET}"
    echo -e "${GREEN} 2) 卸载服务${RESET}"
    echo -e "${GREEN} 3) 查看状态${RESET}"
    echo -e "${GREEN} 4) 仅刷新图片目录权限${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    read -p "$(echo -e ${GREEN}请输入选项: ${RESET})" CHOICE
    
    case $CHOICE in
        1) install_dependencies; install_service ;;
        2) uninstall_service ;;
        3) status_service ;;
        4) refresh_permissions ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
    
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
