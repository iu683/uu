#!/bin/bash
# 网站一键部署
WEB_ROOT="/var/www/clock_site"
NGINX_CONF_DIR="/etc/nginx/sites-available"
LOG_FILE="/var/log/nginx/clock_access.log"
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'


get_public_ip() {
    local mode=${1:-"v4"}
    local ip=""
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
    echo "127.0.0.1"
}



install_site() {

    read -p "$(echo -e "${GREEN}请输入你的自定义域名：${RESET}")" DOMAIN
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

    echo -e "${GREEN}=========================${RESET}"
    echo -e "${GREEN}✅ HTML 网站部署完成！${RESET}"
    echo -e "${YELLOW}页面路径：$WEB_ROOT/index.html${RESET}"
    echo -e "${YELLOW}访问：https://$DOMAIN${RESET}"
    echo -e "${GREEN}=========================${RESET}"
}

uninstall_site() {
    read -p "请输入要卸载的域名： " DOMAIN
    
    echo -e "${GREEN}正在清理配置...${RESET}"
  
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
    # 根据目录是否存在判断状态
    if [ -d "$WEB_ROOT" ]; then
        COLOR_STATUS="${YELLOW}已安装${RESET}"
    else
        COLOR_STATUS="${RED}未安装${RESET}"
    fi
    echo -e "${GREEN}=========================${RESET}"
    echo -e "${GREEN}    ◈  网站管理菜单  ◈   ${RESET}"
    echo -e "${GREEN}=========================${RESET}"
    echo -e "${GREEN} 运行状态 :${RESET} $COLOR_STATUS"
    echo -e "${GREEN} 网页文件 :${RESET} ${YELLOW}${WEB_ROOT}/index.html${RESET}"
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
