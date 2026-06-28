#!/bin/bash
# ==========================================
# Poste.io 一键管理脚本 
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

# 获取公网 IP (兼容双栈环境)
get_public_ip() {
    local mode=${1:-"auto"}
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
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

check_port() {
    local port=$1
    if lsof -i:$port &> /dev/null; then
        echo -e "${YELLOW}✗ 端口 $port........ ${RED}被占用${RESET}"
    else
        echo -e "${YELLOW}✓ 端口 $port........ ${GREEN}可用${RESET}"
    fi
}

# ==================== 端口检测 ====================
port_check() {
    echo -e "${YELLOW}端口检测${RESET}"
    # 检测 timeout 是否安装
    if ! command -v timeout &>/dev/null; then
        echo -e "${YELLOW}检测到系统未安装 timeout，正在安装...${RESET}"
        if [ -x "$(command -v apt)" ]; then
            apt update && apt install -y coreutils
        elif [ -x "$(command -v yum)" ]; then
            yum install -y coreutils
        else
            echo -e "${RED}无法自动安装 timeout，请手动安装 coreutils${RESET}"
            return
        fi
    fi
    # 远程 SMTP 25 端口检测
    port=25
    timeout=3
    telnet_output=$(echo "quit" | timeout $timeout telnet smtp.qq.com $port 2>&1)
    if echo "$telnet_output" | grep -q "Connected"; then
        echo -e "${YELLOW}✓ 端口 $port........ ${GREEN}可访问外网SMTP${RESET}"
    else
        echo -e "${YELLOW}✗ 端口 $port........ ${RED}不可访问外网SMTP${RESET}"
    fi

    # 其他常用端口检测（只看能否连通）
    for port in 587 110 143 993 995 465 80 443; do
        check_port $port
    done

    read -p "按回车返回菜单..."
}

show_dns_info() {
    local domain=$1
    local ip=$(get_public_ip)
    local root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
    echo -e "${YELLOW}================ DNS 配置参考 ================${RESET}"
    echo -e "${GREEN}▶ A      mail      ${ip}${RESET}"
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
    read -p "请输入Web HTTP 端口 [默认:80]: " web_port
    WEB_PORT=${web_port:-80}
    read -p "请输入Web HTTPS 端口 [默认:443]: " https_port
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
    SERVER_IP=$(get_public_ip)
    admin_email="admin@${domain#mail.}"
    echo -e "${YELLOW}=======================================${RESET}"
    echo -e "${YELLOW}访问 Web 邮局 : https://${domain}${RESET}"
    echo -e "${YELLOW}访问管理后台  : https://${domain}/admin${RESET}"
    echo -e "${YELLOW}默认管理员邮箱: ${admin_email}${RESET}"
    echo -e "${YELLOW}访问地址      : http://${SERVER_IP}:${WEB_PORT}${RESET}"
    echo -e "${YELLOW}=======================================${RESET}"
    read -p "按回车返回菜单..."
}

# 辅助函数：启动容器
start_container() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" || exit 1
        docker-compose start
        echo -e "${GREEN}✅ 容器已启动${RESET}"
    else
        echo -e "${RED}未检测到安装目录，请先安装${RESET}"
    fi
    sleep 1
}

# 辅助函数：停止容器
stop_container() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" || exit 1
        docker-compose stop
        echo -e "${YELLOW}🔒 容器已停止${RESET}"
    else
        echo -e "${RED}未检测到安装目录${RESET}"
    fi
    sleep 1
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
    sleep 1
}

view_logs() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" || exit 1
        echo -e "${BLUE}显示 Poste.io 容器日志 (Ctrl+C 退出)...${RESET}"
        docker-compose logs -f
    else
        echo -e "${RED}未检测到安装目录，请先安装${RESET}"
        read -p "按回车返回菜单..."
    fi
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
    echo -ne "${YELLOW}确定要卸载并删除 Poste.io 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$APP_DIR" && docker-compose down
            rm -rf "$APP_DIR"
            echo -e "${GREEN}容器已停止，本地配置与数据目录已彻底清理。${RESET}"
        else
            docker rm -f "${APP_NAME}-mailserver" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
    read -p "按回车返回菜单..."
}


get_status_and_port() {
    if [ -d "$APP_DIR" ] && [ -f "$COMPOSE_FILE" ]; then
        # 提取绑定的 HTTP 端口
        webui_port=$(grep -E '\-[[:space:]]*"[0-9]+:80"' "$COMPOSE_FILE" | grep -oE '[0-9]+:80' | cut -d: -f1)
        [ -z "$webui_port" ] && webui_port="80"
        
        # 通过 docker inspect 获取容器运行状态
        local run_status=$(docker inspect -f '{{.State.Status}}' "${APP_NAME}-mailserver-1" 2>/dev/null)
        if [ "$run_status" == "running" ]; then
            status="${GREEN}运行中${RESET}"
        elif [ -n "$run_status" ]; then
            status="${YELLOW}已停止 ($run_status)${RESET}"
        else
            status="${RED}未启动 (容器不存在)${RESET}"
        fi
    else
        status="${RED}未安装${RESET}"
        webui_port="未配置"
    fi
}


menu() {
    clear
    get_status_and_port
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Poste.io 邮箱服务  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 检测端口${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) start_container ;;
        5) stop_container ;;
        6) restart_app ;;
        7) view_logs ;;
        8) port_check ;; 
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
    esac
    menu
}

check_root
menu
