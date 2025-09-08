#!/bin/bash
# =========================================
# 一键部署/管理脚本（Debian/Ubuntu 兼容）
# IPv6 ONLY 模式
# 支持 HTTPS 自动申请 + 自动续期 + 防浏览器访问 + DNS 检测 + 访问日志
# =========================================

WEB_ROOT="/var/www/html"
LOG_FILE="/var/log/nginx/tim_access.log"
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

show_menu() {
    clear
    echo -e "${GREEN}=========================================${RESET}"
    echo -e "${GREEN}         tim IPv6-only 管理菜单          ${RESET}"
    echo -e "${GREEN}=========================================${RESET}"
    echo -e "${GREEN}1) 安装/部署脚本${RESET}"
    echo -e "${GREEN}2) 卸载/清除脚本${RESET}"
    echo -e "${GREEN}3) 升级/更新脚本${RESET}"
    echo -e "${GREEN}4) 查看访问日志${RESET}"
    echo -e "${GREEN}5) 退出${RESET}"
    echo -e "${GREEN}=========================================${RESET}"
}

install_tim() {
    read -p "请输入你的域名： " DOMAIN
    read -p "请输入脚本 URL（可选，留空默认不下载）： " TIM_URL
    read -p "请输入你的邮箱（用于 HTTPS）： " EMAIL
    read -p "请输入 VPS 本地脚本存放目录（默认 /root/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/root/tim}

    echo -e "${GREEN}安装依赖: nginx, curl, certbot, dnsutils...${RESET}"
    apt update
    apt install -y nginx curl certbot python3-certbot-nginx dnsutils

    # 检查域名 IPv6 解析
    VPS_IPv6=$(curl -s6 https://ifconfig.co)
    DOMAIN_AAAA=$(dig +short AAAA "$DOMAIN" | tail -n1)

    if [[ "$VPS_IPv6" != "$DOMAIN_AAAA" ]]; then
        echo -e "${RED}❌ 域名 $DOMAIN 没有解析到本 VPS IPv6 $VPS_IPv6${RESET}"
        echo -e "${RED}请确认 DNS AAAA 记录正确后再运行安装脚本${RESET}"
        return
    else
        echo -e "${GREEN}✅ 域名解析正确 (IPv6)，继续安装${RESET}"
    fi

    # 创建目录
    mkdir -p "$WEB_ROOT"
    mkdir -p "$LOCAL_DIR"
    chmod 700 "$LOCAL_DIR"

    # 下载脚本（可选）
    if [[ -n "$TIM_URL" ]]; then
        curl -fsSL "$TIM_URL" -o "$WEB_ROOT/$DOMAIN"
        chmod +x "$WEB_ROOT/$DOMAIN"
        cp "$WEB_ROOT/$DOMAIN" "$LOCAL_DIR/$DOMAIN"
    fi

    # 配置 Nginx 仅 IPv6
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    cat > "$NGINX_CONF" <<EOF
server {
    listen [::]:80;
    server_name $DOMAIN;

    root $WEB_ROOT;

    location = / {
        try_files /$DOMAIN =200;

        if (\$http_user_agent !~* "(curl|wget|fetch|httpie|Go-http-client|python-requests|bash)") {
            add_header Content-Type text/html;
            return 200 '<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>时钟 (IPv6 Only)</title>
<style>
html, body { margin:0; padding:0; height:100%; display:flex; justify-content:center; align-items:center; background:#f0f0f0; font-family:Arial,sans-serif; flex-direction:column;}
h1 { font-size:3rem; margin:0;}
#time { font-size:5rem; font-weight:bold; margin-top:20px;}
</style>
</head>
<body>
<h1>🌍 IPv6 世界时间</h1>
<div id="time"></div>
<script>
function updateTime() {
    const now = new Date();
    document.getElementById("time").innerText = now.toLocaleString();
}
setInterval(updateTime, 1000);
updateTime();
</script>
</body>
</html>';
        }
    }

    access_log $LOG_FILE combined;
}
EOF

    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    nginx -t && systemctl restart nginx

    # 申请 HTTPS (IPv6)
    echo -e "${GREEN}申请 HTTPS 证书...${RESET}"
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" || {
        echo -e "${RED}HTTPS 安装失败，请检查 DNS AAAA 或 Nginx 配置后重试${RESET}"
    }

    # 创建自动续期脚本
    RENEW_SCRIPT="/root/tim/renew_cert.sh"
    cat > "$RENEW_SCRIPT" <<EOF
#!/bin/bash
certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF
    chmod +x "$RENEW_SCRIPT"

    # 添加 cron 自动续期任务
    (crontab -l 2>/dev/null; echo "0 0,12 * * * $RENEW_SCRIPT >> /var/log/renew_cert.log 2>&1") | crontab -

    echo -e "${GREEN}✅ 自动续期任务已设置，每天 0 点和 12 点检测证书${RESET}"

    echo -e "${GREEN}==========================================${RESET}"
    echo -e "${GREEN}部署完成！(IPv6 only)${RESET}"
    echo -e "${GREEN}本地脚本已保存到：$LOCAL_DIR/$DOMAIN${RESET}"
    echo -e "${GREEN}HTTPS 已启用 https://$DOMAIN（如证书申请成功）${RESET}"
    echo -e "${GREEN}访问日志：$LOG_FILE${RESET}"
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
    rm -f "$WEB_ROOT/$DOMAIN"

    echo -e "${GREEN}删除 HTTPS 证书...${RESET}"
    certbot delete --cert-name "$DOMAIN" --non-interactive || echo "证书可能不存在"

    echo -e "${GREEN}重启 Nginx...${RESET}"
    systemctl restart nginx

    echo -e "${GREEN}==========================================${RESET}"
    echo -e "${GREEN}卸载完成！(IPv6 only)${RESET}"
    echo -e "${GREEN}==========================================${RESET}"
}

update_tim() {
    read -p "请输入最新脚本 URL： " TIM_URL
    read -p "请输入 VPS 本地脚本存放目录（默认 /root/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/root/tim}

    if [[ -z "$DOMAIN" ]]; then
        read -p "请输入域名（用于生成文件名）： " DOMAIN
    fi

    mkdir -p "$LOCAL_DIR"
    curl -fsSL "$TIM_URL" -o "$LOCAL_DIR/$DOMAIN" || { 
        echo -e "${RED}❌ 下载脚本失败，请检查 URL、权限或路径${RESET}"
        return
    }
    chmod +x "$LOCAL_DIR/$DOMAIN"

    cp -f "$LOCAL_DIR/$DOMAIN" "$WEB_ROOT/$DOMAIN"
    echo -e "${GREEN}✅ 更新完成！本地和网页脚本已同步最新版本${RESET}"
}

view_logs() {
    if [ -f "$LOG_FILE" ]; then
        echo -e "${GREEN}显示最近 20 条访问记录：${RESET}"
        tail -n 20 "$LOG_FILE"
        echo -e "${GREEN}统计不同 IP(IPv6) 访问次数：${RESET}"
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
