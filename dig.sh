#!/bin/bash
set -e

CADDYFILE="/etc/caddy/Caddyfile"
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
        sudo apt install -yq debian-keyring debian-archive-keyring apt-transport-https curl
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
        sudo apt update -q
        sudo apt install -yq caddy
        echo -e "${GREEN}Caddy 安装完成${RESET}"
    else
        echo -e "${GREEN}Caddy 已安装${RESET}"
    fi
}

uninstall_caddy() {
    if command -v caddy >/dev/null 2>&1; then
        echo -e "${GREEN}正在卸载 Caddy...${RESET}"
        sudo systemctl stop caddy
        sudo apt remove -y caddy
        sudo apt autoremove -y
        sudo rm -f /etc/apt/sources.list.d/caddy-stable.list
        sudo rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        echo -e "${GREEN}Caddy 已卸载${RESET}"
    else
        echo -e "${RED}Caddy 未安装${RESET}"
    fi
}

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

    echo -e "$SITE_CONFIG" | sudo tee -a $CADDYFILE >/dev/null
    echo -e "${GREEN}站点 ${DOMAIN} 添加成功${RESET}"

    reload_caddy
}

view_sites() {
    echo -e "${GREEN}当前 Caddy 配置域名及证书到期时间:${RESET}"
    mapfile -t DOMAINS < <(grep -E '^[a-zA-Z0-9.-]+ *{' $CADDYFILE | sed 's/ {//')
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有已配置的域名${RESET}"
    else
        for i in "${!DOMAINS[@]}"; do
            DOMAIN="${DOMAINS[$i]}"
            CERT_FILE="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org/sites/${DOMAIN}/certificate.crt"
            if [ -f "$CERT_FILE" ]; then
                EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)
                EXPIRY_SEC=$(date -d "$EXPIRY" +%s)
                NOW_SEC=$(date +%s)
                DIFF_DAYS=$(( (EXPIRY_SEC - NOW_SEC) / 86400 ))
                if [ $DIFF_DAYS -le 30 ]; then
                    RENEW_MSG="${RED}需要续期!${RESET}"
                else
                    RENEW_MSG="${GREEN}无需续期${RESET}"
                fi
            else
                EXPIRY="未找到证书"
                RENEW_MSG="${YELLOW}未知${RESET}"
            fi
            echo "$((i+1))) ${DOMAIN} 证书到期: ${EXPIRY} - ${RENEW_MSG}"
        done
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
    sudo sed -i "/$DOMAIN {/,/}/d" $CADDYFILE
    echo -e "${GREEN}域名 ${DOMAIN} 已删除${RESET}"
    reload_caddy
}

reload_caddy() {
    sudo systemctl reload caddy
    echo -e "${GREEN}Caddy 配置已重载${RESET}"
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}==== Caddy 管理脚本====${RESET}"
        echo -e "${GREEN}1) 安装 Caddy${RESET}"
        echo -e "${GREEN}2) 添加站点${RESET}"
        echo -e "${GREEN}3) 删除站点${RESET}"
        echo -e "${GREEN}4) 查看站点${RESET}"
        echo -e "${GREEN}5) 重载Caddy${RESET}"
        echo -e "${GREEN}6) 卸载Caddy${RESET}"
        echo -e "${GREEN}0) 退出${RESET}${RESET}"
        read -p "请选择操作[0-6]： " choice

        case $choice in
            1) install_caddy ;;
            2) add_site ;;
            3) delete_site ;;
            4) view_sites ;;
            5) reload_caddy ;;
            6) uninstall_caddy ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${RESET}"; pause ;;
        esac
    done
}

menu
