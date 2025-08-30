#!/bin/bash
# =========================================
# 一键部署 脚本（HTTPS + 根路径访问 + 自动下载）
# 支持自定义域名、tim URL 和邮箱
# =========================================

# ----- 用户输入 -----
read -p "请输入你的域名： " DOMAIN
read -p "请输入脚本 URL： " TIM_URL
read -p "请输入你的邮箱（用于 Let's Encrypt HTTPS 证书）： " EMAIL
read -p "请输入 VPS 上本地存放 tim 脚本的目录（默认 /root/tim）： " LOCAL_DIR
LOCAL_DIR=${LOCAL_DIR:-/root/tim}

WEB_ROOT="/var/www/html"

# ----- 安装依赖 -----
echo "安装依赖: nginx, curl, certbot..."
apt update
apt install -y nginx curl certbot python3-certbot-nginx

# ----- 下载 tim 脚本到根目录供访问 -----
mkdir -p "$WEB_ROOT"
curl -fsSL "$TIM_URL" -o "$WEB_ROOT/index.sh"
chmod +x "$WEB_ROOT/index.sh"

# ----- 配置 Nginx 根路径访问 -----
cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root $WEB_ROOT;

    location / {
        default_type text/plain;
        try_files /index.sh =404;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# ----- 自动申请 HTTPS -----
echo "申请 HTTPS 证书..."
# 使用 --pre-hook 确保 Nginx 配置正确再申请证书
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" || {
    echo "HTTPS 安装失败，请检查 Nginx 配置或 DNS 指向后重试："
    echo "certbot install --cert-name $DOMAIN"
}

# ----- 自动下载脚本到 VPS 本地目录 -----
echo "自动下载 tim 脚本到本地目录 $LOCAL_DIR ..."
mkdir -p "$LOCAL_DIR"
chmod 700 "$LOCAL_DIR"
curl -fsSL "$TIM_URL" -o "$LOCAL_DIR/tim"
chmod +x "$LOCAL_DIR/tim"

# ----- 完成提示 -----
echo "=========================================="
echo "部署完成！"
echo "1. 可通过域名访问：bash <(curl -sL https://$DOMAIN)"
echo "2. 本地脚本已下载到：$LOCAL_DIR/tim"
echo "3. HTTPS 已启用，安全访问 https://$DOMAIN"
echo "=========================================="
