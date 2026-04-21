#!/bin/bash
set -e

CADDYFILE="/etc/caddy/Caddyfile"
CADDY_DATA="/var/lib/caddy/.local/share/caddy"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

pause() {
    echo -ne "${YELLOW}按回车返回菜单...${RESET}"
    read
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

    echo -e "${GREEN}Caddy 安装完成并已启动${RESET}"
    pause
}


uninstall_caddy() {
    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${YELLOW}Caddy 未安装${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}正在卸载 Caddy...${RESET}"

    # 停止并禁用服务（存在就处理，不存在不报错）
    sudo systemctl stop caddy 2>/dev/null || true
    sudo systemctl disable caddy 2>/dev/null || true

    # 使用 apt 正确卸载（包含 service / 二进制）
    sudo apt purge -y caddy
    sudo apt autoremove -y

    # 删除 Caddy 数据和配置（这些 apt 不会删）
    sudo rm -rf /etc/caddy
    sudo rm -rf /var/lib/caddy
    sudo rm -rf /var/log/caddy

    # 删除 Caddy 源和 keyring（可选但推荐）
    sudo rm -f /etc/apt/sources.list.d/caddy-stable.list
    sudo rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    # 刷新 systemd
    sudo systemctl daemon-reload
    sudo systemctl reset-failed

    echo -e "${GREEN}Caddy 已干净卸载（可安全重新安装）${RESET}"
    pause
}



reload_caddy() {
    sudo systemctl reload caddy
    echo -e "${GREEN}Caddy 配置已重载${RESET}"
    pause
}

add_site() {
    read -p "请输入域名 (example.com)： " DOMAIN
    read -p "是否需要 h2c/gRPC 代理？(y/n，回车默认 n)： " H2C
    H2C=${H2C:-n}
    
    SITE_CONFIG="${DOMAIN} {\n"

    if [[ "$H2C" == "y" ]]; then
        read -p "请输入 h2c 代理路径 (例如 /proto.NezhaService/*)： " H2C_PATH
        read -p "请输入内网目标地址 (例如 127.0.0.1:8008)： " H2C_TARGET
        SITE_CONFIG+="    reverse_proxy ${H2C_PATH} h2c://${H2C_TARGET}\n"
    fi

    read -p "请输入普通 HTTP 代理目标 (默认 127.0.0.1:8008)： " HTTP_TARGET
    HTTP_TARGET=${HTTP_TARGET:-127.0.0.1:8008}
    SITE_CONFIG+="    reverse_proxy ${HTTP_TARGET}\n"
    SITE_CONFIG+="}\n\n"

    echo -e "$SITE_CONFIG" | sudo tee -a $CADDYFILE >/dev/null
    echo -e "${GREEN}站点 ${DOMAIN} 添加成功${RESET}"

    reload_caddy
}

view_sites() {
    mapfile -t DOMAINS < <(grep -E '^[a-zA-Z0-9.-]+ *{' $CADDYFILE | sed 's/ {//')
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

    if [[ "$NUM" == "0" ]]; then
        return
    fi

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效编号${RESET}"
        pause
        return
    fi

    DOMAIN="${DOMAINS[$((NUM-1))]}"
    CERT_FILE="$CADDY_DATA/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN/$DOMAIN.crt"

    if [ -f "$CERT_FILE" ]; then
        echo -e "${GREEN}证书路径：${RESET}${CERT_FILE}"
        echo -e "${GREEN}证书信息：${RESET}"
        openssl x509 -in "$CERT_FILE" -noout -text | awk '
            /Subject:/ || /Issuer:/ || /Not Before:/ || /Not After :/ {print}'
    else
        echo -e "${YELLOW}${DOMAIN} - 未找到证书${RESET}"
    fi
    pause
}

delete_site() {
    mapfile -t DOMAINS < <(grep -E '^[a-zA-Z0-9.-]+ *{' $CADDYFILE | sed 's/ {//')
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

    if [[ "$NUM" == "0" ]]; then
        return
    fi

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效编号${RESET}"
        pause
        return
    fi

    DOMAIN="${DOMAINS[$((NUM-1))]}"
    # 删除 Caddyfile 中的配置
    sudo sed -i "/$DOMAIN {/,/}/d" $CADDYFILE
    echo -e "${GREEN}域名 ${DOMAIN} 已从 Caddyfile 删除${RESET}"

    # 检查是否有对应的证书目录
    CERT_DIR="$CADDY_DATA/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN"
    if [ -d "$CERT_DIR" ]; then
        read -p "是否一并删除该域名证书？(y/n): " DEL_CERT
        if [[ "$DEL_CERT" == "y" ]]; then
            sudo rm -rf "$CERT_DIR"
            echo -e "${GREEN}已删除证书目录：${RESET}${CERT_DIR}"
        else
            echo -e "${YELLOW}保留证书：${RESET}${CERT_DIR}"
        fi
    else
        echo -e "${YELLOW}未找到 ${DOMAIN} 的证书目录${RESET}"
    fi

    reload_caddy
}


modify_site() {
    mapfile -t DOMAINS < <(grep -E '^[a-zA-Z0-9.-]+ *{' $CADDYFILE | sed 's/ {//')
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

    if [[ "$NUM" == "0" ]]; then
        return
    fi

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效编号${RESET}"
        pause
        return
    fi

    DOMAIN="${DOMAINS[$((NUM-1))]}"

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

    NEW_CONFIG="${DOMAIN} {\n${H2C_CONFIG}    reverse_proxy ${HTTP_TARGET}\n}\n\n"
    sudo sed -i "/$DOMAIN {/,/}/c\\$NEW_CONFIG" $CADDYFILE
    echo -e "${GREEN}域名 ${DOMAIN} 配置已修改${RESET}"

    reload_caddy
}

check_domains_status() {
    echo -e "${GREEN}域名                  状态       到期时间        剩余天数${RESET}"
    echo -e "${GREEN}------------------------------------------------------------${RESET}"

    CERT_DIR="$CADDY_DATA/certificates/acme-v02.api.letsencrypt.org-directory"
    [ ! -d "$CERT_DIR" ] && echo -e "${YELLOW}没有找到任何证书${RESET}" && pause && return

    DOMAINS=($(ls "$CERT_DIR" | sort))
    for DOMAIN in "${DOMAINS[@]}"; do
        CERT_PATH="$CERT_DIR/$DOMAIN/$DOMAIN.crt"
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
        else
            printf "%-22s %-10s %-15s %-10s\n" "$DOMAIN" "未找到证书" "-" "-"
        fi
    done
    pause
}

add_site_with_cert() {
    read -p "请输入域名 (example.com)： " DOMAIN
    read -p "是否需要 h2c/gRPC 代理？(y/n，回车默认 n)： " H2C
    H2C=${H2C:-n}

    SITE_CONFIG="${DOMAIN} {\n"

    # 指定证书
    read -p "请输入证书文件路径 (.pem)： " CERT_PATH
    read -p "请输入私钥文件路径 (.key)： " KEY_PATH
    SITE_CONFIG+="    tls ${CERT_PATH} ${KEY_PATH}\n"

    if [[ "$H2C" == "y" ]]; then
        read -p "请输入 h2c 代理路径 (例如 /proto.NezhaService/*)： " H2C_PATH
        read -p "请输入内网目标地址 (例如 127.0.0.1:8008)： " H2C_TARGET
        SITE_CONFIG+="    reverse_proxy ${H2C_PATH} h2c://${H2C_TARGET}\n"
    fi

    read -p "请输入普通 HTTP 代理目标 (默认 127.0.0.1:8008)： " HTTP_TARGET
    HTTP_TARGET=${HTTP_TARGET:-127.0.0.1:8008}
    SITE_CONFIG+="    reverse_proxy ${HTTP_TARGET}\n"
    SITE_CONFIG+="}\n\n"

    echo -e "$SITE_CONFIG" | sudo tee -a $CADDYFILE >/dev/null
    echo -e "${GREEN}站点 ${DOMAIN} (自定义证书) 添加成功${RESET}"

    reload_caddy
}

# 生成 Emby 反代配置并追加到 Caddyfile
add_emby_site_caddy() {
    echo -ne "${GREEN}请输入您的域名 (例: emby.example.com): ${RESET}"; read DOMAIN
    echo -ne "${GREEN}请输入 Emby 目标地址 (例: https://emby.example.com): ${RESET}"; read TARGET
    
    # 提取主机名，用于判断是否是本地地址
    local TARGET_HOST=$(echo $TARGET | awk -F[/:] '{print $4}')
    
    # 构造 Caddyfile 配置
    # flush_interval -1 相当于 Nginx 的 proxy_buffering off
    # header_up 逻辑用于隐私去 IP 和 Host 伪装
    cat >> $CADDYFILE <<EOF
$DOMAIN {
    reverse_proxy $TARGET {
        # 关闭缓冲，流媒体即时传输
        flush_interval -1

        # 头部伪装与隐私保护
        header_up Host {upstream_hostport}
        header_up X-Real-IP ""
        header_up X-Forwarded-For ""
EOF

    # 如果是反代外部域名，需要开启 SNI
    if [[ "$TARGET" == https* ]]; then
        cat >> $CADDYFILE <<EOF
        header_up Host $TARGET_HOST
        transport http {
            tls_server_name $TARGET_HOST
        }
EOF
    fi

    cat >> $CADDYFILE <<EOF
    }

    # 跨域支持
    header {
        Access-Control-Allow-Origin *
        Access-Control-Allow-Methods "GET, POST, OPTIONS, DELETE, PUT"
        Access-Control-Allow-Headers "X-Emby-Authorization, Content-Type, Authorization, X-Requested-With"
    }
}
EOF

    echo -e "${GREEN}Emby 站点 ${DOMAIN} 已添加至 Caddyfile${RESET}"
    reload_caddy
}

# 函数：主站+推流分离版 (Caddy 重定向逻辑)
add_emby_split_site_caddy() {
    echo -ne "${GREEN}请输入您的域名: ${RESET}"; read DOMAIN
    echo -ne "${GREEN}请输入 Emby 主站地址: ${RESET}"; read T_MAIN
    echo -ne "${GREEN}请输入推流后端地址: ${RESET}"; read T_STREAM

    local STREAM_HOST=$(echo $T_STREAM | awk -F[/:] '{print $4}')

    cat >> $CADDYFILE <<EOF
$DOMAIN {
    # 推流重定向路径 /s1/
    handle_path /s1/* {
        reverse_proxy $T_STREAM {
            flush_interval -1
            header_up Host $STREAM_HOST
            header_up X-Real-IP ""
            header_up X-Forwarded-For ""
        }
    }

    # 主站逻辑
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
    echo -e "${GREEN}主站+推流分离站点已添加${RESET}"
    reload_caddy
}

emby_proxy_menu() {
    clear
    echo -e "${GREEN}==== Emby 反代管理 ====${RESET}"
    echo -e "${GREEN}1) 普通反代${RESET}"
    echo -e "${GREEN}2) 主站 + 推流重定向${RESET}"
    echo -e "${GREEN}0) 返回主菜单${RESET}"
    read -p "请选择操作 [0-2]: " emby_choice

    case $emby_choice in
        1) add_emby_site_caddy ;;
        2) add_emby_split_site_caddy ;;
        0) return ;;
        *) echo -e "${RED}无效选项${RESET}"; pause ;;
    esac
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}==== Caddy 管理====${RESET}"
        echo -e "${GREEN} 1) 安装Caddy${RESET}"
        echo -e "${GREEN} 2) 添加站点${RESET}"
        echo -e "${GREEN} 3) 删除站点${RESET}"
        echo -e "${GREEN} 4) 查看站点证书信息${RESET}"
        echo -e "${GREEN} 5) 修改站点配置${RESET}"
        echo -e "${GREEN} 6) 添加站点(自定义证书)${RESET}"
        echo -e "${GREEN} 7) 重载Caddy${RESET}"
        echo -e "${GREEN} 8) 卸载Caddy${RESET}"
        echo -e "${GREEN} 9) 查看所有域名证书状态${RESET}"
        echo -e "${GREEN}10) Emby反代${RESET}"
        echo -e "${GREEN} 0) 退出${RESET}"
        read -p "$(echo -e ${GREEN} 请选择操作[0-10]：${RESET}) " choice

        case $choice in
            1) install_caddy ;;
            2) add_site ;;
            3) delete_site ;;
            4) view_sites ;;
            5) modify_site ;;
            6) add_site_with_cert ;;
            7) reload_caddy ;;
            8) uninstall_caddy ;;
            9) check_domains_status ;;
            10) emby_proxy_menu ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${RESET}"; pause ;;
        esac
    done
}

menu
