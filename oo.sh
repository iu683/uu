#!/bin/bash
# =========================================================
# 一键部署/管理脚本（去除 Nginx 安装与证书自动申请）
# 支持手动输入自定义 SSL 证书路径，兼容 IPv4+IPv6 双栈
# =========================================================

WEB_ROOT="/var/www/html"
LOG_FILE="/var/log/nginx/tim_access.log"
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

show_menu() {
    clear
    echo -e "${GREEN}=========================================${RESET}"
    echo -e "${GREEN}        vps短链脚本管理菜单                ${RESET}"
    echo -e "${GREEN}=========================================${RESET}"
    echo -e "${GREEN}1) 部署脚本${RESET}"
    echo -e "${GREEN}2) 卸载脚本${RESET}"
    echo -e "${GREEN}3) 更新脚本${RESET}"
    echo -e "${GREEN}4) 查看访问日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
}

install_tim() {
    read -p "请输入你的域名： " DOMAIN
    read -p "请输入脚本 URL（可选，留空默认不下载）： " TIM_URL
    
    echo -e "${GREEN}--- 请输入自定义 SSL 证书绝对路径 ---${RESET}"
    read -p "请输入证书文件路径 (如 /etc/acmessl/xxxx/cert.crt): " SSL_CERT
    read -p "请输入私钥文件路径 (如 /etc/acmessl/xxxx/private.key): " SSL_KEY
    
    read -p "请输入 VPS 本地脚本存放目录（默认 /root/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/root/tim}

    if [[ ! -f "$SSL_CERT" || ! -f "$SSL_KEY" ]]; then
        echo -e "${RED}❌ 错误: 找不到指定的证书或私钥文件，请检查路径是否正确！${RESET}"
        echo -e "${RED}当前输入 -> 证书: $SSL_CERT | 私钥: $SSL_KEY${RESET}"
        return
    fi

    mkdir -p "$WEB_ROOT"
    mkdir -p "$LOCAL_DIR"
    chmod 700 "$LOCAL_DIR"

    if [[ -n "$TIM_URL" ]]; then
        curl -fsSL "$TIM_URL" -o "$WEB_ROOT/$DOMAIN"
        chmod +x "$WEB_ROOT/$DOMAIN"
        cp "$WEB_ROOT/$DOMAIN" "$LOCAL_DIR/$DOMAIN"
    fi

    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;

    root $WEB_ROOT;

    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location = / {
        try_files /$DOMAIN =200;

        if (\$http_user_agent !~* "(curl|wget|fetch|httpie|Go-http-client|python-requests|bash)") {
            add_header Content-Type text/html;
            return 200 '<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>时钟</title>
<style>
html, body { margin:0; padding:0; height:100%; display:flex; justify-content:center; align-items:center; background:#f0f0f0; font-family:Arial,sans-serif; flex-direction:column;}
h1 { font-size:3rem; margin:0;}
#time { font-size:5rem; font-weight:bold; margin-top:20px;}
</style>
</head>
<body>
<h1>🌎世界时间</h1>
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

    echo -e "${GREEN}==========================================${RESET}"
    echo -e "${GREEN}部署完成！${RESET}"
    echo -e "${GREEN}本地脚本已保存到：$LOCAL_DIR/$DOMAIN${RESET}"
    echo -e "${GREEN}Nginx 已成功加载自定义证书并开启 443 监听。${RESET}"
    echo -e "${GREEN}访问日志：$LOG_FILE${RESET}"
    echo -e "${GREEN}==========================================${RESET}"
}

uninstall_tim() {
    read -p "请输入你的域名 ： " DOMAIN
    read -p "请输入 VPS 本地脚本存放目录（默认 /root/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/root/tim}

    echo -e "${GREEN}删除 Nginx 配置...${RESET}"
    rm -f /etc/nginx/sites-available/"$DOMAIN"
    rm -f /etc/nginx/sites-enabled/"$DOMAIN"

    echo -e "${GREEN}删除本地脚本...${RESET}"
    rm -rf "$LOCAL_DIR"

    echo -e "${GREEN}删除网页根目录脚本...${RESET}"
    rm -f "$WEB_ROOT/$DOMAIN"

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
        echo -e "${GREEN}统计不同 IP (IPv4/IPv6) 访问次数：${RESET}"
        awk '{print $1}' "$LOG_FILE" | sort | uniq -c | sort -nr
    else
        echo -e "${RED}日志文件不存在${RESET}"
    fi
}

while true; do
    show_menu
    read -p "$(echo -e ${GREEN}请输入选项: ${RESET})" choice
    case $choice in
        1) install_tim ;;
        2) uninstall_tim ;;
        3) update_tim ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入有效选项${RESET}" ;;
    esac
    read -p "按回车返回菜单..."
done
