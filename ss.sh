#!/bin/bash
set -e

CADDYFILE="/etc/caddy/Caddyfile"
CADDY_DATA="/var/lib/caddy/.local/share/caddy"
CADDY_CERTS_DIR="/etc/caddy/certs"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# ==================== 自动化环境检查与修复 ====================
if ! command -v sudo >/dev/null 2>&1; then
    echo -e "${YELLOW}检测到系统未安装 sudo，正在尝试自动安装...${RESET}"
    if command -v apt >/dev/null 2>&1; then
        apt update -q && apt install -yq sudo
    elif command -v yum >/dev/null 2>&1; then
        yum install -y sudo
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y sudo
    else
        echo -e "${RED}错误: 无法确定包管理器，请手动安装 sudo 后再试。${RESET}"
        exit 1
    fi
    echo -e "${GREEN}sudo 安装成功！${RESET}"
fi

[ ! -d "/etc/caddy" ] && sudo mkdir -p /etc/caddy
[ ! -d "$CADDY_CERTS_DIR" ] && sudo mkdir -p $CADDY_CERTS_DIR && sudo chown -R caddy:caddy $CADDY_CERTS_DIR 2>/dev/null || true
[ ! -f "$CADDYFILE" ] && sudo touch $CADDYFILE

pause() {
    echo -ne "${YELLOW}按回车返回菜单...${RESET}"
    read -r
}

# 终极精准版域名提取函数（过滤保留字，必须包含点，防止误伤）
get_all_domains() {
    [ ! -f "$CADDYFILE" ] && return
    grep -E '^[[:space:]]*([a-zA-Z0-9.-]+|:[0-9]+|http[s]?://[a-zA-Z0-9.-]+)' "$CADDYFILE" | \
    sed -E 's/https?:\/\///g' | \
    awk '{print $1}' | \
    awk -F: '{print $1}' | \
    grep -Ev '^(file_server|reverse_proxy|root|import|tls|header|encode|route|handle|handle_path|log|respond|rewrite|redir|try_files|{|}|\*)$' | \
    grep '\.' | sort -u
}

get_system_status() {
    if ! command -v caddy >/dev/null 2>&1; then
        STATUS="${RED}未安装${RESET}"
        VERSION_SHOW="-"
        SITE_COUNT="0"
        return
    fi

    if systemctl is-active --quiet caddy; then
        STATUS="${GREEN}运行中${RESET}"
    else
        STATUS="${RED}已停止${RESET}"
    fi

    VERSION_SHOW=$(caddy version | awk '{print $1}')
    SITE_COUNT=$(get_all_domains | wc -l)
}

install_caddy() {
    if command -v caddy >/dev/null 2>&1; then
        echo -e "${GREEN}Caddy 已安装${RESET}"
        pause
        return
    fi

    if ! command -v apt >/dev/null 2>&1; then
        echo -e "${RED}仅支持 Debian/Ubuntu 系统${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}正在安装 Caddy...${RESET}"
    sudo apt update -q
    sudo apt install -yq debian-keyring debian-archive-keyring apt-transport-https curl

    if [ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]; then
        curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | \
        sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    fi

    if [ ! -f /etc/apt/sources.list.d/caddy-stable.list ]; then
        curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | \
        sudo tee /etc/apt/sources.list.d/caddy-stable.list
    fi

    sudo apt update -q
    sudo apt install -yq caddy
    sudo systemctl enable caddy
    sudo systemctl start caddy

    sudo mkdir -p $CADDY_CERTS_DIR && sudo chown -R caddy:caddy $CADDY_CERTS_DIR 2>/dev/null || true

    echo -e "${GREEN}Caddy 安装完成并已启动${RESET}"
    pause
}

update_caddy() {
    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${RED}Caddy 未安装，无法更新${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}正在检查并更新 Caddy...${RESET}"
    sudo apt update -q
    sudo apt install --only-upgrade -y caddy
    echo -e "${GREEN}Caddy 更新程序执行完毕${RESET}"
    pause
}

uninstall_caddy() {
    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${YELLOW}Caddy 未安装${RESET}"
        pause
        return
    fi

    echo -ne "${YELLOW}确定要彻底卸载 Caddy 吗？此操作不可逆！(y/n): ${RESET}"; read -r CONFIRM
    if [[ "$CONFIRM" != "y" ]]; then
        echo -e "${YELLOW}已取消卸载${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}正在卸载 Caddy...${RESET}"
    sudo systemctl stop caddy 2>/dev/null || true
    sudo systemctl disable caddy 2>/dev/null || true

    sudo apt purge -y caddy
    sudo apt autoremove -y

    sudo rm -rf /etc/caddy /var/lib/caddy /var/log/caddy
    sudo rm -f /etc/apt/sources.list.d/caddy-stable.list /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    sudo systemctl daemon-reload
    sudo systemctl reset-failed

    echo -e "${GREEN}Caddy 已干净卸载${RESET}"
    pause
}

reload_caddy() {
    if systemctl is-active --quiet caddy; then
        if sudo caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
            sudo systemctl reload caddy
            echo -e "${GREEN}Caddy 配置验证通过，已成功重载！${RESET}"
        else
            echo -e "${RED}错误: Caddyfile 语法检查未通过，拒绝重载！${RESET}"
            echo -e "${YELLOW}请执行命令手动排查原因: sudo caddy validate --config $CADDYFILE${RESET}"
        fi
    else
        echo -e "${YELLOW}Caddy 未运行，正在尝试启动...${RESET}"
        sudo systemctl start caddy
    fi
    pause
}

add_site() {
    read -p "请输入域名 (example.com)： " DOMAIN
    [ -z "$DOMAIN" ] && return
    read -p "是否需要 h2c/gRPC 代理？(y/n，回车默认 n)： " H2C
    H2C=${H2C:-n}
    
    SITE_CONFIG="\n${DOMAIN} {\n"
    if [[ "$H2C" == "y" ]]; then
        read -p "请输入 h2c 代理路径 (例如 /proto.NezhaService/*)： " H2C_PATH
        read -p "请输入内网目标地址 (例如 127.0.0.1:8008)： " H2C_TARGET
        SITE_CONFIG+="    reverse_proxy ${H2C_PATH} h2c://${H2C_TARGET}\n"
    fi

    read -p "请输入普通 HTTP 代理目标 (默认 127.0.0.1:8008)： " HTTP_TARGET
    HTTP_TARGET=${HTTP_TARGET:-127.0.0.1:8008}
    SITE_CONFIG+="    reverse_proxy ${HTTP_TARGET}\n}\n"

    echo -e "$SITE_CONFIG" | sudo tee -a $CADDYFILE >/dev/null
    echo -e "${GREEN}站点 ${DOMAIN} 添加成功${RESET}"
    reload_caddy
}

check_domains_status() {
    clear
    echo -e "${YELLOW}========================================${RESET}"
    echo -e "${YELLOW}        ◈ 域名证书状态实时监控 ◈            ${RESET}"
    echo -e "${YELLOW}========================================${RESET}"

    mapfile -t DOMAINS < <(get_all_domains)
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${RED} ❌ 当前系统未检测到任何反代站点配置或未找到 Caddyfile。${RESET}"
        echo -e "${YELLOW}----------------------------------------${RESET}"
        pause
        return
    fi

    for DOMAIN in "${DOMAINS[@]}"; do
        local CERT_PATH=""
        local TYPE="自动申请 (Let's Encrypt / ZeroSSL)"

        if [ -d "$CADDY_DATA" ]; then
            CERT_PATH=$(sudo find "$CADDY_DATA" -type f -name "$DOMAIN.crt" 2>/dev/null | head -n 1)
        fi

        if [ -z "$CERT_PATH" ] && grep -A 5 "${DOMAIN}" "$CADDYFILE" | grep -q "tls "; then
            local CUSTOM_PATH=$(grep -A 5 "${DOMAIN}" "$CADDYFILE" | grep "tls " | awk '{print $2}' | tr -d '\r\n')
            if [ -f "$CUSTOM_PATH" ]; then
                CERT_PATH="$CUSTOM_PATH"
                TYPE="自定义证书 (.pem/.crt)"
            fi
        fi

        echo -e "${YELLOW}◈ 域名: ${RESET}${YELLOW}${DOMAIN}${RESET}"
        echo -e "  ├─ ${YELLOW}证书类型: ${RESET}${TYPE}"

        if [ -n "$CERT_PATH" ] && [ -f "$CERT_PATH" ]; then
            END_DATE=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
            if END_TS=$(date -d "$END_DATE" +%s 2>/dev/null); then
                NOW_TS=$(date +%s)
                DAYS_LEFT=$(( (END_TS - NOW_TS) / 86400 ))
                
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
                echo -e "  ├─ ${YELLOW}到期时间: ${RESET}$(date -d "$END_DATE" +"%Y-%m-%d" 2>/dev/null || echo "$END_DATE")"
                echo -e "  ├─ ${YELLOW}剩余天数: ${RESET}${STATUS_COLOR}${DAYS_LEFT} 天${RESET}"
                echo -e "  └─ ${YELLOW}运行状态: ${RESET}${STATUS_COLOR}${STATUS_TEXT}${RESET}"
            else
                if openssl x509 -checkend 2592000 -in "$CERT_PATH" >/dev/null; then
                    echo -e "  └─ ${YELLOW}运行状态: ${RESET}${GREEN}正常有效 (剩余 > 30天)${RESET}"
                else
                    echo -e "  └─ ${YELLOW}运行状态: ${RESET}${YELLOW}即将过期或已过期${RESET}"
                fi
            fi
        else
            echo -e "  └─ ${YELLOW}运行状态: ${RESET}${RED}未找到证书或尚未签发成功${RESET}"
        fi
        echo -e "${YELLOW}----------------------------------------${RESET}"
    done
    pause
}

delete_site() {
    mapfile -t DOMAINS < <(get_all_domains)
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有可删除的域名${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}请选择要删除的域名编号（输入0返回菜单）:${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo "$((i+1))) ${DOMAINS[$i]}"
    done
    read -p "输入编号： " NUM

    if [[ "$NUM" == "0" || -z "$NUM" ]]; then return; fi

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效编号${RESET}"
        pause
        return
    fi

    DOMAIN="${DOMAINS[$((NUM-1))]}"
    local ESCAPED_DOMAIN=$(echo "$DOMAIN" | sed 's/\./\\./g')
    
    sudo sed -i "/^[[:space:]]*${ESCAPED_DOMAIN}\(:[0-9]+\)\?[[:space:]]*,[^{]*{/,/^[[:space:]]*}/d" $CADDYFILE 2>/dev/null || \
    sudo sed -i "/^[[:space:]]*${ESCAPED_DOMAIN}[[:space:]]*{/,/^[[:space:]]*}/d" $CADDYFILE

    echo -e "${GREEN}域名 ${DOMAIN} 已从 Caddyfile 删除${RESET}"

    local CERT_DIR=$(sudo find "$CADDY_DATA" -type d -name "$DOMAIN" 2>/dev/null | head -n 1)
    if [ -n "$CERT_DIR" ] && [ -d "$CERT_DIR" ]; then
        read -p "是否一并删除该域名证书？(y/n): " DEL_CERT
        if [[ "$DEL_CERT" == "y" ]]; then
            sudo rm -rf "$CERT_DIR"
            echo -e "${GREEN}已删除证书目录：${RESET}${CERT_DIR}"
        fi
    fi

    reload_caddy
}

modify_site() {
    mapfile -t DOMAINS < <(get_all_domains)
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有可修改的域名${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}请选择要修改的域名编号（输入0返回菜单）:${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo "$((i+1))) ${DOMAINS[$i]}"
    done
    read -p "输入编号： " NUM

    if [[ "$NUM" == "0" || -z "$NUM" ]]; then return; fi

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效编号${RESET}"
        pause
        return
    fi

    DOMAIN="${DOMAINS[$((NUM-1))]}"

    local OLD_TLS_LINE=$(grep -A 5 "${DOMAIN}" "$CADDYFILE" | grep "tls " | head -n 1 | tr -d '\r')

    read -p "请输入普通 HTTP 代理目标 (默认 127.0.0.1:8008)： " HTTP_TARGET
    HTTP_TARGET=${HTTP_TARGET:-127.0.0.1:8008}

    read -p "是否需要 h2c/gRPC 代理？(y/n，回车默认 n)： " H2C
    H2C=${H2C:-n}
    H2C_CONFIG=""
    if [[ "$H2C" == "y" ]]; then
        read -p "请输入 h2c 代理路径 (例如 /proto.NezhaService/*)： " H2C_PATH
        read -p "请输入内网目标地址 (例如 127.0.0.1:8008)： " H2C_TARGET
        H2C_CONFIG="    reverse_proxy ${H2C_PATH} h2c://${H2C_TARGET}\n"
    fi

    local ESCAPED_DOMAIN=$(echo "$DOMAIN" | sed 's/\./\\./g')
    sudo sed -i "/^[[:space:]]*${ESCAPED_DOMAIN}\(:[0-9]+\)\?[[:space:]]*,[^{]*{/,/^[[:space:]]*}/d" $CADDYFILE 2>/dev/null || \
    sudo sed -i "/^[[:space:]]*${ESCAPED_DOMAIN}[[:space:]]*{/,/^[[:space:]]*}/d" $CADDYFILE
    
    NEW_CONFIG="\n${DOMAIN} {\n"
    if [ -n "$OLD_TLS_LINE" ]; then
        NEW_CONFIG+="${OLD_TLS_LINE}\n"
    fi
    NEW_CONFIG+="${H2C_CONFIG}    reverse_proxy ${HTTP_TARGET}\n}\n"
    
    echo -e "$NEW_CONFIG" | sudo tee -a $CADDYFILE >/dev/null
    
    echo -e "${GREEN}域名 ${DOMAIN} 配置已成功修改并自动维系证书凭证！${RESET}"
    reload_caddy
}

add_site_with_cert() {
    read -p "请输入域名 (example.com)： " DOMAIN
    [ -z "$DOMAIN" ] && return
    read -p "是否需要 h2c/gRPC 代理？(y/n，回车默认 n)： " H2C
    H2C=${H2C:-n}

    read -p "请输入证书文件路径 (.pem/.crt)： " RAW_CERT_PATH
    read -p "请输入私钥文件路径 (.key)： " RAW_KEY_PATH

    if [ ! -f "$RAW_CERT_PATH" ] || [ ! -f "$RAW_KEY_PATH" ]; then
        echo -e "${RED}错误: 输入的证书或私钥文件路径不存在！请重新确认。${RESET}"
        pause
        return
    fi

    sudo mkdir -p $CADDY_CERTS_DIR
    local SAFE_CERT="$CADDY_CERTS_DIR/${DOMAIN}.fullchain.pem"
    local SAFE_KEY="$CADDY_CERTS_DIR/${DOMAIN}.privkey.key"

    echo -e "${YELLOW}正在安全同步证书文件，并为您自动处理 Caddy 读取权限...${RESET}"
    sudo cp -f "$RAW_CERT_PATH" "$SAFE_CERT"
    sudo cp -f "$RAW_KEY_PATH" "$SAFE_KEY"
    sudo chown -R caddy:caddy $CADDY_CERTS_DIR
    sudo chmod 644 "$SAFE_CERT" "$SAFE_KEY"

    SITE_CONFIG="\n${DOMAIN} {\n"
    SITE_CONFIG+="    tls ${SAFE_CERT} ${SAFE_KEY}\n"

    if [[ "$H2C" == "y" ]]; then
        read -p "请输入 h2c 代理路径 (例如 /proto.NezhaService/*)： " H2C_PATH
        read -p "请输入内网目标地址 (例如 127.0.0.1:8008)： " H2C_TARGET
        SITE_CONFIG+="    reverse_proxy ${H2C_PATH} h2c://${H2C_TARGET}\n"
    fi

    read -p "请输入普通 HTTP 代理目标 (默认 127.0.0.1:8008)： " HTTP_TARGET
    HTTP_TARGET=${HTTP_TARGET:-127.0.0.1:8008}
    SITE_CONFIG+="    reverse_proxy ${HTTP_TARGET}\n}\n"

    echo -e "$SITE_CONFIG" | sudo tee -a $CADDYFILE >/dev/null
    echo -e "${GREEN}站点 ${DOMAIN} (自定义证书已自动授权放行) 添加成功${RESET}"

    reload_caddy
}

# 1. Emby 普通反代 (自动申请证书)
add_emby_site_caddy() {
    echo -ne "${GREEN}请输入您的域名 (例: emby.example.com): ${RESET}"; read -r DOMAIN
    [ -z "$DOMAIN" ] && return
    echo -ne "${GREEN}请输入 Emby 目标地址 (例: http://127.0.0.1:8096): ${RESET}"; read -r TARGET
    
    local TARGET_HOST=$(echo "$TARGET" | awk -F[/:] '{print $4}')
    
    sudo tee -a $CADDYFILE >/dev/null <<EOF

$DOMAIN {
    encode gzip

    reverse_proxy $TARGET {
        flush_interval -1
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
EOF

    if [[ "$TARGET" == https* ]]; then
        sudo tee -a $CADDYFILE >/dev/null <<EOF
        header_up Host $TARGET_HOST
        transport http {
            tls_server_name $TARGET_HOST
        }
EOF
    fi

    sudo tee -a $CADDYFILE >/dev/null <<EOF
    }

    header {
        Access-Control-Allow-Origin *
        Access-Control-Allow-Methods "GET, POST, OPTIONS, DELETE, PUT"
        Access-Control-Allow-Headers "X-Emby-Authorization, Content-Type, Authorization, X-Requested-With"
    }
}
EOF

    echo -e "${GREEN}配置已生成！访问地址: https://${DOMAIN}${RESET}"
    reload_caddy
}

# 2. Emby 主站 + 推流重定向 (自动申请证书)
add_emby_split_site_caddy() {
    echo -ne "${GREEN}请输入您的域名(例: emby.example.com): ${RESET}"; read -r DOMAIN
    [ -z "$DOMAIN" ] && return
    echo -ne "${GREEN}请输入 Emby 主站地址(例: https://emby.example.com): ${RESET}"; read -r T_MAIN
    echo -ne "${GREEN}请输入推流后端地址(例: https://emby.xx.com): ${RESET}"; read -r T_STREAM

    local STREAM_HOST=$(echo "$T_STREAM" | awk -F[/:] '{print $4}')

    sudo tee -a $CADDYFILE >/dev/null <<EOF

$DOMAIN {
    handle_path /s1/* {
        reverse_proxy $T_STREAM {
            flush_interval -1
            header_up Host $STREAM_HOST
            header_up X-Real-IP ""
            header_up X-Forwarded-For ""
        }
    }

    handle {
        reverse_proxy $T_MAIN {
            flush_interval -1
            header_up Host {upstream_hostport}
            header_up X-Real-IP ""
            header_up X-Forwarded-For ""
        }
    }
}
EOF
    echo -e "${GREEN}访问地址: https://${DOMAIN}${RESET}"
    reload_caddy
}

# 【新增功能】3. Emby 普通反代 (带有权限纠错能力的自定义证书版本)
add_emby_custom_cert_caddy() {
    echo -ne "${GREEN}请输入您的域名 (例: emby.example.com): ${RESET}"; read -r DOMAIN
    [ -z "$DOMAIN" ] && return
    
    echo -ne "${GREEN}请输入证书文件路径 (.pem/.crt): ${RESET}"; read -r RAW_CERT_PATH
    echo -ne "${GREEN}请输入私钥文件路径 (.key): ${RESET}"; read -r RAW_KEY_PATH

    if [ ! -f "$RAW_CERT_PATH" ] || [ ! -f "$RAW_KEY_PATH" ]; then
        echo -e "${RED}错误: 输入的证书或私钥文件路径不存在！${RESET}"
        pause
        return
    fi

    # 自动安全转移证书到拥有 caddy 权限的目录
    sudo mkdir -p $CADDY_CERTS_DIR
    local SAFE_CERT="$CADDY_CERTS_DIR/emby_${DOMAIN}.fullchain.pem"
    local SAFE_KEY="$CADDY_CERTS_DIR/emby_${DOMAIN}.privkey.key"

    echo -e "${YELLOW}正在同步证书文件并下发 Caddy 专属访问权限...${RESET}"
    sudo cp -f "$RAW_CERT_PATH" "$SAFE_CERT"
    sudo cp -f "$RAW_KEY_PATH" "$SAFE_KEY"
    sudo chown -R caddy:caddy $CADDY_CERTS_DIR
    sudo chmod 644 "$SAFE_CERT" "$SAFE_KEY"

    echo -ne "${GREEN}请输入 Emby 目标地址 (例: http://127.0.0.1:8096): ${RESET}"; read -r TARGET
    local TARGET_HOST=$(echo "$TARGET" | awk -F[/:] '{print $4}')
    
    sudo tee -a $CADDYFILE >/dev/null <<EOF

$DOMAIN {
    tls $SAFE_CERT $SAFE_KEY
    encode gzip

    reverse_proxy $TARGET {
        flush_interval -1
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
EOF

    if [[ "$TARGET" == https* ]]; then
        sudo tee -a $CADDYFILE >/dev/null <<EOF
        header_up Host $TARGET_HOST
        transport http {
            tls_server_name $TARGET_HOST
        }
EOF
    fi

    sudo tee -a $CADDYFILE >/dev/null <<EOF
    }

    header {
        Access-Control-Allow-Origin *
        Access-Control-Allow-Methods "GET, POST, OPTIONS, DELETE, PUT"
        Access-Control-Allow-Headers "X-Emby-Authorization, Content-Type, Authorization, X-Requested-With"
    }
}
EOF

    echo -e "${GREEN}自定义证书 Emby 配置已生成！访问地址: https://${DOMAIN}${RESET}"
    reload_caddy
}

emby_proxy_menu() {
    while true; do
        clear
        echo -e "${GREEN}==== Emby 反代管理 ====${RESET}"
        echo -e "${GREEN}1) 普通反代 (自动申请证书)${RESET}"
        echo -e "${GREEN}2) 主站 + 推流重定向 (自动申请证书)${RESET}"
        echo -e "${GREEN}3) 普通反代 (使用自定义证书)${RESET}"
        echo -e "${GREEN}0) 返回主菜单${RESET}"
        echo -ne "${GREEN}请选择 [0-3]: ${RESET}" 
        read -r emby_choice

        case $emby_choice in
            1) add_emby_site_caddy; break ;;
            2) add_emby_split_site_caddy; break ;;
            3) add_emby_custom_cert_caddy; break ;;
            0) return ;;
            *) echo -e "${RED}无效选项${RESET}"; pause ;;
        esac
    done
}

view_sites() {
    mapfile -t DOMAINS < <(get_all_domains)
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有已配置的域名${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}请选择要查看证书信息的域名编号（输入0返回菜单）:${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo "$((i+1))) ${DOMAINS[$i]}"
    done

    read -p "输入编号： " NUM
    if [[ "$NUM" == "0" || -z "$NUM" ]]; then return; fi

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效编号${RESET}"
        pause
        return
    fi

    DOMAIN="${DOMAINS[$((NUM-1))]}"
    
    local CERT_FILE=""
    if [ -d "$CADDY_DATA" ]; then
        CERT_FILE=$(sudo find "$CADDY_DATA" -type f -name "$DOMAIN.crt" 2>/dev/null | head -n 1)
    fi

    if [ -z "$CERT_FILE" ] && [ -f "$CADDY_CERTS_DIR/${DOMAIN}.fullchain.pem" ]; then
        CERT_FILE="$CADDY_CERTS_DIR/${DOMAIN}.fullchain.pem"
    fi
    if [ -z "$CERT_FILE" ] && [ -f "$CADDY_CERTS_DIR/emby_${DOMAIN}.fullchain.pem" ]; then
        CERT_FILE="$CADDY_CERTS_DIR/emby_${DOMAIN}.fullchain.pem"
    fi

    if [ -n "$CERT_FILE" ] && [ -f "$CERT_FILE" ]; then
        echo -e "${GREEN}证书路径：${RESET}${CERT_FILE}"
        echo -e "${GREEN}证书信息：${RESET}"
        openssl x509 -in "$CERT_FILE" -noout -text | awk '
            /Subject:/ || /Issuer:/ || /Not Before:/ || /Not After :/ {print}'
    else
        echo -e "${YELLOW}${DOMAIN} - 未在系统默认路径找到证书${RESET}"
    fi
    pause
}

menu() {
    while true; do
        clear
        get_system_status
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}         Caddy  管理面板        ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}状态   :${RESET} $STATUS"
        echo -e "${GREEN}版本   :${RESET} ${YELLOW}$VERSION_SHOW${RESET}"
        echo -e "${GREEN}站点   :${RESET} ${YELLOW}$SITE_COUNT 个${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1. 安装Caddy${RESET}"
        echo -e "${GREEN} 2. 添加站点${RESET}"
        echo -e "${GREEN} 3. 修改站点配置${RESET}"
        echo -e "${GREEN} 4. 添加站点(自定义证书)${RESET}"
        echo -e "${GREEN} 5. 删除站点${RESET}"
        echo -e "${GREEN} 6. 查看站点证书信息${RESET}"
        echo -e "${GREEN} 7. Emby反代管理${RESET}"
        echo -e "${GREEN} 8. 查看所有域名证书状态${RESET}"
        echo -e "${GREEN} 9. 重载Caddy配置${RESET}"
        echo -e "${GREEN}10. 更新Caddy${RESET}"
        echo -e "${GREEN}11. 卸载Caddy${RESET}"
        echo -e "${GREEN} 0. 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        read choice

        case $choice in
            1) install_caddy ;;
            2) add_site ;;
            3) modify_site ;;
            4) add_site_with_cert ;;
            5) delete_site ;;
            6) view_sites ;;
            7) emby_proxy_menu ;;
            8) check_domains_status ;;
            9) reload_caddy ;;
            10) update_caddy ;;
            11) uninstall_caddy ;;
            0) echo "退出面板。"; exit 0 ;;
            *) echo -e "${RED}无效选项${RESET}"; pause ;;
        esac
    done
}

menu
