#!/bin/bash
# =========================================
# 一键部署/管理脚本（Debian 兼容）
# 带绿色菜单 + 自动续期检测 + 防浏览器访问 + DNS 检测 + 访问日志 + HTTP自动跳转HTTPS
# =========================================

WEB_ROOT="/var/www/html"
LOG_FILE="/var/log/nginx/tim_access.log"
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

show_menu() {
    clear
    echo -e "${GREEN}=========================================${RESET}"
    echo -e "${GREEN}            tim 脚本管理菜单             ${RESET}"
    echo -e "${GREEN}=========================================${RESET}"
    echo -e "${GREEN}1) 安装/部署脚本${RESET}"
    echo -e "${GREEN}2) 卸载/清除脚本${RESET}"
    echo -e "${GREEN}3) 升级/更新脚本${RESET}"
    echo -e "${GREEN}4) 查看拉取日志${RESET}"
    echo -e "${GREEN}5) 退出${RESET}"
    echo -e "${GREEN}=========================================${RESET}"
}

install_tim() {
    read -p "请输入你的域名： " DOMAIN
    read -p "请输入脚本 URL： " TIM_URL
    read -p "请输入你的邮箱（用于 HTTPS）： " EMAIL
    read -p "请输入 VPS 本地脚本存放目录（默认 /root/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/root/tim}

    echo -e "${GREEN}安装依赖: nginx, curl, certbot, dnsutils...${RESET}"
    apt update
    apt install -y nginx curl certbot python3-certbot-nginx dnsutils

    # 检查域名是否解析到本 VPS
    VPS_IP=$(curl -s https://ipinfo.io/ip)
    DOMAIN_IP=$(dig +short "$DOMAIN" | tail -n1)

    if [[ "$VPS_IP" != "$DOMAIN_IP" ]]; then
        echo -e "${RED}❌ 域名 $DOMAIN 没有解析到本 VPS 公网 IP $VPS_IP${RESET}"
        echo -e "${RED}请确认 DNS 指向后再运行安装脚本${RESET}"
        return
    else
        echo -e "${GREEN}✅ 域名解析正确，继续安装${RESET}"
    fi

    # 创建目录
    mkdir -p "$WEB_ROOT"
    mkdir -p "$LOCAL_DIR"
    chmod 700 "$LOCAL_DIR"

    # 下载 tim 脚本
    curl -fsSL "$TIM_URL" -o "$WEB_ROOT/tim.sh"
    chmod +x "$WEB_ROOT/tim.sh"
    cp "$WEB_ROOT/tim.sh" "$LOCAL_DIR/tim"

    # 配置 Nginx（HTTP → HTTPS 自动跳转）
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    # 所有 HTTP 请求重定向到 HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    root $WEB_ROOT;

    # HTTPS 证书路径（certbot 会自动配置）
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    # 日志文件（Debian 默认兼容格式）
    access_log $LOG_FILE combined;

    # 仅允许命令行工具访问
    location = / {
        if (\$http_user_agent ~* "(curl|wget|fetch|httpie|Go-http-client|python-requests|bash)") {
            default_type text/plain;
            alias $WEB_ROOT/tim.sh;
            break;
        }
        return 403;
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

    # 检查自动续期
    if systemctl list-timers | grep -q certbot.timer; then
        echo -e "${GREEN}✅ 证书自动续期已启用（certbot.timer 正常运行）${RESET}"
    else
        echo -e "${RED}❌ 未检测到 certbot.timer，请手动检查定时任务${RESET}"
    fi

    echo -e "${GREEN}==========================================${RESET}"
    echo -e "${GREEN}部署完成！${RESET}"
    echo -e "${GREEN}一键安装命令：${RESET}"
    echo -e "${GREEN}bash <(curl -sL https://$DOMAIN)${RESET}"
    echo -e "${GREEN}本地脚本已下载到：$LOCAL_DIR/tim${RESET}"
    echo -e "${GREEN}HTTPS 已启用 https://$DOMAIN${RESET}"
    echo -e "${GREEN}拉取日志文件路径：$LOG_FILE${RESET}"
    echo -e "${GREEN}==========================================${RESET}"
}

uninstall_tim() {
    read -p "请输入你的域名 ： " DOMAIN
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
    rm -f "$WEB_ROOT/tim.sh"

    echo -e "${GREEN}删除 HTTPS 证书...${RESET}"
    certbot delete --cert-name "$DOMAIN" --non-interactive || echo "证书可能不存在"

    echo -e "${GREEN}重启 Nginx...${RESET}"
    systemctl restart nginx

    echo -e "${GREEN}==========================================${RESET}"
    echo -e "${GREEN}卸载完成！${RESET}"
    echo -e "${GREEN}==========================================${RESET}"
}

update_tim() {
    read -p "请输入最新脚本 URL： " TIM_URL
    read -p "请输入 VPS 本地脚本存放目录（默认 /root/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/root/tim}

    echo -e "${GREEN}更新脚本...${RESET}"
    curl -fsSL "$TIM_URL" -o "$WEB_ROOT/tim.sh"
    chmod +x "$WEB_ROOT/tim.sh"
    cp "$WEB_ROOT/tim.sh" "$LOCAL_DIR/tim"

    echo -e "${GREEN}更新完成！网页和本地脚本已同步最新版本${RESET}"
}

view_logs() {
    if [ -f "$LOG_FILE" ]; then
        echo -e "${GREEN}显示最近 20 条脚本拉取记录：${RESET}"
        tail -n 20 "$LOG_FILE"
        echo -e "${GREEN}统计不同 IP 拉取次数：${RESET}"
        awk '{print $1}' "$LOG_FILE" | sort | uniq -c | sort -nr
    else
        echo -e "${RED}日志文件不存在${RESET}"
    fi
}

while true; do
    show_menu
    read -p "请选择操作 [1-5]：" choice
    case $choice in
        1) install_tim ;;
        2) uninstall_tim ;;
        3) update_tim ;;
        4) view_logs ;;
        5) exit 0 ;;
        *) echo -e "${RED}请输入有效选项 [1-5]${RESET}" ;;
    esac
    read -p "按回车返回菜单..."
done
