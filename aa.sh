#!/bin/bash
set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

pause() {
    echo -ne "${YELLOW}按回车返回菜单...${RESET}"
    read
}

configure_firewall() {
    for PORT in 80 443; do
        if command -v ufw >/dev/null 2>&1; then
            ufw allow $PORT || true
        elif command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port=$PORT/tcp || true
            firewall-cmd --reload || true
        fi
    done
}

remove_default_server() {
    echo -e "${YELLOW}清理系统自带的 default server 配置...${RESET}"
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-available/default
}

ensure_nginx_conf() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/modules-enabled
    if [ ! -f /etc/nginx/nginx.conf ]; then
        cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    gzip on;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    fi

    if [ ! -f /etc/nginx/mime.types ]; then
        cat > /etc/nginx/mime.types <<'EOF'
types {
    text/html  html htm shtml;
    text/css   css;
    text/xml   xml;
    image/gif  gif;
    image/jpeg jpeg jpg;
    application/javascript js;
    application/atom+xml atom;
    application/rss+xml rss;
}
EOF
    fi
}

create_default_server() {
    DEFAULT_PATH="/etc/nginx/sites-available/default_server_block"
    [ ! -f "$DEFAULT_PATH" ] && cat > "$DEFAULT_PATH" <<EOF
server {
    listen 80 default_server;
    server_name _;
    return 403;
}
EOF
    ln -sf "$DEFAULT_PATH" /etc/nginx/sites-enabled/default_server_block
}

generate_server_config() {
    DOMAIN=$1
    TARGET=$2
    IS_WS=$3
    MAX_SIZE=$4
    CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"

    MAX_SIZE=${MAX_SIZE:-200M}

    if [ "$IS_WS" == "y" ]; then
        WS_HEADERS="proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"Upgrade\";"
    else
        WS_HEADERS=""
    fi

    cat > "$CONFIG_PATH" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        client_max_body_size $MAX_SIZE;

        proxy_pass $TARGET;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        $WS_HEADERS
    }
}
EOF
    ln -sf "$CONFIG_PATH" "/etc/nginx/sites-enabled/$DOMAIN"
}

check_domain_resolution() {
    DOMAIN=$1
    VPS_IP=$(curl -s https://ipinfo.io/ip)
    DOMAIN_IP=$(dig +short "$DOMAIN" | tail -n1)
    if [ "$DOMAIN_IP" != "$VPS_IP" ]; then
        echo -e "${RED}警告: 域名 $DOMAIN 解析为 $DOMAIN_IP, VPS IP 为 $VPS_IP${RESET}"
    else
        echo -e "${GREEN}域名解析正常${RESET}"
    fi
}

# ------------------------------
# 功能函数
# ------------------------------

install_nginx() {
    ensure_nginx_conf
    remove_default_server

    DEBIAN_FRONTEND=noninteractive apt update
    DEBIAN_FRONTEND=noninteractive apt upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    DEBIAN_FRONTEND=noninteractive apt install -y curl dnsutils \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    echo -e "${GREEN}开始安装 Nginx 和 Certbot...${RESET}"
    if ! DEBIAN_FRONTEND=noninteractive apt install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        nginx certbot python3-certbot-nginx; then
        echo -e "${RED}安装失败，尝试自动修复...${RESET}"
        uninstall_nginx
        echo -e "${YELLOW}重新尝试安装...${RESET}"
        DEBIAN_FRONTEND=noninteractive apt install -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            nginx certbot python3-certbot-nginx || {
            echo -e "${RED}修复后安装仍然失败，请手动检查系统环境！${RESET}"
            pause
            return
        }
    fi

    remove_default_server
    create_default_server
    configure_firewall
    systemctl daemon-reload
    systemctl enable --now nginx

    echo -ne "${GREEN}请输入邮箱地址: ${RESET}"; read EMAIL
    echo -ne "${GREEN}请输入域名: ${RESET}"; read DOMAIN
    check_domain_resolution "$DOMAIN"
    echo -ne "${GREEN}请输入反代目标: ${RESET}"; read TARGET
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n，默认 y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}

    echo -ne "${GREEN}请输入最大上传大小 (默认 200M): ${RESET}"
    read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE"
    nginx -t && systemctl reload nginx
    systemctl enable --now certbot.timer
    echo -e "${GREEN}安装完成！访问: https://$DOMAIN${RESET}"
    pause
}

add_config() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    echo -ne "${GREEN}请输入域名: ${RESET}"; read DOMAIN
    check_domain_resolution "$DOMAIN"
    echo -ne "${GREEN}请输入反代目标: ${RESET}"; read TARGET

    EMAIL_FILE="/etc/nginx/.cert_emails"
    if [ -f "$EMAIL_FILE" ]; then
        EMAILS=($(cat "$EMAIL_FILE"))
    else
        EMAILS=()
    fi

    if [ ${#EMAILS[@]} -gt 0 ]; then
        echo -e "${GREEN}已有邮箱列表:${RESET}"
        for i in "${!EMAILS[@]}"; do
            echo -e "${GREEN}$((i+1))) ${EMAILS[$i]}${RESET}"
        done
        echo -ne "${GREEN}请选择邮箱编号 (或输入新邮箱): ${RESET}"; read choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#EMAILS[@]} ]; then
            EMAIL="${EMAILS[$((choice-1))]}"
        else
            EMAIL="$choice"
            echo "$EMAIL" >> "$EMAIL_FILE"
            sort -u "$EMAIL_FILE" -o "$EMAIL_FILE"
        fi
    else
        echo -ne "${GREEN}请输入邮箱地址: ${RESET}"; read EMAIL
        echo "$EMAIL" > "$EMAIL_FILE"
    fi

    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n，回车默认 y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}

    echo -ne "${GREEN}请输入最大上传大小 (默认 200M): ${RESET}"
    read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}

    [ -f "/etc/nginx/sites-available/$DOMAIN" ] && echo -e "${YELLOW}配置已存在${RESET}" && pause && return

    certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE"
    create_default_server
    nginx -t && systemctl reload nginx
    echo -e "${GREEN}添加完成！访问: https://$DOMAIN${RESET}"
    pause
}

modify_config() {
    CONFIG_DIR="/etc/nginx/sites-available"
    [ ! -d "$CONFIG_DIR" ] && echo -e "${YELLOW}还没有任何配置文件！${RESET}" && pause && return

    DOMAINS=($(ls "$CONFIG_DIR" | grep -vE 'default|default_server_block' | sort))
    [ ${#DOMAINS[@]} -eq 0 ] && echo -e "${YELLOW}没有域名配置！${RESET}" && pause && return

    echo -e "${GREEN}现有配置的域名:${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo -e "${GREEN}$((i+1))) ${DOMAINS[$i]}${RESET}"
    done

    echo -ne "${GREEN}请输入编号 (0 返回): ${RESET}"
    read choice
    if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}已取消${RESET}"; return
    fi
    if [ "$choice" -eq 0 ]; then return; fi
    if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效选择${RESET}"; pause; return
    fi

    DOMAIN="${DOMAINS[$((choice-1))]}"
    CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"
    echo -ne "${GREEN}请输入新反代目标: ${RESET}"; read TARGET
    echo -ne "${GREEN}是否为 WebSocket 反代? (y/n，回车默认 y): ${RESET}"; read IS_WS
    IS_WS=${IS_WS:-y}
    echo -ne "${GREEN}请输入最大上传大小 (默认 200M): ${RESET}"
    read MAX_SIZE
    MAX_SIZE=${MAX_SIZE:-200M}
    echo -ne "${GREEN}是否更新邮箱? (y/n，回车默认 n): ${RESET}"; read c
    c=${c:-n}
    if [[ "$c" == "y" ]]; then
        echo -ne "${GREEN}新邮箱: ${RESET}"; read EMAIL
        certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    fi
    generate_server_config "$DOMAIN" "$TARGET" "$IS_WS" "$MAX_SIZE"
    create_default_server
    nginx -t && systemctl reload nginx
    echo -e "${GREEN}修改完成！访问: https://$DOMAIN${RESET}"
    pause
}

delete_config() {
    CONFIG_DIR="/etc/nginx/sites-available"
    [ ! -d "$CONFIG_DIR" ] && echo -e "${YELLOW}没有配置文件！${RESET}" && pause && return

    DOMAINS=($(ls "$CONFIG_DIR" | grep -vE 'default|default_server_block' | sort))
    [ ${#DOMAINS[@]} -eq 0 ] && echo -e "${YELLOW}没有域名配置！${RESET}" && pause && return

    echo -e "${GREEN}可删除的域名:${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo -e "${GREEN}$((i+1))) ${DOMAINS[$i]}${RESET}"
    done

    echo -ne "${GREEN}请选择编号 (0 返回): ${RESET}"
    read choice
    if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}已取消${RESET}"; return
    fi
    if [ "$choice" -eq 0 ]; then return; fi
    if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效选择${RESET}"; pause; return
    fi

    DOMAIN="${DOMAINS[$((choice-1))]}"

    # 删除配置文件
    rm -f "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"

    # 询问是否删除证书
    echo -ne "${YELLOW}是否同时删除证书 $DOMAIN ? (y/N): ${RESET}"
    read del_cert
    if [[ "$del_cert" =~ ^[Yy]$ ]]; then
        certbot delete --cert-name "$DOMAIN" || true
        echo -e "${GREEN}证书已删除${RESET}"
    else
        echo -e "${YELLOW}证书保留${RESET}"
    fi

    # 检查并重载 Nginx
    if nginx -t; then
        systemctl reload nginx
        echo -e "${GREEN}域名 $DOMAIN 已删除${RESET}"
    else
        echo -e "${RED}Nginx 配置测试失败，请检查！${RESET}"
    fi
    pause
}


test_renew() {
    CONFIG_DIR="/etc/nginx/sites-available"
    [ ! -d "$CONFIG_DIR" ] && echo -e "${YELLOW}没有配置文件${RESET}" && pause && return

    DOMAINS=($(ls "$CONFIG_DIR" | grep -vE 'default|default_server_block' | sort))
    [ ${#DOMAINS[@]} -eq 0 ] && echo -e "${YELLOW}没有域名配置！${RESET}" && pause && return

    echo -e "${GREEN}已有配置:${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo -e "${GREEN}$((i+1))) ${DOMAINS[$i]}${RESET}"
    done

    echo -ne "${GREEN}选择编号 (0 返回): ${RESET}"
    read choice
    if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}已取消${RESET}"; return
    fi
    if [ "$choice" -eq 0 ]; then return; fi
    if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效选择${RESET}"; pause; return
    fi

    DOMAIN="${DOMAINS[$((choice-1))]}"
    echo -e "${GREEN}正在测试 $DOMAIN 的证书续期...${RESET}"
    certbot renew --dry-run --cert-name "$DOMAIN"
    pause
}

check_cert() {
    CERT_DIR="/etc/letsencrypt/live"
    if [ ! -d "$CERT_DIR" ]; then
        echo -e "${GREEN}没有找到任何证书"
        pause
        return
    fi

    echo -e "${GREEN}现有证书的域名：${RESET}"
    i=1
    DOMAINS=()
    for DOMAIN in $(ls "$CERT_DIR"); do
        if [ -f "$CERT_DIR/$DOMAIN/fullchain.pem" ]; then
            echo -e "${GREEN}$i) $DOMAIN${RESET}"
            DOMAINS+=("$DOMAIN")
            i=$((i+1))
        fi
    done

    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${GREEN}没有找到任何有效证书${RESET}"
        pause
        return
    fi

    echo -ne "${GREEN}请选择要查看的域名编号 (0 返回): ${RESET}"
    read choice

    # 如果输入为空或不是数字
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo -e "${GREEN}无效输入${RESET}"
        pause
        return
    fi

    if [ "$choice" -eq 0 ]; then
        return
    fi

    if [ "$choice" -ge 1 ] && [ "$choice" -le ${#DOMAINS[@]} ]; then
        SELECTED=${DOMAINS[$((choice-1))]}
        certbot certificates --cert-name "$SELECTED"
    else
        echo -e "${GREEN}无效选择${RESET}"
    fi
    pause
}


check_domains_status() {
    echo -e "${GREEN}域名                  状态       到期时间        剩余天数${RESET}"
    echo -e "${GREEN}------------------------------------------------------------${RESET}"

    CERT_DIR="/etc/letsencrypt/live"
    [ ! -d "$CERT_DIR" ] && echo -e "${GREEN}没有找到任何证书${RESET}" && pause && return

    DOMAINS=($(ls "$CERT_DIR" | grep -vE 'default|default_server_block' | sort))
    for DOMAIN in "${DOMAINS[@]}"; do
        CERT_PATH="$CERT_DIR/$DOMAIN/fullchain.pem"
        if [ -f "$CERT_PATH" ]; then
            END_DATE=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
            END_TS=$(date -d "$END_DATE" +%s)
            NOW_TS=$(date +%s)
            DAYS_LEFT=$(( (END_TS - NOW_TS) / 86400 ))

            if [ $DAYS_LEFT -ge 30 ]; then
                STATUS="有效"
            elif [ $DAYS_LEFT -ge 0 ]; then
                STATUS="即将过期"
            else
                STATUS="已过期"
            fi

            printf "%-22s %-10s %-15s %d 天\n" \
                "$DOMAIN" "$STATUS" "$(date -d "$END_DATE" +"%Y-%m-%d")" "$DAYS_LEFT"
        fi
    done
    pause
}

uninstall_nginx() {
    echo -e "${YELLOW}卸载 Nginx...${RESET}"
    systemctl stop nginx || true
    apt purge -y nginx nginx-common nginx-core certbot python3-certbot-nginx || true
    apt autoremove -y
    rm -rf /etc/nginx /etc/letsencrypt
    remove_default_server
    echo -e "${GREEN}已卸载${RESET}"
    pause
}

# ------------------------------
# 主菜单
# ------------------------------
while true; do
    clear
    echo -e "${GREEN}===== Nginx 管理脚本 =====${RESET}"
    echo -e "${GREEN}1) 安装 Nginx证书${RESET}"
    echo -e "${GREEN}2) 添加配置${RESET}"
    echo -e "${GREEN}3) 修改配置${RESET}"
    echo -e "${GREEN}4) 删除配置${RESET}"
    echo -e "${GREEN}5) 测试证书续期${RESET}"
    echo -e "${GREEN}6) 查看证书信息${RESET}"
    echo -e "${GREEN}7) 卸载 Nginx证书${RESET}"
    echo -e "${GREEN}8) 查看域名证书状态${RESET}"
    echo -e "${GREEN}9) 重载 Nginx 配置${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -ne "${GREEN}请选择[0-9]: ${RESET}"
    read choice
    case $choice in
        1) install_nginx ;;
        2) add_config ;;
        3) modify_config ;;
        4) delete_config ;;
        5) test_renew ;;
        6) check_cert ;;
        7) uninstall_nginx ;;
        8) check_domains_status ;;
        9) nginx -t && systemctl reload nginx && echo -e "${GREEN}Nginx 配置已重载成功${RESET}" || echo -e "${RED}配置检查失败，请修复后重试${RESET}"; pause ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ; pause ;;
    esac
done
