#!/bin/bash
set -e

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请以 root 用户运行此脚本！${RESET}"
  exit 1
fi

pause() {
  echo -e "${YELLOW}按回车返回菜单...${RESET}"
  read
}

# ==============================
# 检测系统 & 安装依赖
# ==============================
install_deps() {
  if [ -f /etc/debian_version ]; then
    apt update -y && apt install -y nginx certbot python3-certbot-nginx curl dnsutils
  elif [ -f /etc/alpine-release ]; then
    apk add --no-cache nginx certbot certbot-nginx curl bind-tools
  elif [ -f /etc/redhat-release ]; then
    yum install -y epel-release
    yum install -y nginx certbot python3-certbot-nginx bind-utils curl
  else
    echo -e "${RED}不支持的系统，请手动安装 nginx certbot${RESET}"
    exit 1
  fi
}

# ==============================
# 获取 VPS IPv4 + IPv6
# ==============================
get_vps_ips() {
  VPS_IPV4=$(hostname -I | awk '{for(i=1;i<=NF;i++) if($i !~ /:/){print $i;exit}}')
  VPS_IPV6=$(hostname -I | awk '{for(i=1;i<=NF;i++) if($i ~ /:/){print $i;exit}}')
}

# ==============================
# 检查 DNS A/AAAA 和防火墙
# ==============================
check_dns_and_firewall() {
  local DOMAIN=$1
  echo -e "${YELLOW}正在检查域名解析和防火墙状态...${RESET}"

  local A_RECORD=$(dig A +short $DOMAIN | head -n1)
  local AAAA_RECORD=$(dig AAAA +short $DOMAIN | head -n1)

  echo "  A记录 (IPv4):  $A_RECORD"
  echo "  AAAA记录 (IPv6): $AAAA_RECORD"

  get_vps_ips
  echo "  VPS IPv4: $VPS_IPV4"
  echo "  VPS IPv6: $VPS_IPV6"

  if [ "$A_RECORD" != "$VPS_IPV4" ] && [ -n "$A_RECORD" ]; then
    echo -e "${RED}⚠ 域名 A 记录 ($A_RECORD) 与 VPS IPv4 ($VPS_IPV4) 不一致${RESET}"
  fi
  if [ "$AAAA_RECORD" != "$VPS_IPV6" ] && [ -n "$AAAA_RECORD" ]; then
    echo -e "${RED}⚠ 域名 AAAA 记录 ($AAAA_RECORD) 与 VPS IPv6 ($VPS_IPV6) 不一致${RESET}"
  fi

  # 检查 80/443 是否监听
  echo -e "${YELLOW}检测 80/443 防火墙端口...${RESET}"
  if ss -lnt | grep -q ":80 "; then
    echo "  ✅ 80 端口已监听"
  else
    echo -e "${RED}  ❌ 80 端口未监听 (可能阻止 HTTP 验证)${RESET}"
  fi
  if ss -lnt | grep -q ":443 "; then
    echo "  ✅ 443 端口已监听"
  else
    echo -e "${RED}  ❌ 443 端口未监听 (TLS 可能失败)${RESET}"
  fi
}

# ==============================
# Nginx 配置检测 + 启动
# ==============================
reload_nginx() {
  if nginx -t; then
    systemctl enable nginx
    systemctl restart nginx
  else
    echo -e "${RED}Nginx 配置有问题，请检查！${RESET}"
    pause
    return 1
  fi
}

# ==============================
# 安装 Nginx + 反代 + TLS
# ==============================
install_nginx() {
  install_deps
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

  echo -ne "${GREEN}请输入邮箱地址: ${RESET}"; read EMAIL
  echo -ne "${GREEN}请输入域名 (example.com): ${RESET}"; read DOMAIN
  echo -ne "${GREEN}请输入反代目标 (http://127.0.0.1:3000): ${RESET}"; read TARGET

  check_dns_and_firewall $DOMAIN

  CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"

  cat > "$CONFIG_PATH" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    location / {
        proxy_pass $TARGET;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  ln -sf "$CONFIG_PATH" /etc/nginx/sites-enabled/
  reload_nginx || return

  certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" || {
    echo -e "${RED}证书申请失败，请检查 DNS A/AAAA 解析和防火墙端口！${RESET}"
    pause
    return
  }

  systemctl enable --now certbot.timer
  echo -e "${GREEN}安装完成！访问: https://$DOMAIN${RESET}"
  pause
}

# ==============================
# 添加新反代配置 (支持 WebSocket)
# ==============================
add_config() {
  echo -ne "${GREEN}请输入域名: ${RESET}"; read DOMAIN
  echo -ne "${GREEN}请输入反代目标 (http://127.0.0.1:3000): ${RESET}"; read TARGET
  echo -ne "${GREEN}请输入邮箱地址: ${RESET}"; read EMAIL
  echo -ne "${GREEN}是否为 WebSocket 反代？(y/n): ${RESET}"; read WS_CHOICE

  check_dns_and_firewall $DOMAIN

  CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"

  if [[ "$WS_CHOICE" == "y" ]]; then
    cat > "$CONFIG_PATH" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    location / {
        proxy_pass $TARGET;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  else
    cat > "$CONFIG_PATH" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    location / {
        proxy_pass $TARGET;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  fi

  ln -sf "$CONFIG_PATH" /etc/nginx/sites-enabled/
  reload_nginx || return

  certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
  echo -e "${GREEN}添加完成！访问: https://$DOMAIN${RESET}"
  pause
}

# ==============================
# 修改现有配置
# ==============================
modify_config() {
  ls /etc/nginx/sites-available/
  echo -ne "${GREEN}请输入要修改的域名: ${RESET}"; read DOMAIN
  CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"
  [ ! -f "$CONFIG_PATH" ] && echo "配置不存在！" && pause && return

  echo -ne "${GREEN}请输入新反代目标: ${RESET}"; read NEW_TARGET
  echo -ne "${GREEN}是否为 WebSocket 反代？(y/n): ${RESET}"; read WS_CHOICE
  echo -ne "${GREEN}是否更新邮箱 (y/n): ${RESET}"; read choice
  if [[ "$choice" == "y" ]]; then
    echo -ne "${GREEN}新邮箱: ${RESET}"; read NEW_EMAIL
  fi

  if [[ "$WS_CHOICE" == "y" ]]; then
    cat > "$CONFIG_PATH" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    location / {
        proxy_pass $NEW_TARGET;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  else
    cat > "$CONFIG_PATH" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    location / {
        proxy_pass $NEW_TARGET;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  fi

  reload_nginx || return
  certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --non-interactive --agree-tos -m "${NEW_EMAIL:-admin@$DOMAIN}"
  echo -e "${GREEN}修改完成！访问: https://$DOMAIN${RESET}"
  pause
}

# ==============================
# 封禁 / 解除端口直连
# ==============================
block_direct_ip_manual() {
  echo -ne "${GREEN}请输入要封禁的端口(例: 3000 8080): ${RESET}"; read PORTS
  for port in $PORTS; do
    CONFIG="/etc/nginx/sites-available/block_port_$port.conf"
    cat > "$CONFIG" <<EOF
server {
    listen $port default_server;
    listen [::]:$port default_server;
    server_name _;
    return 444;
}
EOF
    ln -sf "$CONFIG" /etc/nginx/sites-enabled/
  done
  reload_nginx || return
  echo -e "${GREEN}端口 $PORTS 已封禁 (IPv4+IPv6)${RESET}"
  pause
}

unblock_direct_ip_manual() {
  echo -ne "${GREEN}请输入要解除封禁的端口: ${RESET}"; read PORTS
  for port in $PORTS; do
    CONFIG="/etc/nginx/sites-available/block_port_$port.conf"
    [ -f "$CONFIG" ] && rm -f "$CONFIG" /etc/nginx/sites-enabled/block_port_$port.conf
  done
  reload_nginx || return
  echo -e "${GREEN}端口 $PORTS 封禁已解除${RESET}"
  pause
}

# ==============================
# VPS IP 直连控制
# ==============================
block_vps_ip_access() {
  get_vps_ips
  CONFIG="/etc/nginx/sites-available/block_vps_ip.conf"
  cat > "$CONFIG" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $VPS_IPV4 $VPS_IPV6;
    return 444;
}
EOF
  ln -sf "$CONFIG" /etc/nginx/sites-enabled/
  reload_nginx || return
  echo -e "${GREEN}VPS IP 直连访问已禁止${RESET}"
  pause
}

allow_vps_ip_access() {
  CONFIG="/etc/nginx/sites-available/block_vps_ip.conf"
  [ -f "$CONFIG" ] && rm -f "$CONFIG" /etc/nginx/sites-enabled/block_vps_ip.conf
  reload_nginx || return
  echo -e "${GREEN}VPS IP 直连访问已允许${RESET}"
  pause
}

# ==============================
# 卸载
# ==============================
uninstall_nginx() {
  echo -ne "${GREEN}确定卸载 Nginx 和配置? (y/n): ${RESET}"; read CONFIRM
  [[ "$CONFIRM" != "y" ]] && return

  systemctl stop nginx && systemctl disable nginx
  if [ -f /etc/debian_version ]; then
    apt remove --purge -y nginx certbot python3-certbot-nginx
  elif [ -f /etc/alpine-release ]; then
    apk del nginx certbot certbot-nginx
  elif [ -f /etc/redhat-release ]; then
    yum remove -y nginx certbot python3-certbot-nginx
  fi

  rm -rf /etc/nginx/sites-available /etc/nginx/sites-enabled
  systemctl disable --now certbot.timer || true
  echo -e "${GREEN}Nginx 已卸载${RESET}"
  pause
}

# ==============================
# 菜单
# ==============================
while true; do
  clear
  echo -e "${GREEN}====== Nginx 管理脚本 ======${RESET}"
  echo -e "${GREEN}1) 安装 Nginx + 反代 + TLS${RESET}"
  echo -e "${GREEN}2) 添加新的反代配置${RESET}"
  echo -e "${GREEN}3) 修改现有配置${RESET}"
  echo -e "${GREEN}4) 封禁直接 IP + 端口访问 (IPv6 支持)${RESET}"
  echo -e "${GREEN}5) 解除封禁 IP + 端口访问${RESET}"
  echo -e "${GREEN}6) 卸载 Nginx${RESET}"
  echo -e "${GREEN}7) 禁止 VPS IP 直连访问 (IPv6 支持)${RESET}"
  echo -e "${GREEN}8) 允许 VPS IP 直连访问${RESET}"
  echo -e "${GREEN}0) 退出${RESET}"
  echo -ne "${GREEN}请选择 [0-8]: ${RESET}"
  read choice

  case $choice in
    1) install_nginx ;;
    2) add_config ;;
    3) modify_config ;;
    4) block_direct_ip_manual ;;
    5) unblock_direct_ip_manual ;;
    6) uninstall_nginx ;;
    7) block_vps_ip_access ;;
    8) allow_vps_ip_access ;;
    0) exit 0 ;;
    *) echo -e "${RED}无效选项${RESET}"; pause ;;
  esac
done
