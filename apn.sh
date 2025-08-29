#!/bin/sh
set -e

# 颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 必须 root
[ "$(id -u)" -ne 0 ] && echo -e "${RED}请以 root 用户运行${RESET}" && exit 1

# 端口
PORTS="80 443"

open_ports() {
    echo -e "${YELLOW}开放必要端口...${RESET}"
    for p in $PORTS; do
        if ! iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
            echo "开放端口 $p"
        fi
    done
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4 || true
    fi
}

check_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        echo -e "${YELLOW}检测到 Nginx 已安装: $(nginx -v 2>&1)${RESET}"
        echo -ne "${YELLOW}是否更新 Nginx 到最新版本? (y/n): ${RESET}"; read UPDATE
        if [ "$UPDATE" = "y" ]; then
            apk update
            apk upgrade nginx
            rc-service nginx restart
            echo -e "${GREEN}Nginx 已更新并重启${RESET}"
        fi
        return 0
    else
        echo -e "${YELLOW}Nginx 未安装，稍后将执行安装${RESET}"
        return 1
    fi
}

install_nginx() {
    check_nginx || {
        echo -e "${GREEN}安装 Nginx 和 Certbot...${RESET}"
        apk update
        apk add --no-cache nginx certbot py3-certbot-nginx bash

        mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
        # 确保 include sites-enabled
        if ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
            sed -i '/http {/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
        fi

        open_ports
        rc-update add nginx
        rc-service nginx start
    }

    echo -ne "${GREEN}请输入域名: ${RESET}"; read DOMAIN
    echo -ne "${GREEN}请输入反代目标 (http://127.0.0.1:3000): ${RESET}"; read TARGET
    echo -ne "${GREEN}请输入邮箱: ${RESET}"; read EMAIL

    CONFIG="/etc/nginx/sites-available/$DOMAIN"
    LNCONFIG="/etc/nginx/sites-enabled/$DOMAIN"

    cat > "$CONFIG" <<EOF
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
}
EOF

    ln -sf "$CONFIG" "$LNCONFIG"
    nginx -t && rc-service nginx reload

    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" || {
        echo -e "${RED}证书申请失败，请检查域名解析${RESET}"
        exit 1
    }

    echo -e "${GREEN}安装完成，访问: https://$DOMAIN${RESET}"
}

add_config() {
    echo -ne "${GREEN}请输入域名: ${RESET}"; read DOMAIN
    echo -ne "${GREEN}请输入反代目标: ${RESET}"; read TARGET
    echo -ne "${GREEN}请输入邮箱: ${RESET}"; read EMAIL

    CONFIG="/etc/nginx/sites-available/$DOMAIN"
    LNCONFIG="/etc/nginx/sites-enabled/$DOMAIN"

    if [ -f "$CONFIG" ]; then
        echo -e "${YELLOW}配置已存在${RESET}"; return
    fi

    cat > "$CONFIG" <<EOF
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
}
EOF

    ln -sf "$CONFIG" "$LNCONFIG"
    nginx -t && rc-service nginx reload
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    echo -e "${GREEN}添加完成，访问: https://$DOMAIN${RESET}"
}

modify_config() {
    echo -e "${GREEN}===== 修改已有反代配置 =====${RESET}"
    if [ ! -d /etc/nginx/sites-available ] || [ -z "$(ls /etc/nginx/sites-available)" ]; then
        echo -e "${YELLOW}没有可修改的配置${RESET}"
        return
    fi

    echo "已有配置:"
    ls /etc/nginx/sites-available
    echo -ne "${GREEN}请输入要修改的域名: ${RESET}"; read DOMAIN

    CONFIG="/etc/nginx/sites-available/$DOMAIN"
    LNCONFIG="/etc/nginx/sites-enabled/$DOMAIN"

    if [ ! -f "$CONFIG" ]; then
        echo -e "${RED}配置不存在${RESET}"
        return
    fi

    echo -ne "${GREEN}请输入新的反代目标 (http://127.0.0.1:3000): ${RESET}"; read NEW_TARGET
    echo -ne "${GREEN}是否更新邮箱? (y/n): ${RESET}"; read choice
    if [ "$choice" = "y" ]; then
        echo -ne "${GREEN}请输入新邮箱: ${RESET}"; read NEW_EMAIL
    fi

    cat > "$CONFIG" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass $NEW_TARGET;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    nginx -t && rc-service nginx reload

    if [ -n "$NEW_EMAIL" ]; then
        certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$NEW_EMAIL"
    else
        certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos
    fi

    echo -e "${GREEN}修改完成！访问: https://$DOMAIN${RESET}"
}

uninstall_nginx() {
    echo -ne "${YELLOW}确定卸载 Nginx? (y/n): ${RESET}"; read CONFIRM
    [ "$CONFIRM" != "y" ] && return
    rc-service nginx stop
    apk del nginx certbot py3-certbot-nginx
    rm -rf /etc/nginx/sites-available /etc/nginx/sites-enabled
    echo -e "${GREEN}已卸载 Nginx${RESET}"
}

# 菜单
while true; do
    echo -e "${GREEN}===== Alpine Nginx 管理 =====${RESET}"
    echo -e "${GREEN}1) 安装/更新 Nginx + 反代 + TLS${RESET}"
    echo -e "${GREEN}2) 添加新配置${RESET}"
    echo -e "${GREEN}3) 卸载 Nginx${RESET}"
    echo -e "${GREEN}4) 修改已有配置${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -ne "${GREEN}请选择: ${RESET}"; read choice

    case $choice in
        1) install_nginx ;;
        2) add_config ;;
        3) uninstall_nginx ;;
        4) modify_config ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
    echo ""
done
