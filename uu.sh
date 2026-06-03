#!/usr/bin/env bash
# ========================================================
# ◈ Nginx 反向代理多系统一键管理面板 ◈
# 支持系统: Alpine, Debian, Ubuntu, CentOS/Rocky
# ========================================================

set -euo pipefail

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# 全局路径变量 (兼容多系统)
NGINX_MAIN="/etc/nginx/nginx.conf"
HTTP_D="/etc/nginx/http.d"
CONF_PREFIX="proxy-lite-"
ACME_HOME="/root/.acme.sh"
CERT_HOME="/etc/nginx/certs"

# 检测系统环境
detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS="alpine"
        HTTP_D="/etc/nginx/http.d"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        HTTP_D="/etc/nginx/conf.d"
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
        HTTP_D="/etc/nginx/conf.d"
    else
        echo -e "${RED}未识别的系统，脚本可能无法完美运行。${RESET}"
        OS="unknown"
        HTTP_D="/etc/nginx/conf.d"
    fi
}

need_root() {
    [ "$(id -u)" -eq 0 ] || {
        echo -e "${RED}请使用 root 权限运行此脚本。${RESET}"
        exit 1
    }
}


pause() {
    echo -e "\n${YELLOW}按任意键返回主菜单...${RESET}"
    read -n 1 -s </dev/tty
}

generate_random_email() {
    local rand_num=$(openssl rand -hex 6 2>/dev/null || date +%s | tail -c 8)
    echo "${rand_num}@gmail.com"
}


prompt() {
    local var_name="$1" local text="$2" local default="${3:-}" local value=""
    if [ -n "$default" ]; then
        read -r -p "$text [$default]: " value </dev/tty || true
        value="${value:-$default}"
    else
        read -r -p "$text: " value </dev/tty || true
    fi
    printf -v "$var_name" '%s' "$value"
}

yesno() {
    local var_name="$1" local text="$2" local default="${3:-y}" local ans="" hint="y/N"
    [ "$default" = "y" ] && hint="Y/n"
    read -r -p "$text [$hint]: " ans </dev/tty || true
    ans="${ans:-$default}"
    case "$ans" in
        y|Y|yes|YES) printf -v "$var_name" 'y' ;;
        *) printf -v "$var_name" 'n' ;;
    esac
}

strip_scheme() {
    local s="${1:-}"
    s="${s#http://}" && s="${s#https://}" && s="${s%%/*}"
    echo "$s"
}

sanitize_name() {
    echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

is_port() {
    local p="${1:-}"
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

is_valid_email() {
    [[ "${1:-}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

# 动态获取面板状态数据
get_panel_status() {
    if [ "$OS" = "alpine" ]; then
        if rc-service nginx status 2>&1 | grep -q "started"; then
            STATUS="${GREEN}已启动 (OpenRC)${RESET}"
        else
            STATUS="${RED}未运行${RESET}"
        fi
    else
        if systemctl is-active --quiet nginx 2>/dev/null; then
            STATUS="${GREEN}已启动 (Systemd)${RESET}"
        else
            STATUS="${RED}未运行${RESET}"
        fi
    fi

    if command -v nginx >/dev/null 2>&1; then
        VERSION_SHOW=$(nginx -v 2>&1 | cut -d'/' -f2)
    else
        VERSION_SHOW="${RED}未安装${RESET}"
    fi

    if [ -d "$HTTP_D" ]; then
        SITE_COUNT=$(find "$HTTP_D" -name "${CONF_PREFIX}*.conf" 2>/dev/null | wc -l)
    else
        SITE_COUNT=0
    fi
}

manage_nginx_service() {
    local action="$1"
    if [ "$OS" = "alpine" ]; then
        case "$action" in
            start) rc-service nginx start >/dev/null 2>&1 || true ;;
            stop) rc-service nginx stop >/dev/null 2>&1 || true ;;
            restart) rc-service nginx restart >/dev/null 2>&1 || true ;;
            reload) rc-service nginx reload >/dev/null 2>&1 || rc-service nginx restart >/dev/null 2>&1 ;;
            enable) rc-update add nginx default >/dev/null 2>&1 || true ;;
            disable) rc-update del nginx default >/dev/null 2>&1 || true ;;
        esac
    else
        case "$action" in
            start) systemctl start nginx >/dev/null 2>&1 || true ;;
            stop) systemctl stop nginx >/dev/null 2>&1 || true ;;
            restart) systemctl restart nginx >/dev/null 2>&1 || true ;;
            reload) systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 ;;
            enable) systemctl enable nginx >/dev/null 2>&1 || true ;;
            disable) systemctl disable nginx >/dev/null 2>&1 || true ;;
        esac
    fi
}

ensure_deps() {
    echo "==> 正在安装/检查系统依赖..."
    case "$OS" in
        alpine)
            apk add --no-cache nginx bash curl ca-certificates openssl socat apache2-utils iproute2 >/dev/null
            ;;
        debian)
            apt-get update -y >/dev/null
            apt-get install -y nginx bash curl ca-certificates openssl socat apache2-utils iproute2 >/dev/null
            ;;
        rhel)
            dnf install -y epel-release >/dev/null || true
            dnf install -y nginx bash curl ca-certificates openssl socat httpd-tools iproute2 >/dev/null
            ;;
    esac
}

ensure_dirs() {
    mkdir -p /run/nginx "$HTTP_D" /var/log/nginx "$CERT_HOME"
}

write_main_nginx_conf() {
    echo "==> 初始化轻量 nginx.conf ..."
    [ -f "$NGINX_MAIN" ] && cp -f "$NGINX_MAIN" "${NGINX_MAIN}.bak.$(date +%s)" || true

    cat > "$NGINX_MAIN" <<EOF
user nginx;
worker_processes auto;
pid /run/nginx/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    access_log off;

    include ${HTTP_D}/*.conf;
}
EOF
}

install_or_init_acme_sh() {
    if [ ! -x "${ACME_HOME}/acme.sh" ]; then
        local ACME_EMAIL=$(generate_random_email)
        echo "==> 正在使用随机 Gmail 邮箱安装 acme.sh: $ACME_EMAIL"
        curl -fsSL https://get.acme.sh | sh -s email="$ACME_EMAIL"
    fi
}

choose_ca_provider() {
    echo -e "${YELLOW}请选择证书签发机构 (CA Provider)：${RESET}"
    echo "1) Let's Encrypt (推荐，无限制快速签发)"
    echo "2) ZeroSSL"
    read -r -p "输入序号 [1-2]: " CA_CHOICE </dev/tty
    
    case "$CA_CHOICE" in
        2)
            echo "==> 切换默认 CA 为 ZeroSSL..."
            "${ACME_HOME}/acme.sh" --set-default-ca --server zerossl >/dev/null 2>&1 || true
            if [ ! -d "${ACME_HOME}/ca/zerossl" ] && [ ! -d "${ACME_HOME}/ca/acme.zerossl.com" ]; then
                local Z_EMAIL=$(generate_random_email)
                echo -e "${YELLOW}==> 首次使用 ZeroSSL，正在为您随机注册 Gmail 账号: ${Z_EMAIL}${RESET}"
                "${ACME_HOME}/acme.sh" --register-account -m "$Z_EMAIL" --server zerossl
            fi
            ;;
        *)
            echo "==> 切换默认 CA 为 Let's Encrypt..."
            "${ACME_HOME}/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
            ;;
    esac
}

choose_dns_provider() {
    echo -e "${YELLOW}请选择 DNS 提供商进行验证：${RESET}"
    echo "1) Cloudflare"
    echo "2) 阿里云 (Aliyun)"
    echo "3) 腾讯云 (DNSPod)"
    read -r -p "输入序号: " DNS_CHOICE </dev/tty
    case "$DNS_CHOICE" in
        1) DNS_PROVIDER="cloudflare" ;;
        2) DNS_PROVIDER="aliyun" ;;
        3) DNS_PROVIDER="dnspod" ;;
        *) echo -e "${RED}无效选择${RESET}"; return 1 ;;
    esac
}

setup_dns_env() {
    case "$1" in
        cloudflare)
            prompt CF_Token "请输入 Cloudflare API Token"
            [ -n "${CF_Token:-}" ] || { echo "CF_Token 不能为空"; return 1; }
            export CF_Token
            ;;
        aliyun)
            prompt Ali_Key "请输入阿里云 Ali_Key"
            prompt Ali_Secret "请输入阿里云 Ali_Secret"
            [ -n "${Ali_Key:-}" ] && [ -n "${Ali_Secret:-}" ] || { echo "Key/Secret 不能为空"; return 1; }
            export Ali_Key Ali_Secret
            ;;
        dnspod)
            prompt DP_Id "请输入 DNSPod DP_Id"
            prompt DP_Key "请输入 DNSPod DP_Key"
            [ -n "${DP_Id:-}" ] && [ -n "${DP_Key:-}" ] || { echo "ID/Key 不能为空"; return 1; }
            export DP_Id DP_Key
            ;;
    esac
}

issue_and_install_cert() {
    local domain="$1" local provider="$2"
    local cert_dir="${CERT_HOME}/${domain}"
    mkdir -p "$cert_dir"

    echo "==> 正在通过 DNS 验证申请证书: ${domain} ..."
    local dns_flag="dns_cf"
    [ "$provider" = "aliyun" ] && dns_flag="dns_ali"
    [ "$provider" = "dnspod" ] && dns_flag="dns_dp"

    "${ACME_HOME}/acme.sh" --issue --dns "$dns_flag" -d "$domain" --keylength ec-256 --force

    echo "==> 安装证书到系统目录..."
    "${ACME_HOME}/acme.sh" --install-cert -d "$domain" --ecc \
        --fullchain-file "${cert_dir}/fullchain.cer" \
        --key-file "${cert_dir}/private.key" \
        --reloadcmd "nginx -t && nginx -s reload || true"
}

# 2. 添加配置 (自动申请并托管证书)
add_common_site() {
    prompt DOMAIN "请输入反代域名"
    DOMAIN="$(strip_scheme "$DOMAIN")"
    [ -n "$DOMAIN" ] || return 1

    prompt LISTEN_PORT "请输入本机监听端口" "443"
    is_port "$LISTEN_PORT" || return 1

    prompt UP_HOST "请输入反代后端 IP/主机名 (如 127.0.0.1)" "127.0.0.1"
    prompt UP_PORT "请输入反代后端端口" "80"
    is_port "$UP_PORT" || return 1

    choose_ca_provider || return 1

    choose_dns_provider || return 1
    setup_dns_env "$DNS_PROVIDER" || return 1
    issue_and_install_cert "$DOMAIN" "$DNS_PROVIDER"

    local conf_path="${HTTP_D}/${CONF_PREFIX}$(sanitize_name "$DOMAIN")-${LISTEN_PORT}.conf"
    local cert_dir="${CERT_HOME}/${DOMAIN}"

    cat > "$conf_path" <<EOF
# META domain=${DOMAIN} port=${LISTEN_PORT} upstream=http://${UP_HOST}:${UP_PORT} type=common_acme
server {
    listen ${LISTEN_PORT} ssl;
    listen [::]:${LISTEN_PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${cert_dir}/fullchain.cer;
    ssl_certificate_key ${cert_dir}/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://${UP_HOST}:${UP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    nginx -t && manage_nginx_service reload
    echo -e "${GREEN}==> 普通反代创建成功！访问地址: https://${DOMAIN}:${LISTEN_PORT}${RESET}"
}

# 【补全】 3. 添加配置 (自定义证书)
add_custom_cert_site() {
    echo -e "${YELLOW}=== 添加配置 (使用自备/自定义证书) ===${RESET}"
    prompt DOMAIN "请输入反代域名"
    DOMAIN="$(strip_scheme "$DOMAIN")"
    [ -n "$DOMAIN" ] || return 1

    prompt LISTEN_PORT "请输入本机监听端口" "443"
    is_port "$LISTEN_PORT" || return 1

    prompt UP_HOST "请输入反代后端 IP/主机名" "127.0.0.1"
    prompt UP_PORT "请输入反代后端端口" "80"
    is_port "$UP_PORT" || return 1

    prompt CUSTOM_CERT "请输入自备证书 (.crt/.cer/fullchain) 文件的绝对路径"
    prompt CUSTOM_KEY "请输入自备私钥 (.key/private.key) 文件的绝对路径"

    if [ ! -f "$CUSTOM_CERT" ] || [ ! -f "$CUSTOM_KEY" ]; then
        echo -e "${RED}错误: 指定的证书或私钥文件不存在，请检查路径！${RESET}"
        return 1
    fi

    # 复制自备证书到系统统一的管理目录
    local cert_dir="${CERT_HOME}/${DOMAIN}"
    mkdir -p "$cert_dir"
    cp -f "$CUSTOM_CERT" "${cert_dir}/fullchain.cer"
    cp -f "$CUSTOM_KEY" "${cert_dir}/private.key"

    local conf_path="${HTTP_D}/${CONF_PREFIX}$(sanitize_name "$DOMAIN")-${LISTEN_PORT}.conf"

    cat > "$conf_path" <<EOF
# META domain=${DOMAIN} port=${LISTEN_PORT} upstream=http://${UP_HOST}:${UP_PORT} type=custom_cert
server {
    listen ${LISTEN_PORT} ssl;
    listen [::]:${LISTEN_PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${cert_dir}/fullchain.cer;
    ssl_certificate_key ${cert_dir}/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://${UP_HOST}:${UP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    nginx -t && manage_nginx_service reload
    echo -e "${GREEN}==> 自定义证书反代配置成功！访问地址: https://${DOMAIN}:${LISTEN_PORT}${RESET}"
}

# 9. Emby 专属流媒体反代配置
add_emby_site() {
    echo -e "${YELLOW}=== Emby 专属流媒体高级反代配置 ===${RESET}"
    prompt DOMAIN "请输入 Emby 绑定的域名"
    DOMAIN="$(strip_scheme "$DOMAIN")"
    [ -n "$DOMAIN" ] || return 1

    prompt LISTEN_PORT "请输入 HTTPS 本地监听端口" "52443"
    is_port "$LISTEN_PORT" || return 1

    prompt UP_HOST "请输入 Emby 后端主机名或内网 IP (不要带 https://)"
    UP_HOST="$(strip_scheme "$UP_HOST")"
    
    prompt UP_PORT "请输入 Emby 后端端口" "443"
    is_port "$UP_PORT" || return 1

    # 【新增】证书获取类型交互
    echo -e "${YELLOW}请选择为此 Emby 站点部署的证书类型：${RESET}"
    echo "1) 自动申请证书 (通过 acme.sh 脚本自动托管机制)"
    echo "2) 使用自定义证书 (需手动提供已有的密钥对)"
    read -r -p "输入序号 [1-2]: " CERT_MODE_CHOICE </dev/tty
    
    local cert_meta_type="emby_acme"
    local cert_dir="${CERT_HOME}/${DOMAIN}"

    if [ "$CERT_MODE_CHOICE" = "2" ]; then
        prompt CUSTOM_CERT "请输入自备证书 (.crt/.cer) 文件的绝对路径"
        prompt CUSTOM_KEY "请输入自备私钥 (.key) 文件的绝对路径"
        if [ ! -f "$CUSTOM_CERT" ] || [ ! -f "$CUSTOM_KEY" ]; then
            echo -e "${RED}错误: 证书或私钥文件路径有误，配置终止！${RESET}"
            return 1
        fi
        mkdir -p "$cert_dir"
        cp -f "$CUSTOM_CERT" "${cert_dir}/fullchain.cer"
        cp -f "$CUSTOM_KEY" "${cert_dir}/private.key"
        cert_meta_type="emby_custom_cert"
    else
        choose_ca_provider || return 1
        choose_dns_provider || return 1
        setup_dns_env "$DNS_PROVIDER" || return 1
        issue_and_install_cert "$DOMAIN" "$DNS_PROVIDER"
    fi

    yesno ENABLE_AUTH "是否启用 BasicAuth 额外密码门禁" "n"
    local auth_block="" htpasswd_file="/etc/nginx/.htpasswd-${LISTEN_PORT}"
    if [ "$ENABLE_AUTH" = "y" ]; then
        prompt AUTH_USER "BasicAuth 用户名" "emby"
        prompt AUTH_PASS "BasicAuth 密码"
        htpasswd -bc "$htpasswd_file" "$AUTH_USER" "$AUTH_PASS" >/dev/null
        auth_block="auth_basic \"Restricted\"; auth_basic_user_file ${htpasswd_file};"
    fi

    yesno SKIP_VERIFY "若上游为内网自签证书，是否跳过验证" "y"
    local verify_block=""
    [ "$SKIP_VERIFY" = "y" ] && verify_block="proxy_ssl_verify off;"

    local conf_path="${HTTP_D}/${CONF_PREFIX}$(sanitize_name "$DOMAIN")-${LISTEN_PORT}.conf"

    cat > "$conf_path" <<EOF
# META domain=${DOMAIN} port=${LISTEN_PORT} upstream=https://${UP_HOST}:${UP_PORT} type=${cert_meta_type}
server {
    listen ${LISTEN_PORT} ssl;
    listen [::]:${LISTEN_PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${cert_dir}/fullchain.cer;
    ssl_certificate_key ${cert_dir}/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        ${auth_block}
        proxy_pass https://${UP_HOST}:${UP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$proxy_host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_connect_timeout 5s;
        proxy_read_timeout 3600s;
        proxy_ssl_server_name on;
        ${verify_block}
    }
}
EOF
    nginx -t && manage_nginx_service reload
    echo -e "${GREEN}==> Emby 高级反代配置成功！访问地址: https://${DOMAIN}:${LISTEN_PORT}${RESET}"
}

list_sites() {
    echo -e "${YELLOW}=== 当前已托管的反向代理站点 ===${RESET}"
    local found=0
    if [ -d "$HTTP_D" ]; then
        for f in "${HTTP_D}/${CONF_PREFIX}"*.conf; do
            [ -e "$f" ] || continue
            found=1
            local meta domain port upstream
            meta="$(grep -E '^# META ' "$f" | head -n1 || true)"
            domain="$(echo "$meta" | sed -n 's/.*domain=\([^ ]*\).*/\1/p')"
            port="$(echo "$meta" | sed -n 's/.*port=\([^ ]*\).*/\1/p')"
            upstream="$(echo "$meta" | sed -n 's/.*upstream=\([^ ]*\).*/\1/p')"
            echo -e "◈ 域名: ${GREEN}${domain}${RESET} | 监听端口: ${YELLOW}${port}${RESET} | 后端: ${upstream}"
        done
    fi
    [ "$found" -eq 1 ] || echo "（暂无任何反代站点）"
}

delete_site() {
    list_sites
    prompt DOMAIN "请输入要删除的域名"
    DOMAIN="$(strip_scheme "$DOMAIN")"
    prompt LISTEN_PORT "请输入对应的监听端口"
    
    local conf_path="${HTTP_D}/${CONF_PREFIX}$(sanitize_name "$DOMAIN")-${LISTEN_PORT}.conf"
    if [ -f "$conf_path" ]; then
        rm -f "$conf_path"
        rm -f "/etc/nginx/.htpasswd-${LISTEN_PORT}" || true
        echo -e "${GREEN}站点配置文件已移除。${RESET}"
        nginx -t && manage_nginx_service reload
    else
        echo -e "${RED}未找到对应的站点配置文件。${RESET}"
    fi
}

# 【改写升级】实时监控本地证书状态 (完美兼容多系统/Alpine)
check_domains_status() {
    clear
    echo -e "${YELLOW}========================================${RESET}"
    echo -e "${YELLOW}        ◈ 本地证书状态实时监控 ◈            ${RESET}"
    echo -e "${YELLOW}========================================${RESET}"

    # 兼容低版本 Bash 与 Alpine 替代 mapfile
    local DOMAINS=()
    if [ -x "${ACME_HOME}/acme.sh" ]; then
        while read -r line; do
            [ -n "$line" ] && DOMAINS+=("$line")
        done < <("${ACME_HOME}/acme.sh" --list | tail -n +2 | awk '{print $1}')
    fi
    
    # 补充扫描非 acme.sh 托管的自定义证书目录
    if [ -d "$CERT_HOME" ]; then
        for d in "$CERT_HOME"/*; do
            if [ -d "$d" ]; then
                local b_name=$(basename "$d")
                # 去重加入队列
                [[ " ${DOMAINS[*]} " =~ " ${b_name} " ]] || DOMAINS+=("$b_name")
            fi
        done
    fi

    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${RED} ❌ 当前系统未检测到任何已配置的本地证书。${RESET}"
        echo -e "${YELLOW}----------------------------------------${RESET}"
        pause
        return
    fi

    for DOMAIN in "${DOMAINS[@]}"; do
        [ -z "$DOMAIN" ] && continue
        local CERT_PATH="${CERT_HOME}/${DOMAIN}/fullchain.cer"
        local TYPE="ACME 自动管理 (域名/IP)"
        
        # 判断证书来源类型
        if [ -f "${HTTP_D}/${CONF_PREFIX}${DOMAIN}"*.conf ]; then
            if grep -q "type=custom_cert" "${HTTP_D}/${CONF_PREFIX}${DOMAIN}"*.conf 2>/dev/null; then
                TYPE="用户自备/自定义证书"
            fi
        fi

        echo -e "${YELLOW}◈ 域名/IP: ${RESET}${YELLOW}${DOMAIN}${RESET}"
        echo -e "  ├─ ${YELLOW}证书类型: ${RESET}${TYPE}"

        if [ -f "$CERT_PATH" ]; then
            # 跨系统兼容的到期时间抓取格式
            END_DATE=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
            
            # 使用 openssl 计算剩余天数，规避 Alpine date 命令对 -d 参数不支持的硬伤
            local now_epoch=$(date +%s)
            # 提取证书过期时间戳
            if command -v perl >/dev/null 2>&1; then
                # 若系统有 perl 辅助计算
                local end_epoch=$(perl -MHTTP::Date -e "print str2time('$END_DATE')")
                DAYS_LEFT=$(( (end_epoch - now_epoch) / 86400 ))
            else
                # 纯 openssl 静态检查天数方案
                DAYS_LEFT=0
                while openssl x509 -checkend $((DAYS_LEFT * 86400)) -in "$CERT_PATH" >/dev/null 2>&1; do
                    DAYS_LEFT=$((DAYS_LEFT + 1))
                    [ $DAYS_LEFT -gt 365 ] && break
                done
                # 如果一开始就过期
                if [ $DAYS_LEFT -eq 0 ]; then DAYS_LEFT=-1; fi
            fi

            if [ $DAYS_LEFT -ge 30 ]; then
                STATUS_COLOR="${GREEN}"
                STATUS_TEXT="正常有效"
            elif [ $DAYS_LEFT -ge 0 ]; then
                STATUS_COLOR="${YELLOW}"
                STATUS_TEXT="即将过期 (请注意)"
            else
                STATUS_COLOR="${RED}"
                STATUS_TEXT="已过期 (请立即更新)"
            fi
            
            echo -e "  ├─ ${YELLOW}到期时间: ${RESET}${END_DATE}"
            echo -e "  ├─ ${YELLOW}剩余天数: ${RESET}${STATUS_COLOR}${DAYS_LEFT} 天${RESET}"
            echo -e "  └─ ${YELLOW}运行状态: ${RESET}${STATUS_COLOR}${STATUS_TEXT}${RESET}"
        else
            echo -e "  └─ ${YELLOW}运行状态: ${RESET}${RED}未在 $CERT_HOME 中找到导出的证书文件${RESET}"
        fi
        echo -e "${YELLOW}----------------------------------------${RESET}"
    done
    pause
}

test_cert_renew() {
    clear
    echo -e "${YELLOW}=========================================${RESET}"
    echo -e "${YELLOW}       ◈    ACME 证书手动强制续期    ◈    ${RESET}"
    echo -e "${YELLOW}=========================================${RESET}"
    
    if [ ! -x "${ACME_HOME}/acme.sh" ]; then
        echo -e "${RED}错误: 系统未检测到 acme.sh，无法执行自动续期操作。${RESET}"
        return 0
    fi

    local domains=()
    local count=0
    while read -r line; do
        if [ -n "$line" ]; then
            count=$((count + 1))
            domains+=("$line")
            echo -e "  ${YELLOW}${count})${RESET} 域名/IP: ${GREEN}${line}${RESET}"
        fi
    done < <("${ACME_HOME}/acme.sh" --list | tail -n +2 | awk '{print $1}')

    if [ "$count" -eq 0 ]; then
        echo -e "${RED}当前 acme.sh 列表中无任何可供续期的域名。${RESET}"
        return 0
    fi

    echo -e "  ${YELLOW}0)${RESET} 返回主菜单"
    echo -e "${YELLOW}=========================================${RESET}"
    echo -ne "${GREEN}请选择想要强制续期的证书序号 [0-${count}]: ${RESET}"
    read -r idx </dev/tty

    if [ "$idx" = "0" ] || [ -z "$idx" ]; then
        return 0
    fi

    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$count" ]; then
        echo -e "${RED}输入序号非法！${RESET}"
        sleep 1
        return 0
    fi

    local target_domain="${domains[$((idx - 1))]}"
    echo -e "${YELLOW}==> 正在向证书颁发机构申请强制更新域名: ${target_domain} ...${RESET}"
    
    if "${ACME_HOME}/acme.sh" --renew -d "$target_domain" --ecc --force; then
        echo -e "${GREEN}✔ 证书续期成功！正在尝试复制和重载 Nginx 服务...${RESET}"
        local cert_dir="${CERT_HOME}/${target_domain}"
        if [ -d "$cert_dir" ]; then
            "${ACME_HOME}/acme.sh" --install-cert -d "$target_domain" --ecc \
                --fullchain-file "${cert_dir}/fullchain.cer" \
                --key-file "${cert_dir}/private.key"
        fi
        nginx -t && manage_nginx_service reload
        echo -e "${GREEN}✔ 证书文件部署与 Nginx 服务重载全部完成！${RESET}"
    else
        echo -e "${RED}❌ 证书续期失败！具体错误原因请参考上方 acme.sh 官方日志。${RESET}"
    fi
}

uninstall_nginx() {
    yesno CONFIRM "确定要完全卸载反代系统和 Nginx 吗？" "n"
    if [ "$CONFIRM" = "y" ]; then
        manage_nginx_service stop || true
        manage_nginx_service disable || true
        rm -f "${HTTP_D}/${CONF_PREFIX}"*.conf 2>/dev/null || true
        rm -rf "$CERT_HOME"
        
        local tmp_cron="/tmp/cron_backup"
        if crontab -l > "$tmp_cron" 2>/dev/null; then
            sed -i '/acme.sh/d' "$tmp_cron" && crontab "$tmp_cron"
        fi
        rm -f "$tmp_cron"

        case "$OS" in
            alpine) apk del nginx >/dev/null 2>&1 || true ;;
            debian) apt-get purge -y nginx >/dev/null 2>&1 || true ;;
            rhel) dnf remove -y nginx >/dev/null 2>&1 || true ;;
        esac
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

# 终极主菜单面板
main_panel() {
    need_root
    detect_os
    
    while true; do
        get_panel_status
        clear
        echo -e "${GREEN}===============================${RESET}"
        echo -e "${GREEN} ◈  Nginx 反向代理管理面板  ◈  ${RESET}"
        echo -e "${GREEN}===============================${RESET}"
        echo -e "${GREEN} 状态     : ${STATUS}"
        echo -e "${GREEN} 版本     : ${YELLOW}${VERSION_SHOW}${RESET}"
        echo -e "${GREEN} 数量     : ${YELLOW}${SITE_COUNT} 个${RESET}"
        echo -e "${GREEN}===============================${RESET}"
        echo -e "${GREEN}  1. 安装 Nginx${RESET}"
        echo -e "${GREEN}  2. 添加配置(自动申请证书)${RESET}"
        echo -e "${GREEN}  3. 添加配置(使用自定义证书)${RESET}"
        echo -e "${GREEN}  4. 删除配置${RESET}"
        echo -e "${GREEN}  5. 证书续期${RESET}"
        echo -e "${GREEN}  6. 查看证书状态${RESET}"
        echo -e "${GREEN}  7. 查看当前站点${RESET}"
        echo -e "${GREEN}  8. Emby反代配置${RESET}"
        echo -e "${GREEN}  9. 重载Nginx服务${RESET}"
        echo -e "${GREEN} 10. 卸载Nginx${RESET}"
        echo -e "${GREEN}  0. 退出${RESET}"
        echo -e "${GREEN}===============================${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        read -r choice </dev/tty

        case "$choice" in
            1)  ensure_deps && ensure_dirs && install_or_init_acme_sh && write_main_nginx_conf && manage_nginx_service enable && manage_nginx_service start ; pause ;;
            2)  add_common_site ; pause ;;
            3)  add_custom_cert_site ; pause ;;
            4)  delete_site ; pause ;;
            5)  test_cert_renew ; pause ;;
            6)  check_domains_status ;;
            7)  list_sites ; pause ;;
            8)  add_emby_site ; pause ;;
            9)  manage_nginx_service reload && echo -e "${GREEN}重载成功！${RESET}" ; pause ;;
            10) uninstall_nginx ; pause ;;
            0)  clear && exit 0 ;;
            *)  echo -e "${RED}输入错误，请重新选择！${RESET}" ; pause ;;
        esac
    done
}

main_panel "$@"
