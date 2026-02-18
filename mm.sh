#!/bin/bash
set -e

CADDYFILE="/etc/caddy/Caddyfile"
CADDY_DATA="/root/.local/share/caddy"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

pause() {
    echo -ne "${YELLOW}按回车返回菜单...${RESET}"
    read
}

install_caddy() {
    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${GREEN}正在安装 Caddy...${RESET}"
        sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
        sudo apt update
        sudo apt install -y caddy
        echo -e "${GREEN}Caddy 安装完成${RESET}"
    else
        echo -e "${GREEN}Caddy 已安装${RESET}"
    fi

    # 🔥 确保 systemd 服务存在
    if [ ! -f /etc/systemd/system/caddy.service ]; then
        echo -e "${YELLOW}创建 systemd 服务文件...${RESET}"
        sudo tee /etc/systemd/system/caddy.service >/dev/null <<EOF
[Unit]
Description=Caddy
After=network.target

[Service]
User=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    fi

    sudo systemctl daemon-reload
    sudo systemctl enable caddy
    sudo systemctl restart caddy

    echo -e "${GREEN}Caddy 已启动 (systemd 模式)${RESET}"
    pause
}


uninstall_caddy() {
    if command -v caddy >/dev/null 2>&1; then
        echo -e "${GREEN}正在卸载 Caddy...${RESET}"

        # 停止服务
        sudo systemctl stop caddy 2>/dev/null || true
        sudo systemctl disable caddy 2>/dev/null || true
        sudo systemctl daemon-reload

        # 删除 apt 安装的 caddy
        sudo apt remove -y caddy
        sudo apt autoremove -y

        # 删除源和 keyring
        sudo rm -f /etc/apt/sources.list.d/caddy-stable.list
        sudo rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg

        # 删除 Caddy 系统数据和配置
        sudo rm -rf /etc/caddy
        sudo rm -rf /var/lib/caddy
        sudo rm -rf /var/log/caddy
        sudo rm -rf /usr/bin/caddy
        sudo rm -rf /usr/local/bin/caddy

        # 删除残留 systemd 服务文件（如果有）
        sudo rm -f /etc/systemd/system/caddy.service
        sudo rm -f /lib/systemd/system/caddy.service
        sudo systemctl daemon-reload

        echo -e "${GREEN}Caddy 已彻底卸载${RESET}"
    else
        echo -e "${RED}Caddy 未安装${RESET}"
    fi
    pause
}


reload_caddy() {
    if systemctl is-active --quiet caddy; then
        sudo systemctl reload caddy
        echo -e "${GREEN}Caddy 配置已重载${RESET}"
    else
        echo -e "${YELLOW}Caddy 未运行，正在启动...${RESET}"
        sudo systemctl start caddy
        echo -e "${GREEN}Caddy 已启动${RESET}"
    fi
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

    # 删除旧配置块
    sudo awk -v domain="$DOMAIN" '
        $0 ~ "^"domain"[[:space:]]*{" {flag=1; next}
        flag && $0 ~ "^}" {flag=0; next}
        !flag {print}
    ' $CADDYFILE | sudo tee ${CADDYFILE}.tmp >/dev/null

    sudo mv ${CADDYFILE}.tmp $CADDYFILE

    # 追加新配置
    echo -e "$NEW_CONFIG" | sudo tee -a $CADDYFILE >/dev/null

    echo -e "${GREEN}域名 ${DOMAIN} 配置已修改${RESET}"
    caddy validate --config $CADDYFILE
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

menu() {
    while true; do
        clear
        echo -e "${GREEN}==== Caddy 管理脚本====${RESET}"
        echo -e "${GREEN}1) 安装Caddy${RESET}"
        echo -e "${GREEN}2) 添加站点${RESET}"
        echo -e "${GREEN}3) 删除站点${RESET}"
        echo -e "${GREEN}4) 查看站点证书信息${RESET}"
        echo -e "${GREEN}5) 修改站点配置${RESET}"
        echo -e "${GREEN}6) 添加站点(自定义证书)${RESET}"
        echo -e "${GREEN}7) 重载Caddy${RESET}"
        echo -e "${GREEN}8) 卸载Caddy${RESET}"
        echo -e "${GREEN}9) 查看所有域名证书状态${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择操作[0-9]：${RESET}) " choice

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
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${RESET}"; pause ;;
        esac
    done
}

menu
