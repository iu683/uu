#!/bin/bash
# ==========================================
# Poste.io 一键管理脚本 (Docker)
# ==========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

APP_NAME="posteio"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误: 请使用root用户运行此脚本${RESET}"
        exit 1
    fi
}

check_docker() {
    export PATH=$PATH:/usr/local/bin
    if ! command -v docker &> /dev/null; then
        echo "正在安装 Docker..."
        curl -fsSL https://get.docker.com | sh || { echo "Docker 安装失败"; exit 1; }
    fi
    if ! command -v docker-compose &> /dev/null; then
        echo "正在安装 Docker Compose..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || { echo "Docker Compose 下载失败"; exit 1; }
        chmod +x /usr/local/bin/docker-compose
    fi
}



# ==================== 端口检测 ====================
check_port() {
    local port=$1
    local timeout=3
    nc -z -w $timeout 8.8.8.8 $port &>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${YELLOW}✓ 端口 $port........ ${GREEN}可访问${RESET}"
    else
        echo -e "${YELLOW}✗ 端口 $port........ ${RED}不可访问${RESET}"
    fi
}

port_check() {
    echo -e "${YELLOW}端口检测${RESET}"
    # 远程 SMTP 25 端口检测
    port=25
    timeout=3
    telnet_output=$(echo "quit" | timeout $timeout telnet smtp.qq.com $port 2>&1)
    if echo "$telnet_output" | grep -q "Connected"; then
        echo -e "${YELLOW}✓ 端口 $port........ ${GREEN}可访问外网SMTP${RESET}"
    else
        echo -e "${YELLOW}✗ 端口 $port........ ${RED}不可访问外网SMTP${RESET}"
    fi

    # 检测其他常用端口
    for port in 587 110 143 993 995 465 80 443; do
        check_port $port
    done

    read -p "按回车返回菜单..."
}
show_dns_info() {
    local domain=$1
    local ip=$(curl -s ifconfig.me)
    local root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
    echo -e "${YELLOW}================ DNS 配置参考 ================${RESET}"
    echo -e "${GREEN}▶ A       mail      ${ip}${RESET}"
    echo -e "${GREEN}▶ CNAME   imap      ${domain}${RESET}"
    echo -e "${GREEN}▶ CNAME   pop       ${domain}${RESET}"
    echo -e "${GREEN}▶ CNAME   smtp      ${domain}${RESET}"
    echo -e "${GREEN}▶ MX      @         ${domain}${RESET}"
    echo -e "${GREEN}▶ TXT     @         v=spf1 mx ~all${RESET}"
    echo -e "${GREEN}▶ TXT     _dmarc    v=DMARC1; p=none; rua=mailto:admin@${root_domain}${RESET}"
    echo -e "${BLUE}===============================================${RESET}"
}

install_app() {
    read -p "请输入邮箱域名 (例如: mail.example.com): " domain
    read -p "请输入 Web HTTP 端口 [默认:80]: " web_port
    WEB_PORT=${web_port:-80}
    read -p "请输入 Web HTTPS 端口 [默认:443]: " https_port
    HTTPS_PORT=${https_port:-443}

    read -p "是否禁用反病毒 ClamAV (TRUE/FALSE) [默认:TRUE]: " clamav_input
    DISABLE_CLAMAV=${clamav_input:-TRUE}

    read -p "是否禁用反垃圾邮件 Rspamd (TRUE/FALSE) [默认:TRUE]: " rspamd_input
    DISABLE_RSPAMD=${rspamd_input:-TRUE}

    read -p "是否启用 HTTPS (ON/OFF) [默认:OFF]: " https_input
    HTTPS=${https_input:-OFF}

    mkdir -p "$APP_DIR/mail-data"
    cd "$APP_DIR" || exit 1

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  mailserver:
    image: analogic/poste.io
    hostname: ${domain}
    ports:
      - "25:25"
      - "110:110"
      - "143:143"
      - "587:587"
      - "993:993"
      - "995:995"
      - "4190:4190"
      - "465:465"
      - "${WEB_PORT}:80"
      - "${HTTPS_PORT}:443"
    environment:
      - LETSENCRYPT_EMAIL=admin@${domain}
      - LETSENCRYPT_HOST=${domain}
      - VIRTUAL_HOST=${domain}
      - DISABLE_CLAMAV=${DISABLE_CLAMAV}
      - DISABLE_RSPAMD=${DISABLE_RSPAMD}
      - TZ=Asia/Shanghai
      - HTTPS=${HTTPS}
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./mail-data:/data
EOF

    echo -e "${BLUE}正在启动 Poste.io 服务...${RESET}"
    docker-compose up -d
    echo -e "${GREEN}✅ 服务已启动${RESET}"

    # 显示 DNS 信息
    show_dns_info "$domain"

    # 默认管理员账号提示
    admin_email="admin@${domain#mail.}"
    echo -e "${YELLOW}访问 Web 邮局: https://${domain}${RESET}"
    echo -e "${YELLOW}访问管理后台: https://${domain}/admin${RESET}"
    echo -e "${YELLOW}默认管理员邮箱: ${admin_email}${RESET}"
    echo -e "${GREEN}     访问地址: http://$(hostname -I | awk '{print $1}'):${WEB_PORT}${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" || exit 1
        echo -e "${BLUE}正在重启 Poste.io 服务...${RESET}"
        docker-compose restart
        echo -e "${GREEN}✅ 服务已重启${RESET}"
    else
        echo -e "${RED}未检测到安装目录，请先安装${RESET}"
    fi
    read -p "按回车返回菜单..."
}

view_logs() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" || exit 1
        echo -e "${BLUE}显示 Poste.io 容器日志 (Ctrl+C 退出)...${RESET}"
        docker-compose logs -f
    else
        echo -e "${RED}未检测到安装目录，请先安装${RESET}"
    fi
    read -p "按回车返回菜单..."
}

update_app() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" || exit 1
        echo -e "${BLUE}正在更新 Poste.io 服务...${RESET}"
        docker-compose pull
        docker-compose up -d
        echo -e "${GREEN}✅ 服务已更新${RESET}"
    else
        echo -e "${RED}未检测到安装目录，请先安装${RESET}"
    fi
    read -p "按回车返回菜单..."
}

uninstall_app() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" || exit 1
        echo -e "${BLUE}正在卸载 Poste.io 服务...${RESET}"
        docker-compose down
        docker images | awk '/poste\.io/ {print $3}' | xargs -r docker rmi -f
        rm -rf "$APP_DIR"
        echo -e "${RED}✅ 已卸载服务及数据${RESET}"
    else
        echo -e "${RED}未检测到安装目录${RESET}"
    fi
    read -p "按回车返回菜单..."
}

menu() {
    clear
    echo -e "${GREEN}=== Poste.io 邮件服务器管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 查看日志${RESET}"
    echo -e "${GREEN}4) 卸载(含数据)${RESET}"
    echo -e "${GREEN}5) 端口检测${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) view_logs ;;
        4) uninstall_app ;;
        5) port_check ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
    menu
}

check_root
menu
