#!/bin/bash

# ================== 颜色变量 ==================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误: 请使用root用户运行此脚本${NC}"
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

check_port() {
    local port=$1
    if lsof -i:$port &> /dev/null; then
        echo -e "✗ 端口 $port........ ${RED}被占用${NC}"
    else
        echo -e "✓ 端口 $port........ ${GREEN}可用${NC}"
    fi
}

create_docker_compose() {
    local domain=$1
    local root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
    local admin_email="admin@${root_domain}"

    mkdir -p /opt/posteio
    cd /opt/posteio || exit 1

    cat > docker-compose.yml << EOF
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
      - "8808:80"
      - "8843:443"
    environment:
      - LETSENCRYPT_EMAIL=${admin_email}
      - LETSENCRYPT_HOST=${domain}
      - VIRTUAL_HOST=${domain}
      - DISABLE_CLAMAV=TRUE
      - DISABLE_RSPAMD=TRUE
      - TZ=Asia/Shanghai
      - HTTPS=OFF
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./mail-data:/data
EOF
}

show_dns_info() {
    local domain=$1
    local ip=$(curl -s ifconfig.me)
    local root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')

    echo -e "\n\033[38;5;81m────────────────────────\033[0m"
    echo -e "${GREEN}▶ 请配置以下DNS记录：${NC}"
    echo -e "${GREEN}▶ A       mail      ${ip}${NC}"
    echo -e "${GREEN}▶ CNAME   imap      ${domain}${NC}"
    echo -e "${GREEN}▶ CNAME   pop       ${domain}${NC}"
    echo -e "${GREEN}▶ CNAME   smtp      ${domain}${NC}"
    echo -e "${GREEN}▶ MX      @         ${domain}${NC}"
    echo -e "${GREEN}▶ TXT     @         v=spf1 mx ~all${NC}"
    echo -e "${GREEN}▶ TXT     _dmarc    v=DMARC1; p=none; rua=mailto:admin@${root_domain}${NC}"
    echo -e "\033[38;5;81m────────────────────────\033[0m"
}

main_menu_action() {
    local choice=$1
    case $choice in
        1)
            read -p "请输入邮箱域名 (例如: mail.example.com): " domain
            create_docker_compose "$domain"
            cd /opt/posteio
            echo "正在启动服务..."
            docker-compose up -d || { echo -e "${RED}启动失败！${NC}"; exit 1; }
            show_dns_info "$domain"
            local ip=$(curl -s ifconfig.me)

            echo -e "\n\033[38;5;81m────────────────────────\033[0m"
            echo -e "${GREEN}▶ 安装完成！${NC}"
            echo -e "${GREEN}▶ 首次配置页面: https://${domain}${NC}"
            echo -e "${GREEN}▶ 管理后台: https://${domain}/admin${NC}"
            echo -e "${GREEN}▶ 默认管理员账号: admin@${domain#mail.}${NC}"
            echo -e "${GREEN}▶ 访问地址(IP:8808): http://${ip}:8808${NC}"
            echo -e "\033[38;5;81m────────────────────────\033[0m"
            ;;
        2)
            if [ -d "/opt/posteio" ]; then
                cd /opt/posteio
                echo "正在更新服务..."
                docker-compose pull
                docker-compose up -d
                echo -e "\n\033[38;5;81m────────────────────────\033[0m"
                echo -e "${GREEN}▶ 更新完成！${NC}"
                echo -e "\033[38;5;81m────────────────────────\033[0m"
            else
                echo -e "\n${RED}未找到安装目录！${NC}"
            fi
            ;;
        3)
            if [ -d "/opt/posteio" ]; then
                cd /opt/posteio
                echo "正在卸载服务..."
                docker-compose down
                docker images | awk '/poste\.io/ {print $3}' | xargs -r docker rmi -f
                cd /opt
                rm -rf posteio
                echo -e "\n\033[38;5;81m────────────────────────\033[0m"
                echo -e "${GREEN}▶ 已完全卸载服务、数据和镜像！${NC}"
                echo -e "\033[38;5;81m────────────────────────\033[0m"
            else
                echo -e "\n${RED}未找到安装目录！${NC}"
            fi
            ;;
    esac

    read -p "按回车返回菜单，或输入 q 退出: " back
    [[ "$back" == "q" ]] && exit 0
    initial_check
}

initial_check() {
    clear
    check_docker

    # 菜单标题
    echo -e "\033[1;36m=====  Poste.io菜单管理 =====\033[0m\n"

    echo -e "\033[1;36m系统检查\033[0m"
    echo -e "\033[38;5;81m────────────────────────\033[0m"

    echo -n "✓ Telnet......... "
    if command -v telnet &> /dev/null; then
        echo -e "${GREEN}已安装${NC}"
    else
        echo -e "${RED}未安装${NC}"
        echo "正在安装telnet..."
        apt-get update && apt-get install -y telnet > /dev/null 2>&1
    fi

    echo -n "✓ 邮局服务....... "
    if [ -d "/opt/posteio" ]; then
        echo -e "${GREEN}已安装${NC}"
    else
        echo -e "${RED}未安装${NC}"
    fi

    echo -e "\n\033[1;36m端口检测\033[0m"
    echo -e "\033[38;5;81m────────────────────────\033[0m"

    # 远程25端口检测
    port=25
    timeout=3
    telnet_output=$(echo "quit" | timeout $timeout telnet smtp.qq.com $port 2>&1)
    if echo "$telnet_output" | grep -q "Connected"; then
        echo -e "✓ 端口 $port........ ${GREEN}可访问外网SMTP${NC}"
    else
        echo -e "✗ 端口 $port........ ${RED}不可访问外网SMTP${NC}"
    fi

    # 其他端口检查
    for port in 587 110 143 993 995 465 80 443; do
        check_port $port
    done

    echo -e "\n\033[1;36m操作选项\033[0m"
    echo -e "\033[38;5;81m────────────────────────\033[0m"

    local menu_options=("安装 Poste.io" "更新服务" "卸载 Poste.io" "退出脚本")
    local colors=($GREEN $GREEN $GREEN $GREEN)

    for i in "${!menu_options[@]}"; do
        printf "${colors[i]}▶ %d. %s${NC}\n" $((i+1)) "${menu_options[i]}"
    done

    echo -e "\033[38;5;81m────────────────────────\033[0m"
    read -p "$(echo -e "\033[1;33m请输入选项 [1-4]: \033[0m")" choice

    case $choice in
        1|2|3)
            main_menu_action $choice
            ;;
        4)
            echo -e "\n${GREEN}感谢使用，再见！${NC}"
            exit 0
            ;;
        *)
            echo -e "\n${RED}无效选项，请重新选择${NC}"
            sleep 2
            initial_check
            ;;
    esac
}

check_root
initial_check
