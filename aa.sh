#!/bin/bash
# ========================================
# 哪吒面板 Nginx 反向代理管理脚本（完整优化版）
# ========================================

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

CONFIG_DIR="/etc/nginx/sites-available"
ENABLED_DIR="/etc/nginx/sites-enabled"

mkdir -p "$CONFIG_DIR" "$ENABLED_DIR"

pause() {
    read -p "按回车返回..."
}

# ------------------------------
# 系统检测
# ------------------------------
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        OS=$(uname -s)
    fi
}

# ------------------------------
# 配置防火墙
# ------------------------------
configure_firewall() {
    echo -e "${GREEN}检测并配置防火墙以开放必要端口...${RESET}"

    if command -v ufw >/dev/null 2>&1; then
        echo "检测到 ufw 防火墙。"
        ufw_status=$(ufw status | head -n 1)
        if [[ "$ufw_status" == "Status: inactive" ]]; then
            echo "ufw 未启用，正在启用..."
            ufw --force enable
        fi
        for port in "${REQUIRED_PORTS[@]}"; do
            if ! ufw status | grep -qw "$port"; then
                echo "允许端口 $port ..."
                ufw allow "$port"
            else
                echo "端口 $port 已经开放。"
            fi
        done
        return
    fi

    if systemctl is-active --quiet firewalld; then
        echo "检测到 firewalld 防火墙。"
        for port in "${REQUIRED_PORTS[@]}"; do
            if ! firewall-cmd --list-ports | grep -qw "${port}/tcp"; then
                echo "允许端口 $port ..."
                firewall-cmd --permanent --add-port=${port}/tcp
            else
                echo "端口 $port 已经开放。"
            fi
        done
        firewall-cmd --reload
        return
    fi

    if command -v iptables >/dev/null 2>&1; then
        echo "检测到 iptables 防火墙。"
        for port in "${REQUIRED_PORTS[@]}"; do
            if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                echo "允许端口 $port ..."
                iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
            else
                echo "端口 $port 已经开放。"
            fi
        done
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save
        elif command -v service >/dev/null 2>&1; then
            service iptables save
        fi
        return
    fi

    echo -e "${YELLOW}未检测到已知防火墙工具，请手动确保端口 ${REQUIRED_PORTS[*]} 已开放。${RESET}"
}

# ------------------------------
# 安装 Certbot
# ------------------------------
install_certbot() {
    if ! command -v certbot >/dev/null 2>&1; then
        echo -e "${GREEN}正在安装 Certbot...${RESET}"
        if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
            apt update
            apt install -y certbot python3-certbot-nginx
        elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
            yum install -y epel-release
            yum install -y certbot python3-certbot-nginx
        else
            echo -e "${RED}无法自动安装 Certbot，请手动安装。${RESET}"
            exit 1
        fi
        echo -e "${GREEN}Certbot 安装完成。${RESET}"
    else
        echo -e "${GREEN}Certbot 已经安装。${RESET}"
    fi
}

# ------------------------------
# 安装 Nginx
# ------------------------------
install_nginx() {
    echo -e "${GREEN}安装或更新 Nginx...${RESET}"
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt update && apt upgrade -y
        apt install -y nginx
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
        yum install -y epel-release
        yum install -y nginx
    else
        echo -e "${RED}无法自动安装 Nginx，请手动安装。${RESET}"
        exit 1
    fi

    configure_firewall

    mkdir -p "$CONFIG_DIR" "$ENABLED_DIR"

    systemctl start nginx
    systemctl enable nginx
    echo -e "${GREEN}Nginx 安装完成！${RESET}"
}

# ------------------------------
# 初始化环境
# ------------------------------
init_env() {
    detect_os
    install_nginx
    install_certbot
}

# ------------------------------
# 获取当前所有域名列表
# ------------------------------
get_domain_list() {
    DOMAINS=()
    for f in "$CONFIG_DIR"/*.conf; do
        [ -e "$f" ] || continue
        DOMAINS+=("$(basename "$f" .conf)")
    done
}

# ------------------------------
# 添加域名配置
# ------------------------------
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

    # 上游服务配置
    read -p "请输入上游服务地址 (默认 127.0.0.1): " UPSTREAM_HOST
    UPSTREAM_HOST=${UPSTREAM_HOST:-127.0.0.1}
    read -p "请输入上游服务端口 (默认 8008): " UPSTREAM_PORT
    UPSTREAM_PORT=${UPSTREAM_PORT:-8008}

    # CDN 回源设置
    echo "CDN 回源已默认开启"
    read -p "请输入你的 CDN 回源 IP 地址段 (默认 173.245.48.0/20): " CDN_IP_RANGE
    CDN_IP_RANGE=${CDN_IP_RANGE:-173.245.48.0/20}
    read -p "请输入 CDN 提供的私有 Header 名称 (默认 CF-Connecting-IP): " CDN_HEADER
    CDN_HEADER=${CDN_HEADER:-CF-Connecting-IP}

    REAL_IP_CONFIG="set_real_ip_from $CDN_IP_RANGE;
    real_ip_header $CDN_HEADER;"
    HEADER_VAR="\$http_${CDN_HEADER//-/_}"

    # 写入 Nginx 配置
    CONFIG_PATH="$CONFIG_DIR/$DOMAIN.conf"
    ENABLED_PATH="$ENABLED_DIR/$DOMAIN.conf"

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

    # 启用配置
    rm -f "$ENABLED_PATH"
    ln -s "$CONFIG_PATH" "$ENABLED_DIR/"

    nginx -t && systemctl reload nginx
    echo -e "${GREEN}域名 $DOMAIN 配置完成！${RESET}"
    pause
}

# ------------------------------
# 修改域名配置
# ------------------------------
modify_site() {
    get_domain_list
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${RED}暂无已配置的域名${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}=== 已配置的域名 ===${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo "$((i+1)). ${DOMAINS[$i]}"
    done
    echo "0. 返回"

    read -p "请输入要修改的域名编号: " choice
    if [ "$choice" == "0" ]; then
        return
    fi

    INDEX=$((choice-1))
    if [ $INDEX -lt 0 ] || [ $INDEX -ge ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效编号${RESET}"
        pause
        return
    fi

    DOMAIN="${DOMAINS[$INDEX]}"
    CONFIG_PATH="$CONFIG_DIR/$DOMAIN.conf"
    ENABLED_PATH="$ENABLED_DIR/$DOMAIN.conf"

    echo -e "${GREEN}修改域名 $DOMAIN 配置${RESET}"

    # 使用与 add_site 相同的证书选择逻辑
    add_site_for_modify "$DOMAIN"
}

# 为修改复用添加流程（避免重复代码）
add_site_for_modify() {
    local DOMAIN="$1"
    read -p "请输入证书所在目录 (例如 /etc/nginx/ssl): " CERT_DIR

    if [[ ! -d "$CERT_DIR" ]]; then
        echo -e "${RED}目录不存在${RESET}"
        pause
        return
    fi

    CERT_FILES=($(find "$CERT_DIR" -maxdepth 1 -type f \( -name "*.crt" -o -name "*.pem" \)))
    if [ ${#CERT_FILES[@]} -eq 0 ]; then
        echo -e "${RED}没有找到证书文件，请手动输入路径${RESET}"
        read -p "请输入证书路径: " CERT_PATH
        read -p "请输入密钥路径: " KEY_PATH
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
            read -p "请输入证书路径: " CERT_PATH
            read -p "请输入密钥路径: " KEY_PATH
        else
            CERT_PATH="${CERT_FILES[$((cert_idx-1))]}"
            KEY_PATH="${CERT_PATH%.*}.key"
            if [[ ! -f "$KEY_PATH" ]]; then
                read -p "请输入密钥路径: " KEY_PATH
            fi
        fi
    fi

    # 上游服务地址
    read -p "请输入上游服务地址 (默认 127.0.0.1): " UPSTREAM_HOST
    UPSTREAM_HOST=${UPSTREAM_HOST:-127.0.0.1}
    read -p "请输入上游服务端口 (默认 8008): " UPSTREAM_PORT
    UPSTREAM_PORT=${UPSTREAM_PORT:-8008}

    # CDN 回源设置
    echo "CDN 回源已默认开启"
    read -p "请输入你的 CDN 回源 IP 地址段 (默认 173.245.48.0/20): " CDN_IP_RANGE
    CDN_IP_RANGE=${CDN_IP_RANGE:-173.245.48.0/20}
    read -p "请输入 CDN 提供的私有 Header 名称 (默认 CF-Connecting-IP): " CDN_HEADER
    CDN_HEADER=${CDN_HEADER:-CF-Connecting-IP}

    REAL_IP_CONFIG="set_real_ip_from $CDN_IP_RANGE;
    real_ip_header $CDN_HEADER;"
    HEADER_VAR="\$http_${CDN_HEADER//-/_}"

    # 写入 Nginx 配置
    CONFIG_PATH="$CONFIG_DIR/$DOMAIN.conf"
    ENABLED_PATH="$ENABLED_DIR/$DOMAIN.conf"

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

    # 启用配置
    rm -f "$ENABLED_PATH"
    ln -s "$CONFIG_PATH" "$ENABLED_DIR/"

    nginx -t && systemctl reload nginx
    echo -e "${GREEN}域名 $DOMAIN 配置修改完成！${RESET}"
    pause
}

# ------------------------------
# 删除域名配置
# ------------------------------
delete_site() {
    get_domain_list
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${RED}暂无已配置的域名${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}=== 已配置的域名 ===${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo "$((i+1)). ${DOMAINS[$i]}"
    done
    echo "0. 返回"

    read -p "请输入要删除的域名编号: " choice
    if [ "$choice" == "0" ]; then
        return
    fi

    INDEX=$((choice-1))
    if [ $INDEX -lt 0 ] || [ $INDEX -ge ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效编号${RESET}"
        pause
        return
    fi

    DOMAIN="${DOMAINS[$INDEX]}"
    CONFIG_PATH="$CONFIG_DIR/$DOMAIN.conf"
    ENABLED_PATH="$ENABLED_DIR/$DOMAIN.conf"

    rm -f "$CONFIG_PATH" "$ENABLED_PATH"
    nginx -t && systemctl reload nginx
    echo -e "${GREEN}已删除 $DOMAIN 配置${RESET}"
    pause
}

# ------------------------------
# 查看域名信息
# ------------------------------
list_sites() {
    get_domain_list
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${RED}暂无已配置的域名${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}=== 已配置的域名 ===${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo "$((i+1)). ${DOMAINS[$i]}"
    done
    echo "0. 返回"

    read -p "请输入要查看的域名编号: " choice
    if [ "$choice" == "0" ]; then
        return
    fi

    INDEX=$((choice-1))
    if [ $INDEX -lt 0 ] || [ $INDEX -ge ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效编号${RESET}"
        pause
        return
    fi

    DOMAIN="${DOMAINS[$INDEX]}"
    CONFIG_PATH="$CONFIG_DIR/$DOMAIN.conf"

    echo -e "${GREEN}====== $DOMAIN 配置详情 ======${RESET}"
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
    pause
}

# ------------------------------
# 主菜单
# ------------------------------
main_menu() {
    while true; do
        clear
        echo -e "${GREEN}====== 哪吒反向代理管理 ======${RESET}"
        echo -e "${GREEN}1. 安装Nginx${RESET}"
        echo -e "${GREEN}2. 添加域名配置${RESET}"
        echo -e "${GREEN}3. 删除域名配置${RESET}"
        echo -e "${GREEN}4. 查看已配置域名信息${RESET}"
        echo -e "${GREEN}5. 修改已有域名配置${RESET}"
        echo -e "${GREEN}0. 退出${RESET}"
        read -p "请选择 [0-5]: " choice
        case $choice in
            1) init_env ;;   
            2) add_site ;;
            3) delete_site ;;
            4) list_sites ;;
            5) modify_site ;;
            0) exit 0 ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

main_menu
