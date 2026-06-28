#!/bin/bash
# =========================================
# 一键部署/管理脚本
# =========================================

WEB_ROOT="/var/www/html"
LOG_FILE="/var/log/nginx/tim_access.log"
GREEN='\033[0;32m'
YELLOW="\033[33m"
RED='\033[0;31m'
RESET='\033[0m'

# ✨ 终极双栈/纯v6 智能 IP 获取引擎
get_public_ip() {
    local mode=${1:-"v4"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        # 强制获取 IPv4
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        # 强制获取 IPv6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        # auto 模式：双栈环境优先获取 IPv4 (更适合大众网络)，纯 v6 环境自动fallback到 v6
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        # 如果获取 v4 失败，说明可能是纯 v6 机器，尝试获取 v6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    # 兜底处理：所有接口都失败时，直接输出 127.0.0.1，不报错
    echo "127.0.0.1" && return 0
}

# 动态检查服务部署状态
check_status() {
    # 检查 Nginx 启用的站点目录中是否存在任何短链配置
    if [ -d "/etc/nginx/sites-enabled" ] && [ "$(ls -A /etc/nginx/sites-enabled 2>/dev/null)" ]; then
        # 进一步确认这些启用的配置里是否包含咱们脚本特有的伪装短链标识
        if grep -q "http_user_agent" /etc/nginx/sites-enabled/* 2>/dev/null; then
            echo -e "${YELLOW}[已部署]${RESET}"
            return
        fi
    fi
    echo -e "${RED}[未部署]${RESET}"
}


show_menu() {
    clear
    local STATUS_TEXT=$(check_status)
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}   ◈ vps短链脚本 管理菜单◈    ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}当前状态: ${STATUS_TEXT}${RESET}"
    echo -e "${GREEN}1) 部署脚本${RESET}"
    echo -e "${GREEN}2) 卸载脚本${RESET}"
    echo -e "${GREEN}3) 更新脚本${RESET}"
    echo -e "${GREEN}4) 查看访问日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
}

install_tim() {
    read -p "请输入你的域名： " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}❌ 域名不能为空！${RESET}"
        return
    fi

    read -p "请输入脚本 URL（例如:https://raw.githubusercontent.com/gos/gost/refs/heads/main/gost.sh）： " TIM_URL
    read -p "请输入 VPS 本地脚本存放目录（默认 /etc/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/etc/tim}

    # 根据域名自动预测 Let's Encrypt 默认路径
    PREDICT_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    PREDICT_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    echo -e "${GREEN}--- 证书路径配置（直接回车使用域名预测路径） ---${RESET}"
    read -p "证书文件路径 [默认: $PREDICT_CERT]: " CERT_PATH
    CERT_PATH=${CERT_PATH:-$PREDICT_CERT}

    read -p "私钥文件路径 [默认: $PREDICT_KEY]: " KEY_PATH
    KEY_PATH=${KEY_PATH:-$PREDICT_KEY}

    if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
        echo -e "${RED}❌ 错误：在指定路径未找到证书或私钥文件！${RESET}"
        return
    fi

    echo -e "${GREEN}安装基础依赖: curl, dnsutils...${RESET}"
    apt update && apt install -y curl dnsutils

    # 检查域名解析 (仅 IPv4)
    VPS_IPv4=$(get_public_ip)
    DOMAIN_A=$(dig +short A "$DOMAIN" | tail -n1)

    echo -e "${GREEN}VPS IPv4: $VPS_IPv4${RESET}"
    echo -e "${GREEN}域名 A 记录: $DOMAIN_A${RESET}"

    if [[ "$VPS_IPv4" == "$DOMAIN_A" ]]; then
        echo -e "${GREEN}✅ 域名解析正确${RESET}"
    else
        echo -e "${RED}❌ 域名 $DOMAIN 未解析到本 VPS 公网 IPv4 地址${RESET}"
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

    # 配置 Nginx 站点（纯 IPv4 监听）
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root $WEB_ROOT;

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
    
    if nginx -t; then
        systemctl reload nginx
        echo -e "${GREEN}✅ Nginx 配置重载成功！${RESET}"
    else
        echo -e "${RED}❌ Nginx 配置有误，请检查！${RESET}"
        return
    fi

    echo -e "${GREEN}==========================================${RESET}"
    echo -e "${GREEN}部署完成！${RESET}"
    echo -e "${GREEN}使用证书：$CERT_PATH${RESET}"
    echo -e "${GREEN}访问网址：https://$DOMAIN${RESET}"
    echo -e "${GREEN}使用命令：bash <(curl -fsSL $DOMAIN)${RESET}"
    echo -e "${GREEN}==========================================${RESET}"
}

uninstall_tim() {
    read -p "请输入你的域名 ： " DOMAIN
    read -p "请输入 VPS 本地脚本存放目录（默认 /etc/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/etc/tim}

    rm -f /etc/nginx/sites-available/"$DOMAIN"
    rm -f /etc/nginx/sites-enabled/"$DOMAIN"
    rm -rf "$LOCAL_DIR"
    rm -f "$WEB_ROOT/$DOMAIN"

    systemctl reload nginx
    echo -e "${GREEN}卸载完成！${RESET}"
}

update_tim() {
    read -p "请输入最新脚本 URL： " TIM_URL
    if [[ -z "$TIM_URL" ]]; then
        echo -e "${RED}❌ 脚本 URL 不能为空！${RESET}"
        return
    fi

    read -p "请输入 VPS 本地脚本存放目录（默认 /etc/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/etc/tim}

    read -p "请输入你的域名（用于确定文件名）： " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}❌ 域名不能为空！${RESET}"
        return
    fi

    mkdir -p "$LOCAL_DIR"
    echo -e "${GREEN}正在下载最新脚本...${RESET}"
    curl -fsSL "$TIM_URL" -o "$LOCAL_DIR/$DOMAIN" || {
        echo -e "${RED}❌ 下载失败，请检查 URL！${RESET}"
        return
    }
    chmod +x "$LOCAL_DIR/$DOMAIN"
    
    cp -f "$LOCAL_DIR/$DOMAIN" "$WEB_ROOT/$DOMAIN"
    echo -e "${GREEN}✅ 脚本已同步更新至最新版本！${RESET}"
}

view_logs() {
    if [ -f "$LOG_FILE" ]; then
        tail -n 20 "$LOG_FILE"
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
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
