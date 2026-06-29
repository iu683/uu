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



# 获取当前生效的配置信息与安装状态
INSTALL_STATUS="未安装"
CURRENT_DOMAIN="无"
CURRENT_CERT="无"
CURRENT_KEY="无"

get_current_status() {
    # 1. 严格只判断目录是否存在
    if [ -d "$WEB_ROOT" ]; then
        INSTALL_STATUS="已安装"
        
        # 2. 提取 Nginx 中启用的文件名作为域名 (清除异常换行符)
        local find_domain
        find_domain=$(ls /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "default" | head -n 1 | tr -d '\r\n ')
        
        if [ -n "$find_domain" ]; then
            CURRENT_DOMAIN="$find_domain"
            # 3. 静态安全读取，如果文件存在则直接显示，避免去读取 Nginx 内部造成终端冲突
            if [ -f "$NGINX_CONF_DIR/$find_domain" ]; then
                CURRENT_CERT=$(sed -n 's/^\s*ssl_certificate\s\+\([^;]\+\);.*/\1/p' "$NGINX_CONF_DIR/$find_domain" | tr -d '\r\n ' | head -n 1)
                CURRENT_KEY=$(sed -n 's/^\s*ssl_certificate_key\s\+\([^;]\+\);.*/\1/p' "$NGINX_CONF_DIR/$find_domain" | tr -d '\r\n ' | head -n 1)
            fi
        else
            CURRENT_DOMAIN="本地目录存在(未绑定域名)"
            CURRENT_CERT="无"
            CURRENT_KEY="无"
        fi
    else
        INSTALL_STATUS="未安装"
        CURRENT_DOMAIN="无"
        CURRENT_CERT="无"
        CURRENT_KEY="无"
    fi

    # 兜底清理空变量
    [ -z "$CURRENT_CERT" ] && CURRENT_CERT="无"
    [ -z "$CURRENT_KEY" ] && CURRENT_KEY="无"
}

install_site() {
    read -p "请输入你的自定义域名： " DOMAIN

    echo -e "${GREEN}正在检查并安装必要依赖(dnsutils/curl)...${RESET}"
    apt update
    apt install -y dnsutils curl

    # 检查域名解析 (仅限 IPv4)
    VPS_IPv4=$(get_public_ip)
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
    echo -e "${GREEN}=========================${RESET}"
    echo -e "${GREEN}    ◈  网站管理菜单  ◈   ${RESET}"
    echo -e "${GREEN}=========================${RESET}"
    echo -e "${GREEN} 运行状态 : ${RESET}$COLOR_STATUS"
    echo -e "${GREEN} 网页文件 : ${RESET}${WEB_ROOT}/index.html"
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
