#!/bin/bash
# =================================================================
# BBS1ORG 论坛原生环境自建安装管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

TARGET_DIR="/var/www/bbs1org"
# 统一管理 Nginx 配置目录路径
NGINX_CONF_DIR="/etc/nginx/sites-available"
NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"

# 检测基础依赖
check_dependencies() {
    if ! command -v git &> /dev/null; then
        echo -e "${RED}错误: 未检测到 git，请先安装 git！(apt install git 或 yum install git)${RESET}"
        exit 1
    fi
}

# 获取公网 IP (兼容双栈环境)
get_public_ip() {
    local mode=${1:-"auto"} local ip=""
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
}

# 智能探测本地 PHP-FPM 的监听位置
detect_php_fpm() {
    echo -e "${YELLOW}🔍 正在智能探测系统 PHP-FPM 配置...${RESET}"
    
    # 1. 尝试从原生配置文件里抓取真实监听路径
    local grep_listen=""
    grep_listen=$(grep -R "listen =" /etc/php* 2>/dev/null | grep -v ";" | head -n 1)
    
    if [[ "$grep_listen" =~ /run/.*\.sock ]]; then
        # 匹配到了套接字路径 (如 /run/php/php8.3-fpm.sock)
        PHP_PASS="unix:$(echo "$grep_listen" | awk -F'= ' '{print $2}')"
    elif [[ "$grep_listen" =~ [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+ ]]; then
        # 匹配到了端口 (如 127.0.0.1:9000)
        PHP_PASS="$(echo "$grep_listen" | awk -F'= ' '{print $2}')"
    else
        # 2. 如果没抓到配置，直接去文件系统里搜寻存在的 sock 文件作为备选
        local find_sock=""
        find_sock=$(find /run/php/ -name "php*-fpm.sock" 2>/dev/null | head -n 1)
        if [[ -n "$find_sock" ]]; then
            PHP_PASS="unix:$find_sock"
        else
            # 3. 兜底策略，默认端口
            PHP_PASS="127.0.0.1:9000"
        fi
    fi
    echo -e "${GREEN}✅ 成功捕获 PHP 后端转发目标: ${PHP_PASS}${RESET}"
}

# 动态获取本地运行状态
get_status_info() {
    if [ -d "$TARGET_DIR" ]; then
        status_dir="${GREEN}已创建 (${TARGET_DIR})${RESET}"
    else
        status_dir="${RED}未创建${RESET}"
    fi

    if command -v nginx &> /dev/null && systemctl is-active --quiet nginx; then
        status_nginx="${GREEN}运行中${RESET}"
    else
        status_nginx="${RED}未运行/未安装${RESET}"
    fi
}

# 执行自建安装
install_app() {
    check_dependencies
    
    echo -e "${CYAN}====== 开始自建环境安装 ======${RESET}"
    
    # 1. 克隆源码
    if [ ! -d "$TARGET_DIR" ]; then
        echo -e "${YELLOW}📡 正在克隆源码到 ${TARGET_DIR} ...${RESET}"
        mkdir -p /var/www
        git clone https://github.com/bbs1org/bbs1org.git "$TARGET_DIR"
    else
        echo -e "${GREEN}✅ 目标目录已存在，跳过克隆。${RESET}"
    fi

    # 2. 创建目录并赋予权限
    echo -e "${YELLOW}🔧 正在创建 data 和 cache 目录并设置 Web 权限...${RESET}"
    cd "$TARGET_DIR" || exit
    mkdir -p data cache
    
    local web_user="www-data"
    if id "nginx" &>/dev/null; then web_user="nginx"; fi
    
    chown -R "$web_user:$web_user" data cache
    chmod -R 755 data cache
    echo -e "${GREEN}✅ 权限归属已设置为: ${web_user}${RESET}"

    # 3. 智能探测 PHP
    detect_php_fpm

    # 4. 域名核心输入逻辑
    read -p "$(echo -e "${GREEN}请输入你的自定义域名：${RESET}")" DOMAIN
    
    mkdir -p "$NGINX_CONF_DIR" "$NGINX_ENABLED_DIR"

    # --- 自定义证书路径逻辑 ---
    DEFAULT_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    DEFAULT_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    echo -e "\n${GREEN}--- 证书路径配置 ---${RESET}"
    read -p "$(echo -e "${GREEN}请输入证书路径 [默认: $DEFAULT_CERT]: ${RESET}")" USER_CERT
    read -p "$(echo -e "${GREEN}请输入私钥路径 [默认: $DEFAULT_KEY]: ${RESET}")" USER_KEY

    # 如果用户直接回车，则使用默认预测路径
    CERT_PATH=${USER_CERT:-$DEFAULT_CERT}
    KEY_PATH=${USER_KEY:-$DEFAULT_KEY}
    # --------------------------

    # 5. 动态写入 Nginx 站点配置文件
    echo -e "${YELLOW}📝 正在生成 Nginx 站点配置文件...${RESET}"
    
    cat <<EOF > "${NGINX_CONF_DIR}/${DOMAIN}"
server {
    listen 80;
    server_name ${DOMAIN};
    # 强制将所有 HTTP 请求重定向到 HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};
    root ${TARGET_DIR};
    index index.php;

    # SSL 证书配置
    ssl_certificate ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # 安全拦截规则：禁止公网访问 SQLite 数据库
    location ^~ /data/ {
        deny all;
    }

    # 安全拦截规则：禁止公网访问缓存目录
    location ^~ /cache/ {
        deny all;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass ${PHP_PASS}; 
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

    # 创建 Nginx 启用软链接
    ln -sf "${NGINX_CONF_DIR}/${DOMAIN}" "${NGINX_ENABLED_DIR}/"
    
    # 6. 检查并重载配置
    echo -e "${GREEN}正在测试 Nginx 配置并平滑重载...${RESET}"
    if nginx -t; then
        systemctl reload nginx
        echo -e "${GREEN}✅ Nginx 配置加载成功并已成功重载服务！${RESET}"
    else
        echo -e "${RED}❌ Nginx 配置测试失败，请检查上面输出的错误原因或确保证书路径正确！${RESET}"
    fi

    # 7. 完成提示
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN}        BBS1ORG 论坛站点配置完成！                ${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW}🌐 访问以下链接开始安装并在后台绑定域名:${RESET}"
    echo -e "${GREEN}👉 https://${DOMAIN}/install.php${RESET}"
    echo -e "${RED}🔒 安全生效: data/ 和 cache/ 在 Nginx 规则中已被拒绝访问。${RESET}"
    echo -e "${GREEN}================================================${RESET}"
}

# 更新源码
update_app() {
    if [ -d "$TARGET_DIR/.git" ]; then
        echo -e "${YELLOW}🔄 正在同步 GitHub 最新源码...${RESET}"
        cd "$TARGET_DIR" && git pull
        echo -e "${GREEN}✅ 源码更新成功！${RESET}"
    else
        echo -e "${RED}错误: 未检测到 Git 仓库项目，请先执行选项 1 部署！${RESET}"
    fi
}

# 卸载功能
uninstall_app() {
    echo -e "${RED}警告：正在执行卸载流程！${RESET}"
    echo -ne "${YELLOW}是否同时彻底删除论坛源码和全部数据库数据 (${TARGET_DIR})？(y/n): ${RESET}"
    read -r clean_data
    if [[ "$clean_data" == "y" || "$clean_data" == "Y" ]]; then
        rm -rf "$TARGET_DIR"
        echo -e "${GREEN}✅ 论坛所有本地网页和数据库文件已彻底清理。${RESET}"
    fi

    echo -e "${GREEN}🎉 域名为 ${UNINSTALL_DOMAIN} 的站点卸载完成！${RESET}"
}

# 查看本地日志
view_logs() {
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}选择查看本地服务日志:${RESET}"
    echo -e "${GREEN}1) Nginx 错误日志 (Error Log)${RESET}"
    echo -e "${GREEN}2) Nginx 访问日志 (Access Log)${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请选择 [1-2]: ${RESET}"
    read -r c
    case $c in
        1) tail -n 100 -f /var/log/nginx/error.log 2>/dev/null || echo -e "${RED}日志文件不存在${RESET}" ;;
        2) tail -n 100 -f /var/log/nginx/access.log 2>/dev/null || echo -e "${RED}日志文件不存在${RESET}" ;;
        *) echo -e "${RED}无效选择${RESET}" ;;
    esac
}

# 主菜单交互
menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} ◈  BBS1ORG 原生自建管理面板  ◈ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}源码目录 :${RESET} $status_dir"
    echo -e "${GREEN}环境状态 : Nginx -> $status_nginx"
    echo -e "${GREEN}配置目录 :${RESET} ${CYAN}${NGINX_CONF_DIR}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署论坛站点${RESET}"
    echo -e "${GREEN}2. 更新论坛源码${RESET}"
    echo -e "${GREEN}3. 卸载论坛站点${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        7) view_logs ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
