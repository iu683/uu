#!/bin/bash
# ===============================================
# Cloudflare SSL + Nginx 管理脚本（多域名 + WS 反代）
# 每次申请证书都手动输入 Cloudflare API 信息
# ===============================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

DOMAIN_FILE="$HOME/cf_domains.list"
ACME_SH="$HOME/.acme.sh/acme.sh"

declare -A BACKEND_MAP

# ================= 安装 acme.sh =================
install_acme() {
    if [ ! -f "$ACME_SH" ]; then
        echo -e "${YELLOW}安装 acme.sh...${RESET}"
        curl https://get.acme.sh | sh
        source ~/.bashrc
    fi
    $ACME_SH --set-default-ca --server letsencrypt
    echo -e "${GREEN}acme.sh 安装完成${RESET}"
}

# ================= 安装 Nginx =================
install_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        echo -e "${YELLOW}安装 Nginx...${RESET}"
        if [ -f /etc/debian_version ]; then
            apt update && apt install -y nginx
        elif [ -f /etc/redhat-release ]; then
            yum install -y epel-release && yum install -y nginx
        else
            echo -e "${RED}未识别系统，请手动安装 Nginx${RESET}"
            return
        fi
        systemctl enable nginx
        systemctl start nginx
        echo -e "${GREEN}Nginx 已安装并启动${RESET}"
    else
        echo -e "${GREEN}检测到 Nginx 已安装${RESET}"
    fi
}

# ================= 域名管理 =================
get_domain_array() {
    [ ! -f "$DOMAIN_FILE" ] && touch "$DOMAIN_FILE"
    DOMAIN_LIST=$(cat "$DOMAIN_FILE")
    DOMAIN_ARR=($DOMAIN_LIST)
}

add_or_modify_domain() {
    echo -e "${GREEN}请输入要添加/修改的域名（可空格分隔多个）:${RESET}"
    read -r NEW_DOMAINS
    if [ -n "$NEW_DOMAINS" ]; then
        echo "$NEW_DOMAINS" >> "$DOMAIN_FILE"
        sort -u "$DOMAIN_FILE" -o "$DOMAIN_FILE"
    fi
    echo -e "${GREEN}当前域名列表:${RESET}"
    cat "$DOMAIN_FILE"
}

# ================= 设置反代目标 =================
set_backend_for_domains() {
    get_domain_array
    for DOMAIN in "${DOMAIN_ARR[@]}"; do
        read -p "请输入 $DOMAIN 的反代目标 (如 http://127.0.0.1:8080): " TARGET
        BACKEND_MAP["$DOMAIN"]=$TARGET
    done
}

# ================= 证书路径 =================
cert_path() {
    echo "/etc/ssl/$1"
}

# ================= 一键批量操作 =================
one_click_all() {
    get_domain_array
    [ ${#DOMAIN_ARR[@]} -eq 0 ] && { echo -e "${RED}没有域名，请先添加域名${RESET}"; return; }

    set_backend_for_domains

    for DOMAIN in "${DOMAIN_ARR[@]}"; do
        echo -e "${GREEN}处理 $DOMAIN ...${RESET}"
        TARGET=${BACKEND_MAP["$DOMAIN"]}
        CERT_DIR=$(cert_path "$DOMAIN")
        KEY_FILE="$CERT_DIR/private.key"
        FULLCHAIN_FILE="$CERT_DIR/fullchain.cer"
        mkdir -p "$CERT_DIR"

        # ⚠️ 每次申请证书都输入 Cloudflare API 信息
        read -p "请输入 Cloudflare API Token: " CF_Token
        read -p "请输入 Cloudflare 账户 ID: " CF_Account_ID
        export CF_Token CF_Account_ID

        # 申请证书
        $ACME_SH --issue --dns dns_cf -d "$DOMAIN"
        $ACME_SH --install-cert -d "$DOMAIN" \
            --key-file "$KEY_FILE" \
            --fullchain-file "$FULLCHAIN_FILE" \
            --reloadcmd "nginx -s reload"

        # 生成 Nginx 配置
        nginx_conf="/etc/nginx/conf.d/$DOMAIN.conf"
        cat > "$nginx_conf" <<EOF
server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate $FULLCHAIN_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass $TARGET;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF
        echo -e "${GREEN}$DOMAIN 完成证书 + 配置生成${RESET}"
    done

    # 检查 Nginx 配置并重载
    if nginx -t; then
        nginx -s reload
        echo -e "${GREEN}所有域名处理完成，Nginx 已重载${RESET}"
    else
        echo -e "${RED}Nginx 配置有误，请检查${RESET}"
    fi
}

# ================= 删除域名 =================
delete_domain() {
    get_domain_array
    if [ ${#DOMAIN_ARR[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有域名可删除${RESET}"
        return
    fi
    echo -e "${YELLOW}请选择要删除的域名:${RESET}"
    select DOMAIN in "${DOMAIN_ARR[@]}" "取消"; do
        [ "$DOMAIN" == "取消" ] && return
        CERT_DIR=$(cert_path "$DOMAIN")
        # ⚠️ 删除证书前也需要输入 CF 信息
        read -p "请输入 Cloudflare API Token: " CF_Token
        read -p "请输入 Cloudflare 账户 ID: " CF_Account_ID
        export CF_Token CF_Account_ID

        $ACME_SH --remove -d "$DOMAIN"
        rm -rf "$CERT_DIR"
        rm -f "/etc/nginx/conf.d/$DOMAIN.conf"
        grep -v "^$DOMAIN\$" "$DOMAIN_FILE" > "$DOMAIN_FILE.tmp" && mv "$DOMAIN_FILE.tmp" "$DOMAIN_FILE"
        nginx -s reload
        echo -e "${GREEN}$DOMAIN 已删除证书和配置并重载 Nginx${RESET}"
        break
    done
}

# ================= 主菜单 =================
while true; do
    echo -e "${GREEN}======================${RESET}"
    echo -e "${GREEN} Cloudflare SSL + Nginx 多域名管理（WS 支持）${RESET}"
    echo -e "${GREEN}======================${RESET}"
    echo "1) 安装 acme.sh"
    echo "2) 安装 Nginx"
    echo "3) 添加/修改域名"
    echo "4) 一键批量操作（证书 + Nginx + WS）"
    echo "5) 删除域名及证书"
    echo "6) 退出"
    read -p "请选择操作 [1-6]: " choice
    case "$choice" in
        1) install_acme ;;
        2) install_nginx ;;
        3) add_or_modify_domain ;;
        4) one_click_all ;;
        5) delete_domain ;;
        6) echo "退出"; break ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
done
