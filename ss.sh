#!/bin/bash
# 网站一键部署
WEB_ROOT="/var/www/clock_site"
NGINX_CONF_DIR="/etc/nginx/sites-available"
LOG_FILE="/var/log/nginx/clock_access.log"
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

install_site() {
    read -p "请输入你的自定义域名： " DOMAIN

    echo -e "${GREEN}正在检查并安装必要依赖(dnsutils/curl)...${RESET}"
    apt update
    apt install -y dnsutils curl

    # 检查域名解析 (仅限 IPv4)
    VPS_IPv4=$(curl -s4 https://ifconfig.co || true)
    DOMAIN_A=$(dig +short A "$DOMAIN" | tail -n1)

    echo -e "${GREEN}VPS IPv4: $VPS_IPv4${RESET}"
    echo -e "${GREEN}域名 A 记录: $DOMAIN_A${RESET}"

    if [[ -n "$VPS_IPv4" && "$VPS_IPv4" != "$DOMAIN_A" ]]; then
        echo -e "${RED}❌ A 记录未指向本机 IPv4${RESET}"
    fi
    
    if [[ "$VPS_IPv4" == "$DOMAIN_A" ]]; then
        echo -e "${GREEN}✅ IPv4 解析正确，继续配置${RESET}"
    else
        echo -e "${RED}❌ 域名未解析到本机，停止安装${RESET}"
        return
    fi

    # --- 自定义证书路径逻辑 ---
    DEFAULT_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    DEFAULT_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    echo -e "\n${GREEN}--- 证书路径配置 ---${RESET}"
    read -p "请输入证书路径 [默认: $DEFAULT_CERT]: " USER_CERT
    read -p "请输入私钥路径 [默认: $DEFAULT_KEY]: " USER_KEY

    # 如果用户直接回车，则使用默认预测路径
    CERT_PATH=${USER_CERT:-$DEFAULT_CERT}
    KEY_PATH=${USER_KEY:-$DEFAULT_KEY}
    # --------------------------

    mkdir -p "$WEB_ROOT"
    chmod 755 "$WEB_ROOT"

    # 默认 HTML 页面
    cat > "$WEB_ROOT/index.html" <<'EOF'
<!DOCTYPE html>
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
<h1>🌍世界时间</h1>
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
</html>
EOF

    # 写入 Nginx 配置
    NGINX_CONF="$NGINX_CONF_DIR/$DOMAIN"
    echo -e "${GREEN}正在写入/修改 Nginx 配置文件: $NGINX_CONF${RESET}"
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    
    # 强制 HTTP 跳转 HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    root $WEB_ROOT;
    index index.html;

    # 采用确定的证书与私钥路径
    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;

    # 基础 SSL 安全配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    access_log $LOG_FILE combined;
}
EOF

    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    
    # 检查并重载配置
    echo -e "${GREEN}正在测试 Nginx 配置并平滑重载...${RESET}"
    nginx -t && systemctl reload nginx

    echo -e "${GREEN}✅ HTML 网站配置修改完成！${RESET}"
    echo -e "${GREEN}页面路径：$WEB_ROOT/index.html${RESET}"
    echo -e "${GREEN}当前生效的证书路径：${RESET}"
    echo -e "   Certificate Path: $CERT_PATH"
    echo -e "   Private Key Path: $KEY_PATH"
    echo -e "${GREEN}访问：https://$DOMAIN${RESET}"
}

uninstall_site() {
    read -p "请输入要卸载的域名： " DOMAIN
    
    echo -e "${GREEN}正在清理 $DOMAIN 的 Nginx 配置...${RESET}"
    rm -f "$NGINX_CONF_DIR/$DOMAIN"
    rm -f /etc/nginx/sites-enabled/$DOMAIN
    rm -rf "$WEB_ROOT"
    
    # 仅仅重载 Nginx 使配置生效
    systemctl reload nginx
    echo -e "${GREEN}✅ HTML 时钟网站配置已卸载，Nginx 已平滑重载${RESET}"
}

edit_html() {
    ${EDITOR:-nano} "$WEB_ROOT/index.html"
    systemctl reload nginx
}

view_logs() {
    if [ -f "$LOG_FILE" ]; then
        tail -n 20 "$LOG_FILE"
        echo -e "\n统计不同 IP 访问次数："
        awk '{print $1}' "$LOG_FILE" | sort | uniq -c | sort -nr
    else
        echo -e "${RED}日志文件不存在${RESET}"
    fi
}

while true; do
    clear
    echo -e "${GREEN}=========================${RESET}"
    echo -e "${GREEN}    ◈  网站管理菜单  ◈   ${RESET}"
    echo -e "${GREEN}=========================${RESET}"
    echo -e "${GREEN}1) 部署网站${RESET}" 
    echo -e "${GREEN}2) 卸载网站${RESET}"
    echo -e "${GREEN}3) 编辑页面${RESET}"
    echo -e "${GREEN}4) 访问日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}=========================${RESET}"
    read -p "$(echo -e ${GREEN}请输入选项: ${RESET})" choice
    case $choice in
        1) install_site ;;
        2) uninstall_site ;;
        3) edit_html ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入有效选项${RESET}" ;;
    esac
    read -p "$(echo -e "${YELLOW}按回车返回菜单...${RESET}")"
done
