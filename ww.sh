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
        echo -e "${GREEN}1. 添加域名配置${RESET}"
        echo -e "${GREEN}2. 删除域名配置${RESET}"
        echo -e "${GREEN}3. 查看已配置域名信息${RESET}"
        echo -e "${GREEN}4. 修改已有域名配置${RESET}"
        echo -e "${GREEN}0. 退出${RESET}"
        read -p "请选择 [0-4]: " choice
        case $choice in
            1) add_site ;;
            2) delete_site ;;
            3) list_sites ;;
            4) modify_site ;;
            0) exit 0 ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

main_menu
