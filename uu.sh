#!/bin/bash
# ========================================
# 哪吒面板 Nginx 反向代理管理脚本
# ========================================

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

CONFIG_DIR="/etc/nginx/sites-available"
ENABLED_DIR="/etc/nginx/sites-enabled"

mkdir -p "$CONFIG_DIR" "$ENABLED_DIR"

# ------------------------------
# 添加或修改域名配置
# ------------------------------
create_or_update_domain() {
  ACTION=$1
  echo -e "${GREEN}====== ${ACTION}域名配置 ======${RESET}"
  read -p "请输入你的域名（例如 dashboard.example.com）： " DOMAIN

  CONFIG_PATH="$CONFIG_DIR/$DOMAIN"
  ENABLED_PATH="$ENABLED_DIR/$DOMAIN"

  # 如果是修改且已有配置，读取已有上游地址和端口
  if [ -f "$CONFIG_PATH" ]; then
    OLD_UPSTREAM_HOST=$(grep "upstream dashboard" -A1 "$CONFIG_PATH" | grep "server" | awk '{print $2}' | cut -d: -f1)
    OLD_UPSTREAM_PORT=$(grep "upstream dashboard" -A1 "$CONFIG_PATH" | grep "server" | awk '{print $2}' | cut -d: -f2 | tr -d ';')
    OLD_UPSTREAM_HOST=${OLD_UPSTREAM_HOST:-127.0.0.1}
    OLD_UPSTREAM_PORT=${OLD_UPSTREAM_PORT:-8008}
  else
    OLD_UPSTREAM_HOST="127.0.0.1"
    OLD_UPSTREAM_PORT="8008"
  fi

  # 证书获取方式
  echo "请选择证书获取/使用方式："
  echo "1. 使用系统已有证书文件"
  echo "2. 返回主菜单"
  read -p "请输入选项: " ssl_option

  if [ "$ssl_option" == "1" ]; then
    read -p "请输入已有证书文件路径: " CERT_PATH
    read -p "请输入已有密钥文件路径: " KEY_PATH
  elif [ "$ssl_option" == "2" ]; then
    return
  else
    echo "无效的选项"
    return
  fi

  # CDN 回源默认开启
  echo "CDN 回源已默认开启"
  read -p "请输入你的 CDN 回源 IP 地址段 (默认: 173.245.48.0/20): " CDN_IP_RANGE
  CDN_IP_RANGE=${CDN_IP_RANGE:-173.245.48.0/20}

  read -p "请输入 CDN 提供的私有 Header 名称 (默认: CF-Connecting-IP): " CDN_HEADER
  CDN_HEADER=${CDN_HEADER:-CF-Connecting-IP}

  REAL_IP_CONFIG="set_real_ip_from $CDN_IP_RANGE;
  real_ip_header $CDN_HEADER;"
  HEADER_VAR="\$http_${CDN_HEADER//-/_}"

  # 上游服务地址
  read -p "请输入上游服务地址 (默认: $OLD_UPSTREAM_HOST): " UPSTREAM_HOST
  UPSTREAM_HOST=${UPSTREAM_HOST:-$OLD_UPSTREAM_HOST}

  read -p "请输入上游服务端口 (默认: $OLD_UPSTREAM_PORT): " UPSTREAM_PORT
  UPSTREAM_PORT=${UPSTREAM_PORT:-$OLD_UPSTREAM_PORT}

  # 写入 Nginx 配置
  cat > "$CONFIG_PATH" <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;

    server_name $DOMAIN;

    ssl_certificate     $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_stapling on;

    underscores_in_headers on;
    $REAL_IP_CONFIG

    # gRPC
    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
        grpc_set_header nz-realip $HEADER_VAR;
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        client_max_body_size 10m;
        grpc_buffer_size 4m;
        grpc_pass grpc://dashboard;
    }

    # WebSocket
    location ~* ^/api/v1/ws/(server|terminal|file)(.*)\$ {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip $HEADER_VAR;
        proxy_set_header Origin https://\$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://$UPSTREAM_HOST:$UPSTREAM_PORT;
    }

    # Web
    location / {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip $HEADER_VAR;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        proxy_max_temp_file_size 0;
        proxy_pass http://$UPSTREAM_HOST:$UPSTREAM_PORT;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

upstream dashboard {
    server $UPSTREAM_HOST:$UPSTREAM_PORT;
    keepalive 512;
}
EOF

  rm -f "$ENABLED_PATH"
  ln -s "$CONFIG_PATH" "$ENABLED_PATH"

  nginx -t && systemctl reload nginx

  echo -e "${GREEN}域名 $DOMAIN 配置已${ACTION}完成！${RESET}"
}

# ------------------------------
# 删除域名配置
# ------------------------------
delete_domain() {
  echo -e "${GREEN}=== 已配置的域名 ===${RESET}"
  ls "$CONFIG_DIR"
  read -p "请输入要删除的域名: " DOMAIN
  CONFIG_PATH="$CONFIG_DIR/$DOMAIN"
  ENABLED_PATH="$ENABLED_DIR/$DOMAIN"

  if [ -f "$CONFIG_PATH" ]; then
    rm -f "$CONFIG_PATH" "$ENABLED_PATH"
    nginx -t && systemctl reload nginx
    echo -e "${GREEN}已删除 $DOMAIN 配置${RESET}"
  else
    echo -e "${RED}未找到 $DOMAIN 配置${RESET}"
  fi
}

# ------------------------------
# 查看域名信息
# ------------------------------
list_domains() {
  echo -e "${GREEN}=== 已配置的域名 ===${RESET}"
  ls "$CONFIG_DIR" || { echo "暂无配置"; read -p "回车返回..."; return; }
  read -p "请输入要查看的域名（0 返回）: " DOMAIN
  [ "$DOMAIN" == "0" ] && return

  CONFIG_PATH="$CONFIG_DIR/$DOMAIN"
  if [ -f "$CONFIG_PATH" ]; then
    echo -e "\n${GREEN}====== $DOMAIN 配置详情 ======${RESET}"
    echo "配置文件: $CONFIG_PATH"
    echo "监听端口:"
    grep -E "listen " "$CONFIG_PATH"
    echo "证书:"
    grep "ssl_certificate " "$CONFIG_PATH" | head -n1
    grep "ssl_certificate_key " "$CONFIG_PATH" | head -n1
    echo "上游服务:"
    grep "proxy_pass " "$CONFIG_PATH" | head -n1
    echo "gRPC: 已启用"
    echo "WebSocket: 已启用"
    echo "HTTP/2: 已启用"
    echo "CDN 设置:"
    grep -E "set_real_ip_from|real_ip_header" "$CONFIG_PATH" || echo "未配置"
  else
    echo -e "${RED}未找到 $DOMAIN 配置${RESET}"
  fi
  read -p "按回车返回..."
}

# ------------------------------
# 主菜单
# ------------------------------
main_menu() {
  while true; do
    clear
    echo -e "${GREEN}====== 哪吒反向代理管理 ======${RESET}"
    echo -e "${GREEN}1. 添加域名配置${RESET}"
    echo -e "${GREEN}2. 删除域名配置${RESET}"
    echo -e "${GREEN}3. 查看已配置域名信息${RESET}"
    echo -e "${GREEN}4. 修改已有域名配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    read -p "请选择 [0-4]: " choice
    case $choice in
      1) create_or_update_domain "添加" ;;
      2) delete_domain ;;
      3) list_domains ;;
      4) create_or_update_domain "修改" ;;
      0) exit 0 ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

main_menu
