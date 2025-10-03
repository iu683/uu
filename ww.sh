#!/bin/bash
set -e

APP_NAME="caddy"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/Caddyfile"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

pause() {
    echo -ne "${YELLOW}按回车返回菜单...${RESET}"
    read
}

# 安装并启动
install_app() {
    mkdir -p "$APP_DIR/site"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${GREEN}请输入站点信息以生成 Caddyfile${RESET}"
        read -p "请输入域名 (example.com)： " DOMAIN
        read -p "是否需要 h2c/gRPC 代理？(y/n)： " H2C

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

        echo -e "$SITE_CONFIG" > "$CONFIG_FILE"
    fi

    cat > "$COMPOSE_FILE" <<EOF
services:
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ./site:/srv
      - ./caddy_data:/data
      - ./caddy_config:/config
EOF

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ Caddy 已启动${RESET}"
    echo -e "${GREEN}📂 配置文件: $CONFIG_FILE${RESET}"
    echo -e "${GREEN}📂 网站目录: $APP_DIR/site${RESET}"
    pause
}

# 更新
update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; pause; return; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Caddy 已更新并重启完成${RESET}"
    pause
}

# 重启
restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; pause; return; }
    docker compose restart
    echo -e "${GREEN}✅ Caddy 已重启${RESET}"
    pause
}

# 查看日志
view_logs() {
    docker logs -f caddy
    pause
}

# 卸载
uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; pause; return; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Caddy 已卸载，数据已删除${RESET}"
    pause
}

# 添加站点
add_site() {
    read -p "请输入域名 (example.com)： " DOMAIN
    read -p "是否需要 h2c/gRPC 代理？(y/n)： " H2C

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

    echo -e "$SITE_CONFIG" >> "$CONFIG_FILE"
    echo -e "${GREEN}站点 ${DOMAIN} 添加成功${RESET}"
    restart_app
}

# 删除站点（同时可删除证书）
delete_site() {
    mapfile -t DOMAINS < <(grep -E '^[a-zA-Z0-9.-]+ *{' "$CONFIG_FILE" | sed 's/ {//')
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有可删除的域名${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}请选择要删除的域名编号:${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo "$((i+1))) ${DOMAINS[$i]}"
    done
    read -p "输入编号： " NUM
    DOMAIN="${DOMAINS[$((NUM-1))]}"

    # 删除 Caddyfile 中的配置
    sed -i "/$DOMAIN {/,/}/d" "$CONFIG_FILE"
    echo -e "${GREEN}域名 ${DOMAIN} 已从 Caddyfile 删除${RESET}"

    # 删除对应证书目录
    CERT_DIR="$APP_DIR/caddy_data/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN"
    if [ -d "$CERT_DIR" ]; then
        read -p "是否一并删除该域名证书文件？(y/n)： " DEL_CERT
        if [[ "$DEL_CERT" == "y" ]]; then
            rm -rf "$CERT_DIR"
            echo -e "${GREEN}证书目录已删除：${CERT_DIR}${RESET}"
        else
            echo -e "${YELLOW}保留证书：${CERT_DIR}${RESET}"
        fi
    else
        echo -e "${YELLOW}未找到证书目录：${CERT_DIR}${RESET}"
    fi

    restart_app
}


# 修改站点
modify_site() {
    mapfile -t DOMAINS < <(grep -E '^[a-zA-Z0-9.-]+ *{' "$CONFIG_FILE" | sed 's/ {//')
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有可修改的域名${RESET}"
        pause
        return
    fi
    echo -e "${GREEN}请选择要修改的域名编号:${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo "$((i+1))) ${DOMAINS[$i]}"
    done
    read -p "输入编号： " NUM
    DOMAIN="${DOMAINS[$((NUM-1))]}"

    read -p "请输入新的 HTTP 代理目标 (默认 127.0.0.1:8008)： " HTTP_TARGET
    HTTP_TARGET=${HTTP_TARGET:-127.0.0.1:8008}
    read -p "是否需要 h2c/gRPC 代理？(y/n)： " H2C
    H2C_CONFIG=""
    if [[ "$H2C" == "y" ]]; then
        read -p "请输入 h2c 代理路径： " H2C_PATH
        read -p "请输入内网目标地址： " H2C_TARGET
        H2C_CONFIG="    reverse_proxy ${H2C_PATH} h2c://${H2C_TARGET}\n"
    fi
    NEW_CONFIG="${DOMAIN} {\n${H2C_CONFIG}    reverse_proxy ${HTTP_TARGET}\n}\n\n"
    sed -i "/$DOMAIN {/,/}/c\\$NEW_CONFIG" "$CONFIG_FILE"
    echo -e "${GREEN}域名 ${DOMAIN} 配置已修改${RESET}"
    restart_app
}

# 查看已配置域名并可查看证书信息
view_sites() {
    mapfile -t DOMAINS < <(grep -E '^[a-zA-Z0-9.-]+ *{' "$CONFIG_FILE" | sed 's/ {//')
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有已配置的域名${RESET}"
        pause
        return
    fi

    echo -e "${GREEN}当前已配置的域名:${RESET}"
    for i in "${!DOMAINS[@]}"; do
        echo "$((i+1))) ${DOMAINS[$i]}"
    done

    read -p "输入编号查看证书信息（输入0返回菜单）： " NUM
    if [[ "$NUM" == "0" ]]; then
        return
    fi

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#DOMAINS[@]} ]; then
        echo -e "${RED}无效编号${RESET}"
        pause
        return
    fi

    DOMAIN="${DOMAINS[$((NUM-1))]}"
    CERT_PATH="$APP_DIR/caddy_data/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN/$DOMAIN.crt"

    if [ -f "$CERT_PATH" ]; then
        echo -e "${GREEN}证书路径：${RESET}${CERT_PATH}"
        echo -e "${GREEN}证书信息：${RESET}"
        openssl x509 -in "$CERT_PATH" -noout -text | awk '
            /Subject:/ || /Issuer:/ || /Not Before:/ || /Not After :/ {print}'
    else
        echo -e "${YELLOW}${DOMAIN} - 未找到证书${RESET}"
    fi

    pause
}


# 查看证书状态
view_certs() {

    CADDY_DATA="$APP_DIR/caddy_data"
    CERT_DIR="$CADDY_DATA/certificates/acme-v02.api.letsencrypt.org-directory"

    echo -e "${GREEN}域名                  状态       到期时间        剩余天数${RESET}"
    echo -e "${GREEN}------------------------------------------------------------${RESET}"

    if [ ! -d "$CERT_DIR" ]; then
        echo -e "${YELLOW}没有找到任何证书${RESET}"
        pause
        return
    fi

    DOMAINS=($(ls "$CERT_DIR" | sort))
    for DOMAIN in "${DOMAINS[@]}"; do
        CERT_PATH="$CERT_DIR/$DOMAIN/$DOMAIN.crt"
        if [ -f "$CERT_PATH" ]; then
            END_DATE=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
            END_TS=$(date -d "$END_DATE" +%s)
            NOW_TS=$(date +%s)
            DAYS_LEFT=$(( (END_TS - NOW_TS) / 86400 ))

            if [ $DAYS_LEFT -ge 30 ]; then
                STATUS="${GREEN}有效${RESET}"
            elif [ $DAYS_LEFT -ge 0 ]; then
                STATUS="${YELLOW}即将过期${RESET}"
            else
                STATUS="${RED}已过期${RESET}"
            fi

            printf "%-22s %-12b %-15s %d 天\n" \
                "$DOMAIN" "$STATUS" "$(date -d "$END_DATE" +"%Y-%m-%d")" "$DAYS_LEFT"
        else
            printf "%-22s %-12b %-15s %-10s\n" "$DOMAIN" "${RED}未找到证书${RESET}" "-" "-"
        fi
    done
    pause
}

# 添加站点（自定义证书）
add_site_with_cert() {
    read -p "请输入域名 (example.com)： " DOMAIN
    read -p "是否需要 h2c/gRPC 代理？(y/n)： " H2C

    # 输入证书路径
    read -p "请输入证书文件路径 (.pem)： " CERT_PATH
    read -p "请输入私钥文件路径 (.key)： " KEY_PATH

    SITE_CONFIG="${DOMAIN} {\n"
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

    echo -e "$SITE_CONFIG" >> "$CONFIG_FILE"
    echo -e "${GREEN}站点 ${DOMAIN} (自定义证书) 添加成功${RESET}"

    restart_app
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Caddy Docker 管理脚本 ===${RESET}"
        echo -e "${GREEN} 1) 安装启动${RESET}"
        echo -e "${GREEN} 2) 更新${RESET}"
        echo -e "${GREEN} 3) 重启${RESET}"
        echo -e "${GREEN} 4) 查看日志${RESET}"
        echo -e "${GREEN} 5) 卸载${RESET}"
        echo -e "${GREEN} 6) 添加站点${RESET}"
        echo -e "${GREEN} 7) 删除站点${RESET}"
        echo -e "${GREEN} 8) 修改站点${RESET}"
        echo -e "${GREEN} 9) 添加站点(自定义证书)${RESET}"
        echo -e "${GREEN}10) 查看已配置域名${RESET}"
        echo -e "${GREEN}11) 查看证书状态${RESET}"
        echo -e "${GREEN} 0) 退出${RESET}"
        read -p "请选择操作[0-10]： " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) uninstall_app ;;
            6) add_site ;;
            7) delete_site ;;
            8) modify_site ;;
            9) add_site_with_cert ;;
            10) view_sites ;;
            11) view_certs ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${RESET}"; pause ;;
        esac
    done
}

menu
