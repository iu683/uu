#!/bin/bash
# =========================================
# 一键部署/管理脚本（Debian/Ubuntu 兼容，IPv4+IPv6 双栈）
# HTTP 先行，HTTPS 自动申请
# 支持自动续期 + 防浏览器访问 + DNS 检测 + 访问日志
# =========================================

WEB_ROOT="/var/www/html"
LOG_FILE="/var/log/nginx/tim_access.log"
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

show_menu() {
    clear
    echo -e "${GREEN}=========================================${RESET}"
    echo -e "${GREEN}       vps短链脚本管理菜单                ${RESET}"
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
    read -p "请输入你的邮箱（用于 HTTPS）： " EMAIL
    read -p "请输入 VPS 本地脚本存放目录（默认 /root/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/root/tim}

    echo -e "${GREEN}安装依赖: nginx, curl, certbot, dnsutils...${RESET}"
    apt update
    apt install -y nginx curl certbot python3-certbot-nginx dnsutils

    # 检查域名解析 (IPv4 + IPv6)
    VPS_IPv4=$(curl -s4 https://ifconfig.co || true)
    VPS_IPv6=$(curl -s6 https://ifconfig.co || true)
    DOMAIN_A=$(dig +short A "$DOMAIN" | tail -n1)
    DOMAIN_AAAA=$(dig +short AAAA "$DOMAIN" | tail -n1)

    echo -e "${GREEN}VPS IPv4: $VPS_IPv4${RESET}"
    echo -e "${GREEN}VPS IPv6: $VPS_IPv6${RESET}"
    echo -e "${GREEN}域名 A 记录: $DOMAIN_A${RESET}"
    echo -e "${GREEN}域名 AAAA 记录: $DOMAIN_AAAA${RESET}"

    if [[ "$VPS_IPv4" == "$DOMAIN_A" || "$VPS_IPv6" == "$DOMAIN_AAAA" ]]; then
        echo -e "${GREEN}✅ 域名解析正确，继续安装${RESET}"
    else
        echo -e "${RED}❌ 域名 $DOMAIN 未解析到本 VPS 公网 IP${RESET}"
        echo -e "${RED}请确认 DNS 指向后再运行安装脚本${RESET}"
        return
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

    # 确保 Nginx sites-available/sites-enabled 存在
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled

    # 写入 Nginx 配置
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    root $WEB_ROOT;
    index index.html index.htm;

    location = / {
        if (\$http_user_agent !~* "(curl|wget|fetch|httpie|Go-http-client|python-requests|bash)") {
            add_header Content-Type text/html;
            return 200 '<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>Toolbox</title>
<style>
html, body { margin:0; padding:0; height:100%; }
body {
    background-image: url("https://t.alcy.cc/ycy");
    background-size: cover;
    background-position: center;
    background-repeat: no-repeat;
    display:flex; justify-content:center; align-items:center;
    font-family: Arial, sans-serif;
    transition: background 0.3s;
}
.card {
    backdrop-filter: blur(15px);
    -webkit-backdrop-filter: blur(15px);
    background: rgba(255, 255, 255, 0.4);
    border-radius: 20px;
    padding: 40px 60px;
    text-align:center;
    box-shadow: 0 8px 32px rgba(0,0,0,0.1);
    transition: background 0.3s, color 0.3s;
}
@media (prefers-color-scheme: dark) {
    html, body { background:#1e1e1e; }
    .card { background: rgba(40,40,40,0.6); color:#eee; box-shadow:0 8px 32px rgba(0,0,0,0.5); }
}
h1 { font-size:2.5rem; margin-bottom:20px; }
#cmd {
    font-size:1.5rem;
    font-weight:bold;
    background: rgba(255,255,255,0.25);
    padding:15px 25px;
    border-radius:12px;
    cursor:pointer;
    user-select:all;
    border:1px solid rgba(255,255,255,0.3);
    transition: background 0.3s, border 0.3s;
}
@media (prefers-color-scheme: dark) {
    #cmd { background: rgba(255,255,255,0.1); border:1px solid rgba(255,255,255,0.2); }
}
#hint { margin-top:15px; font-size:1rem; color:#555; }
@media (prefers-color-scheme: dark) { #hint { color:#ccc; } }
</style>
</head>
<body>
<div class="card">
<h1>🖱️ Toolbox工具箱</h1>
<div id="cmd">bash &lt;(curl -fsSL $DOMAIN)</div>
<div id="hint">点击命令即可复制到剪贴板</div>
</div>
<script>
const cmdDiv = document.getElementById("cmd");
cmdDiv.addEventListener("click", async () => {
    try {
        await navigator.clipboard.writeText(cmdDiv.innerText);
        cmdDiv.innerText = "✅ 已复制！";
        setTimeout(() => { cmdDiv.innerText = "bash <(curl -fsSL $DOMAIN)"; }, 1500);
    } catch(err) { alert("复制失败，请手动复制命令。"); }
});
</script>
</body>
</html>';
        }

        default_type text/plain;
        try_files /$DOMAIN =404;
    }

    access_log /var/log/nginx/tool_access.log combined;
}
EOF

    # 创建软链接
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

    # 测试并重载 Nginx
    nginx -t && systemctl reload nginx

    # HTTPS 申请
    echo -e "${GREEN}申请 HTTPS 证书...${RESET}"
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" || {
        echo -e "${RED}HTTPS 安装失败，请检查 DNS 或 Nginx 配置后重试${RESET}"
    }

    # 自动续期
    RENEW_SCRIPT="$LOCAL_DIR/renew_cert.sh"
    cat > "$RENEW_SCRIPT" <<EOF
#!/bin/bash
certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF
    chmod +x "$RENEW_SCRIPT"
    CRON_JOB="0 0,12 * * * $RENEW_SCRIPT >> /var/log/renew_cert.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "$RENEW_SCRIPT"; echo "$CRON_JOB") | crontab -

    echo -e "${GREEN}✅ 自动续期任务已设置，每天 0 点和 12 点检测证书${RESET}"

    echo -e "${GREEN}==========================================${RESET}"
    echo -e "${GREEN}部署完成！${RESET}"
    echo -e "${GREEN}本地脚本已保存到：$LOCAL_DIR/$DOMAIN${RESET}"
    echo -e "${GREEN}HTTPS 已启用 https://$DOMAIN${RESET}"
    echo -e "${GREEN}访问日志：/var/log/nginx/tool_access.log${RESET}"
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
