#!/bin/bash
set -e

# ==================== 颜色设置 ====================
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

###############################################################################
# 安装 Certbot
###############################################################################
install_certbot() {
  if ! command -v certbot &>/dev/null; then
    echo -e "${YELLOW}正在安装 Certbot...${RESET}"
    if [ -f /etc/debian_version ]; then
      apt update
      apt install -y certbot python3-certbot-nginx
    elif [ -f /etc/redhat-release ]; then
      yum install -y epel-release
      yum install -y certbot python3-certbot-nginx
    else
      echo -e "${RED}❌ 不支持的系统，请手动安装 Certbot${RESET}"
      return 1
    fi
  else
    echo -e "${GREEN}✅ Certbot 已安装${RESET}"
  fi
}

###############################################################################
# 配置复杂反向代理功能
###############################################################################
configure_complex_reverse_proxy() {
  echo -e "${GREEN}===============================${RESET}"
  echo -e "${GREEN}       哪吒复杂反向代理${RESET}"
  echo -e "${GREEN}===============================${RESET}"

  # 自定义本地服务地址
  read -p "请输入本地服务 IP（例如 127.0.0.1）: " LOCAL_IP
  [ -z "$LOCAL_IP" ] && LOCAL_IP="127.0.0.1"

  read -p "请输入本地服务端口（例如 8008）: " LOCAL_PORT
  [ -z "$LOCAL_PORT" ] && LOCAL_PORT="8008"

  LOCAL_SERVICE="http://$LOCAL_IP:$LOCAL_PORT"
  GRPC_SERVICE="$LOCAL_IP:$LOCAL_PORT"

  read -p "请输入你的域名（例如 dashboard.example.com）： " DOMAIN
  # 生成唯一 upstream 名称
  UPSTREAM_NAME="dashboard_$(echo $DOMAIN | tr '.' '_')"

  echo "请选择证书获取/使用方式："
  echo "1. 使用系统已有证书文件"
  echo "2. 自动申请 Let's Encrypt 证书 (Certbot)"
  echo "0. 返回主菜单"
  read -p "请输入选项 [0-2]: " ssl_option

  echo "请选择是否启用 HTTP/2："
  echo "1. 启用 HTTP/2"
  echo "2. 禁用 HTTP/2"
  read -p "请输入选项 [1-2]: " http2_option
  [ "$http2_option" == "1" ] && HTTP2_CONFIG="ssl http2" || HTTP2_CONFIG="ssl"

  SSL_PROTOCOLS="TLSv1.2 TLSv1.3"
  SSL_SESSION_CACHE="shared:SSL:10m"

  echo "是否使用 CDN 回源（如 Cloudflare）？"
  echo "1. 是"
  echo "2. 否"
  read -p "请输入选项 [1-2]: " cdn_option
  if [ "$cdn_option" == "1" ]; then
    read -p "请输入你的 CDN 回源 IP 地址段（例如 0.0.0.0/0）： " CDN_IP_RANGE
    read -p "请输入 CDN 提供的私有 Header 名称（例如 CF-Connecting-IP）： " CDN_HEADER
    REAL_IP_CONFIG="
    set_real_ip_from $CDN_IP_RANGE;
    real_ip_header $CDN_HEADER;"
  else
    REAL_IP_CONFIG=""
    CDN_HEADER="remote_addr"
  fi

  echo "是否配置 gRPC 服务？"
  echo "1. 是"
  echo "2. 否"
  read -p "请输入选项 [1-2]: " grpc_option
  [ "$grpc_option" == "1" ] && GRPC_ENABLED=true || GRPC_ENABLED=false

  echo "是否配置 WebSocket 服务？"
  echo "1. 是"
  echo "2. 否"
  read -p "请输入选项 [1-2]: " ws_option
  [ "$ws_option" == "1" ] && WS_ENABLED=true || WS_ENABLED=false

  # 证书处理
  if [ "$ssl_option" == "1" ]; then
    read -p "请输入已有证书文件路径: " CERT_PATH
    read -p "请输入已有密钥文件路径: " KEY_PATH
  elif [ "$ssl_option" == "2" ]; then
    read -p "请输入你的邮箱地址（用于 Let's Encrypt 通知）： " EMAIL
    install_certbot || return
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect || {
      echo -e "${RED}❌ 证书申请失败，请检查域名解析${RESET}"
      return
    }
    systemctl enable certbot.timer
    systemctl start certbot.timer
    CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  elif [ "$ssl_option" == "0" ]; then
    return
  fi

  CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"
  ENABLED_PATH="/etc/nginx/sites-enabled/$DOMAIN"

  echo -e "${GREEN}写入 Nginx 配置...${RESET}"
  cat > "$CONFIG_PATH" <<EOF
# ================= HTTPS =================
server {
    listen 443 $HTTP2_CONFIG;
    listen [::]:443 $HTTP2_CONFIG;

    server_name $DOMAIN;
    ssl_certificate     $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    ssl_stapling on;
    ssl_session_timeout 1d;
    ssl_session_cache $SSL_SESSION_CACHE;
    ssl_protocols $SSL_PROTOCOLS;

    underscores_in_headers on;
    $REAL_IP_CONFIG
EOF

  if [ "$GRPC_ENABLED" = true ]; then
    cat >> "$CONFIG_PATH" <<EOF
    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
        grpc_set_header nz-realip \$http_${CDN_HEADER};
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        client_max_body_size 10m;
        grpc_buffer_size 16m;
        grpc_pass grpc://$UPSTREAM_NAME;
    }
EOF
  fi

  if [ "$WS_ENABLED" = true ]; then
    cat >> "$CONFIG_PATH" <<EOF
    location ~* ^/api/v1/ws/(server|terminal|file)(.*)\$ {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$http_${CDN_HEADER};
        proxy_set_header Origin https://\$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass $UPSTREAM_NAME;
    }
EOF
  fi

  cat >> "$CONFIG_PATH" <<EOF
    location / {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$http_${CDN_HEADER};
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        proxy_max_temp_file_size 0;
        proxy_pass $UPSTREAM_NAME;
    }
}

# ================= HTTP =================
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

# ================= Upstream =================
upstream $UPSTREAM_NAME {
    server $GRPC_SERVICE;
    keepalive 512;
}
EOF

  rm -f "$ENABLED_PATH"
  ln -s "$CONFIG_PATH" "$ENABLED_PATH"
  nginx -t && systemctl reload nginx
  echo -e "${GREEN}✅ 配置完成，访问：https://$DOMAIN${RESET}"
}

###############################################################################
# 删除反向代理配置
###############################################################################
delete_reverse_proxy() {
  read -p "请输入要删除的域名: " DOMAIN
  CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"
  ENABLED_PATH="/etc/nginx/sites-enabled/$DOMAIN"
  rm -f "$CONFIG_PATH" "$ENABLED_PATH"
  nginx -t && systemctl reload nginx
  echo -e "${GREEN}✅ 已删除 $DOMAIN 的反向代理配置${RESET}"
}

###############################################################################
# 查看反向代理配置
###############################################################################
view_reverse_proxy() {
  read -p "请输入要查看的域名: " DOMAIN
  CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"
  if [ -f "$CONFIG_PATH" ]; then
    cat "$CONFIG_PATH"
  else
    echo -e "${RED}❌ 配置文件不存在: $CONFIG_PATH${RESET}"
  fi
}

###############################################################################
# 查看证书状态
###############################################################################
check_cert_status() {
  read -p "请输入要检查的域名: " DOMAIN
  CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  if [ ! -f "$CERT_PATH" ]; then
    echo -e "${RED}❌ 找不到证书: $CERT_PATH${RESET}"
    return
  fi
  EXPIRY_DATE=$(openssl x509 -in "$CERT_PATH" -noout -enddate | cut -d= -f2)
  EXPIRY_TIMESTAMP=$(date -d "$EXPIRY_DATE" +%s)
  NOW_TIMESTAMP=$(date +%s)
  DAYS_LEFT=$(( (EXPIRY_TIMESTAMP - NOW_TIMESTAMP) / 86400 ))
  echo -e "${GREEN}证书到期时间: $EXPIRY_DATE${RESET}"
  echo -e "${YELLOW}剩余天数: $DAYS_LEFT 天${RESET}"
}

###############################################################################
# 手动续签证书
###############################################################################
renew_cert_manual() {
  read -p "请输入要续签的域名: " DOMAIN
  if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    certbot renew --cert-name "$DOMAIN" --force-renewal
    systemctl reload nginx
    echo -e "${GREEN}✅ $DOMAIN 证书已续签并重载 Nginx${RESET}"
  else
    echo -e "${RED}❌ 未找到 $DOMAIN 的证书${RESET}"
  fi
}

###############################################################################
# 主菜单
###############################################################################
while true; do
  echo -e "${GREEN}===============================${RESET}"
  echo -e "${GREEN}         主菜单${RESET}"
  echo -e "${GREEN}===============================${RESET}"
  echo -e "${GREEN}1. 配置复杂反向代理${RESET}"
  echo -e "${GREEN}2. 删除反向代理配置${RESET}"
  echo -e "${GREEN}3. 查看反向代理配置${RESET}"
  echo -e "${GREEN}5. 查看证书状态${RESET}"
  echo -e "${GREEN}6. 手动续签证书${RESET}"
  echo -e "${GREEN}0. 退出${RESET}"
  read -p "请输入选项 [0-6]: " choice

  case $choice in
    1) configure_complex_reverse_proxy ;;
    2) delete_reverse_proxy ;;
    3) view_reverse_proxy ;;
    5) check_cert_status ;;
    6) renew_cert_manual ;;
    0) exit 0 ;;
    *) echo -e "${RED}无效的选项，请重新输入。${RESET}" ;;
  esac
done
