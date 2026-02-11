#!/bin/bash
# ==========================================
# Nginx HTTPS 反代管理脚本（已有证书）
# 支持：添加 / 修改 / 删除 / 查看 / 安装 / 卸载
# ==========================================

set -e

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"
REQUIRED_PORTS=(80 443)

# ---------------------------
# 工具函数
# ---------------------------
pause() {
    echo -ne "${GREEN}按回车返回菜单...${RESET}"
    read
}

list_sites() {
    ls "$SITES_AVAILABLE" 2>/dev/null | grep "\.conf$" | sed 's/\.conf$//'
}

nginx_reload() {
    nginx -t && systemctl reload nginx
}

# ---------------------------
# 系统检测
# ---------------------------
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        OS=$(uname -s)
    fi
}

# ---------------------------
# 安装 / 更新 Nginx 与 Certbot
# ---------------------------
configure_firewall() {
    echo -e "${GREEN}检测并配置防火墙以开放必要端口...${RESET}"

    if command -v ufw >/dev/null 2>&1; then
        ufw_status=$(ufw status | head -n 1)
        if [[ "$ufw_status" == "Status: inactive" ]]; then
            echo "ufw 未启用，正在启用..."
            ufw --force enable
        fi
        for port in "${REQUIRED_PORTS[@]}"; do
            if ! ufw status | grep -qw "$port"; then
                echo "允许端口 $port ..."
                ufw allow "$port"
            fi
        done
        return
    fi

    if systemctl is-active --quiet firewalld; then
        for port in "${REQUIRED_PORTS[@]}"; do
            if ! firewall-cmd --list-ports | grep -qw "${port}/tcp"; then
                firewall-cmd --permanent --add-port=${port}/tcp
            fi
        done
        firewall-cmd --reload
        return
    fi

    if command -v iptables >/dev/null 2>&1; then
        for port in "${REQUIRED_PORTS[@]}"; do
            if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
            fi
        done
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save
        elif command -v service >/dev/null 2>&1; then
            service iptables save
        fi
        return
    fi
}

install_nginx_certbot() {
    detect_os
    echo -e "${GREEN}安装/更新 Nginx 与 Certbot ...${RESET}"
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt update
        apt install -y nginx certbot python3-certbot-nginx
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
        yum install -y epel-release
        yum install -y nginx certbot python3-certbot-nginx
    else
        echo -e "${RED}无法自动安装，请手动安装 Nginx 与 Certbot${RESET}"
        pause
        return
    fi

    configure_firewall

    mkdir -p "$SITES_AVAILABLE" "$SITES_ENABLED"

    systemctl enable nginx
    systemctl start nginx

    echo -e "${GREEN}Nginx安装完成！${RESET}"
    pause
}

# ---------------------------
# 卸载 Nginx 与 Certbot
# ---------------------------
uninstall_nginx_certbot() {

    echo -e "${GREEN}停止 Nginx 服务...${RESET}"
    systemctl stop nginx
    systemctl disable nginx

    detect_os
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt remove -y nginx certbot python3-certbot-nginx
        apt autoremove -y
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
        yum remove -y nginx certbot python3-certbot-nginx
    fi

    echo -e "${GREEN}卸载完成${RESET}"
    pause
}


# ---------------------------
# 添加站点
# ---------------------------
add_site() {
    read -p "请输入域名 (例如 example.com): " DOMAIN
    read -p "请输入证书所在目录 (例如 /etc/nginx/ssl): " CERT_DIR

    if [[ ! -d "$CERT_DIR" ]]; then
        echo -e "${RED}目录不存在${RESET}"
        pause
        return
    fi

    # 查找证书文件
    CERT_FILES=($(find "$CERT_DIR" -maxdepth 1 -type f \( -name "*.crt" -o -name "*.pem" \)))
    if [ ${#CERT_FILES[@]} -eq 0 ]; then
        echo -e "${RED}没有找到证书文件，请手动输入路径${RESET}"
        read -p "请输入证书路径(例如 /etc/nginx/ssl/example.com.pem): " CERT_PATH
        read -p "请输入密钥路径(例如 /etc/nginx/ssl/example.com.key): " KEY_PATH
    else
        echo -e "${GREEN}=== 可选择证书列表 ===${RESET}"
        for i in "${!CERT_FILES[@]}"; do
            FILE_NAME=$(basename "${CERT_FILES[$i]}")
            DOMAIN_NAME="${FILE_NAME%.*}"
            printf "${GREEN}%d) %s${RESET}\n" $((i+1)) "$DOMAIN_NAME"
        done
        echo -e "${GREEN}0) 手动输入证书和密钥路径${RESET}"
        read -p "请选择证书编号: " cert_idx
        if [[ "$cert_idx" == "0" ]]; then
            read -p "请输入证书路径(例如 /etc/nginx/ssl/example.com.pem): " CERT_PATH
            read -p "请输入密钥路径(例如 /etc/nginx/ssl/example.com.key): " KEY_PATH
        else
            if ! [[ "$cert_idx" =~ ^[0-9]+$ ]] || [ "$cert_idx" -lt 1 ] || [ "$cert_idx" -gt "${#CERT_FILES[@]}" ]; then
                echo -e "${RED}无效编号${RESET}"
                pause
                return
            fi
            CERT_PATH="${CERT_FILES[$((cert_idx-1))]}"
            KEY_PATH="${CERT_PATH%.*}.key"
            if [[ ! -f "$KEY_PATH" ]]; then
                read -p "请输入密钥路径(例如 /etc/nginx/ssl/example.com.key): " KEY_PATH
            fi
        fi
    fi

    read -p "请输入反代目标地址 (例如 http://127.0.0.1:8000): " TARGET
    read -p "请输入上传文件大小限制 (例如 50M，默认 50M): " UPLOAD_SIZE
    UPLOAD_SIZE=${UPLOAD_SIZE:-50M}   # 默认值50M

    CONFIG_PATH="$SITES_AVAILABLE/$DOMAIN.conf"
    if [[ -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}站点已存在！${RESET}"
        pause
        return
    fi

    cat > "$CONFIG_PATH" <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    client_max_body_size $UPLOAD_SIZE;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;

    location / {
        proxy_pass $TARGET;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF

    ln -sf "$CONFIG_PATH" "$SITES_ENABLED/$DOMAIN.conf"
    nginx_reload
    echo -e "${GREEN}站点 $DOMAIN 添加成功！${RESET}"
    pause
}

# ---------------------------
# 修改站点
# ---------------------------
modify_site() {
    SITES=($(list_sites))
    if [ ${#SITES[@]} -eq 0 ]; then
        echo -e "${RED}没有可修改的站点${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}=== 可修改站点列表 ===${RESET}"
    for i in "${!SITES[@]}"; do
        printf "${GREEN}%d) %s${RESET}\n" $((i+1)) "${SITES[$i]}"
    done
    echo -e "${GREEN}0) 取消${RESET}"
    read -p "请输入要修改的站点编号: " idx
    if [[ "$idx" == "0" ]]; then return; fi
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#SITES[@]}" ]; then
        echo -e "${RED}无效编号${RESET}"
        pause
        return
    fi

    SITE="${SITES[$((idx-1))]}"
    CONFIG_PATH="$SITES_AVAILABLE/$SITE.conf"
    echo -e "${GREEN}正在修改站点 $SITE 配置：${RESET}"

    read -p "请输入新的证书路径 (回车保持不变): " NEW_CERT
    read -p "请输入新的私钥路径 (回车保持不变): " NEW_KEY
    read -p "请输入新的反代目标地址 (回车保持不变): " NEW_TARGET
    read -p "请输入新的上传大小 (回车保持不变): " NEW_SIZE

    [[ -n "$NEW_CERT" ]] && sed -i "s|ssl_certificate .*;|ssl_certificate $NEW_CERT;|" "$CONFIG_PATH"
    [[ -n "$NEW_KEY" ]] && sed -i "s|ssl_certificate_key .*;|ssl_certificate_key $NEW_KEY;|" "$CONFIG_PATH"
    [[ -n "$NEW_TARGET" ]] && sed -i "s|proxy_pass .*;|proxy_pass $NEW_TARGET;|" "$CONFIG_PATH"
    [[ -n "$NEW_SIZE" ]] && sed -i "s|client_max_body_size .*;|client_max_body_size $NEW_SIZE;|" "$CONFIG_PATH"

    nginx_reload
    echo -e "${GREEN}站点 $SITE 修改成功！${RESET}"
    pause
}

# ---------------------------
# 删除站点
# ---------------------------
delete_site() {
    SITES=($(list_sites))
    if [ ${#SITES[@]} -eq 0 ]; then
        echo -e "${RED}没有可删除的站点${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}=== 可删除站点列表 ===${RESET}"
    for i in "${!SITES[@]}"; do
        printf "${GREEN}%d) %s${RESET}\n" $((i+1)) "${SITES[$i]}"
    done
    echo -e "${GREEN}0) 取消${RESET}"
    read -p "请输入要删除的站点编号: " idx
    if [[ "$idx" == "0" ]]; then return; fi
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#SITES[@]}" ]; then
        echo -e "${RED}无效编号${RESET}"
        pause
        return
    fi

    SITE="${SITES[$((idx-1))]}"
    rm -f "$SITES_AVAILABLE/$SITE.conf"
    rm -f "$SITES_ENABLED/$SITE.conf"

    nginx_reload
    echo -e "${GREEN}站点 $SITE 删除成功！${RESET}"
    pause
}

# ---------------------------
# 查看站点
# ---------------------------
view_sites() {
    SITES=($(list_sites))
    if [ ${#SITES[@]} -eq 0 ]; then
        echo -e "${RED}没有配置的站点${RESET}"
    else
        echo -e "${GREEN}=== 已配置站点 ===${RESET}"
        for i in "${!SITES[@]}"; do
            printf "${GREEN}%d) %s${RESET}\n" $((i+1)) "${SITES[$i]}"
        done
    fi
    pause
}

# ---------------------------
# 主菜单
# ---------------------------
while true; do
    clear
    echo -e "${GREEN}=== Nginx证书反代管理 ===${RESET}"
    echo -e "${GREEN}1) 安装Nginx${RESET}"
    echo -e "${GREEN}2) 添加站点配置${RESET}"
    echo -e "${GREEN}3) 修改站点配置${RESET}"
    echo -e "${GREEN}4) 删除站点配置${RESET}"
    echo -e "${GREEN}5) 查看站点信息${RESET}"
    echo -e "${GREEN}6) 卸载Nginx${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "请选择操作[0-6]: " choice

    case "$choice" in
        1) install_nginx_certbot ;;
        2) add_site ;;
        3) modify_site ;;
        4) delete_site ;;
        5) view_sites ;;
        6) uninstall_nginx_certbot ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}"; pause ;;
    esac
done
