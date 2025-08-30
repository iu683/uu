#!/bin/bash
set -e

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 检查是否 root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请以 root 用户运行此脚本！${RESET}"
  exit 1
fi

# 防火墙配置函数
configure_firewall() {
  echo -e "${YELLOW}检测并配置防火墙以开放必要端口...${RESET}"

  REQUIRED_PORTS=(80 443)
  if command -v ufw >/dev/null 2>&1; then
    echo "检测到 ufw"
    for port in "${REQUIRED_PORTS[@]}"; do
      if ! ufw status | grep -qw "$port"; then
        ufw allow "$port"
        echo "开放端口 $port"
      fi
    done
    return
  fi

  if systemctl is-active --quiet firewalld; then
    echo "检测到 firewalld"
    for port in "${REQUIRED_PORTS[@]}"; do
      if ! firewall-cmd --list-ports | grep -qw "${port}/tcp"; then
        firewall-cmd --permanent --add-port=${port}/tcp
        echo "开放端口 $port"
      fi
    done
    firewall-cmd --reload
    return
  fi

  if command -v iptables >/dev/null 2>&1; then
    echo "检测到 iptables"
    for port in "${REQUIRED_PORTS[@]}"; do
      if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        echo "开放端口 $port"
      fi
    done
    if command -v netfilter-persistent >/dev/null 2>&1; then
      netfilter-persistent save
    elif command -v service >/dev/null 2>&1; then
      service iptables save
    fi
    return
  fi

  echo -e "${YELLOW}未检测到防火墙工具，默认所有端口已开放。${RESET}"
}

# 确保 sites-enabled 被包含
ensure_nginx_include() {
  if ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
    sed -i '/http {/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
    echo "已补充 include /etc/nginx/sites-enabled/*; 到 nginx.conf"
  fi
}

# 封禁直接 IP + 端口访问（动态检测所有 Nginx 配置端口）
block_direct_ip() {
  echo -e "${YELLOW}自动检测 Nginx 配置端口并封禁直接 IP 访问...${RESET}"

  PORTS=($(grep -h "listen " /etc/nginx/sites-available/* | awk '{print $2}' | sed 's/;//' | sort -u))

  for PORT in "${PORTS[@]}"; do
    CONF="/etc/nginx/sites-available/block_port_$PORT.conf"
    cat > "$CONF" <<EOF
server {
    listen $PORT default_server;
    server_name _;
    return 444;
}
EOF
    ln -sf "$CONF" /etc/nginx/sites-enabled/
  done

  nginx -t && systemctl reload nginx
  echo -e "${GREEN}已封禁直接 IP + 端口访问（自动检测端口）${RESET}"
}

# 解除封禁
unblock_direct_ip() {
  echo -e "${YELLOW}解除封禁直接 IP + 端口访问...${RESET}"
  for CONF in /etc/nginx/sites-available/block_port_*.conf; do
    [[ -f "$CONF" ]] && rm -f "$CONF"
    [[ -f "/etc/nginx/sites-enabled/$(basename $CONF)" ]] && rm -f "/etc/nginx/sites-enabled/$(basename $CONF)"
  done
  nginx -t && systemctl reload nginx
  echo -e "${GREEN}已解除封禁${RESET}"
}

# 检查 Docker 容器端口映射
check_docker_ports() {
  if command -v docker >/dev/null 2>&1; then
    CONTAINERS=$(docker ps --format "{{.Names}}")
    if [ -n "$CONTAINERS" ]; then
      echo -e "${YELLOW}检测到 Docker 容器，请确认后端服务监听地址为 127.0.0.1 或正确端口映射${RESET}"
      docker ps --format "容器: {{.Names}} 映射端口: {{.Ports}}"
    fi
  fi
}

# 检测 Nginx 是否监听公网 IP
check_nginx_bind() {
  echo -e "${YELLOW}检查 Nginx 是否监听公网 IP...${RESET}"
  LISTEN_ADDRESSES=$(ss -tlnp | grep nginx | awk '{print $4}')
  PUBLIC_IPS=($(hostname -I))
  FOUND_PUBLIC=0

  for addr in $LISTEN_ADDRESSES; do
    IP=$(echo $addr | cut -d':' -f1)
    if [[ ! " ${PUBLIC_IPS[@]} " =~ " $IP " ]] && [[ "$IP" != "127.0.0.1" ]] && [[ "$IP" != "::1" ]]; then
      FOUND_PUBLIC=1
      echo -e "${RED}警告：Nginx 正在监听公网 IP ($IP)${RESET}"
    fi
  done

  if [ $FOUND_PUBLIC -eq 0 ]; then
    echo -e "${GREEN}Nginx 没有监听公网 IP，配置安全${RESET}"
  else
    echo -ne "${YELLOW}是否将 Nginx 配置修改为只监听 127.0.0.1？(y/n): ${RESET}"
    read choice
    if [[ "$choice" == "y" ]]; then
      sed -i 's/listen [0-9\.]*:[0-9]\+/listen 127.0.0.1:80/g' /etc/nginx/sites-available/*
      sed -i 's/listen \[::\]:[0-9]\+/listen [::1]:80/g' /etc/nginx/sites-available/*
      nginx -t && systemctl reload nginx
      echo -e "${GREEN}已修改 Nginx 为只监听本地 IP${RESET}"
    fi
  fi
}

# 生成反代配置（支持 WebSocket）
generate_nginx_config() {
  DOMAIN=$1
  TARGET=$2
  EMAIL=$3
  CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"
  ENABLED_PATH="/etc/nginx/sites-enabled/$DOMAIN"

  echo -ne "${GREEN}是否需要 WebSocket 反代支持? (y/n): ${RESET}"
  read WS_CHOICE

  WS_CONF=""
  if [[ "$WS_CHOICE" == "y" ]]; then
    WS_CONF=$(cat <<EOF
location /ws/ {
    proxy_pass $TARGET;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}
EOF
)
  fi

  cat > "$CONFIG_PATH" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass $TARGET;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    $WS_CONF
}
EOF

  ln -sf "$CONFIG_PATH" "$ENABLED_PATH"
  nginx -t && systemctl reload nginx
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
}

# 安装 Nginx + TLS + 封禁 + 检查 Docker/公网 IP
install_nginx() {
  echo -e "${GREEN}安装 Nginx 和 Certbot...${RESET}"
  apt update && apt upgrade -y
  apt install -y nginx certbot python3-certbot-nginx

  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  configure_firewall
  ensure_nginx_include
  systemctl enable --now nginx

  echo -ne "${GREEN}请输入邮箱地址: ${RESET}"
  read EMAIL
  echo -ne "${GREEN}请输入域名 (example.com): ${RESET}"
  read DOMAIN
  echo -ne "${GREEN}请输入反代目标 (http://localhost:3000): ${RESET}"
  read TARGET

  generate_nginx_config "$DOMAIN" "$TARGET" "$EMAIL"
  block_direct_ip
  check_docker_ports
  check_nginx_bind

  echo -e "${GREEN}安装完成！访问: https://$DOMAIN${RESET}"
}

# 添加配置
add_config() {
  echo -ne "${GREEN}请输入域名: ${RESET}"
  read DOMAIN
  echo -ne "${GREEN}请输入反代目标: ${RESET}"
  read TARGET
  echo -ne "${GREEN}请输入邮箱地址: ${RESET}"
  read EMAIL

  if [ -f "/etc/nginx/sites-available/$DOMAIN" ]; then
    echo -e "${YELLOW}配置已存在: $DOMAIN${RESET}"
    return
  fi

  generate_nginx_config "$DOMAIN" "$TARGET" "$EMAIL"
  block_direct_ip
  check_docker_ports
  check_nginx_bind

  echo -e "${GREEN}添加完成！访问: https://$DOMAIN${RESET}"
}

# 修改配置
modify_config() {
  ls /etc/nginx/sites-available/
  echo -ne "${GREEN}请输入要修改的域名: ${RESET}"
  read DOMAIN
  CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"

  [ ! -f "$CONFIG_PATH" ] && echo "配置不存在！" && return

  echo -ne "${GREEN}请输入新反代目标: ${RESET}"
  read NEW_TARGET
  echo -ne "${GREEN}是否更新邮箱 (y/n): ${RESET}"
  read choice
  if [[ "$choice" == "y" ]]; then
    echo -ne "${GREEN}新邮箱: ${RESET}"
    read NEW_EMAIL
  else
    NEW_EMAIL="admin@$DOMAIN"
  fi

  generate_nginx_config "$DOMAIN" "$NEW_TARGET" "$NEW_EMAIL"
  block_direct_ip
  check_docker_ports
  check_nginx_bind

  echo -e "${GREEN}修改完成！访问: https://$DOMAIN${RESET}"
}

# 卸载
uninstall_nginx() {
  echo -ne "${GREEN}确定卸载 Nginx 和配置? (y/n): ${RESET}"
  read CONFIRM
  [[ "$CONFIRM" != "y" ]] && return

  systemctl stop nginx && systemctl disable nginx
  apt remove --purge -y nginx certbot python3-certbot-nginx
  rm -rf /etc/nginx/sites-available /etc/nginx/sites-enabled
  systemctl disable --now certbot.timer || true

  echo -e "${GREEN}Nginx 已卸载${RESET}"
}

# 菜单
while true; do
  echo -e "${GREEN}====== Nginx 管理脚本 ======${RESET}"
  echo -e "${GREEN}1) 安装 Nginx + 反代 + TLS${RESET}"
  echo -e "${GREEN}2) 添加新的反代配置${RESET}"
  echo -e "${GREEN}3) 修改现有配置${RESET}"
  echo -e "${GREEN}4) 封禁直接 IP + 端口访问${RESET}"
  echo -e "${GREEN}5) 解除封禁 IP + 端口访问${RESET}"
  echo -e "${GREEN}6) 卸载 Nginx${RESET}"
  echo -e "${GREEN}0) 退出${RESET}"
  echo -ne "${GREEN}请选择 [0-6]: ${RESET}"
  read choice

  case $choice in
    1) install_nginx ;;
    2) add_config ;;
    3) modify_config ;;
    4) block_direct_ip ;;
    5) unblock_direct_ip ;;
    6) uninstall_nginx ;;
    0) exit 0 ;;
    *) echo -e "${RED}无效选项${RESET}" ;;
  esac
  echo ""
done
