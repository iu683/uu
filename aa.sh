#!/bin/bash
# =========================================
# Poste.io Docker 管理脚本（统一路径 /opt/posteio）
# =========================================

# ================== 颜色 ==================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

INSTALL_DIR="/opt/posteio"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
DATA_DIR="$INSTALL_DIR/mail-data"

# ================== 检查 root ==================
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误: 请使用 root 用户运行此脚本${NC}"
        exit 1
    fi
}

# ================== 检查 Docker ==================
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

# ================== 检查端口 ==================
check_port() {
    local port=$1
    if lsof -i:$port &> /dev/null; then
        echo -e "✗ 端口 $port........ ${RED}被占用${NC}"
    else
        echo -e "✓ 端口 $port........ ${GREEN}可用${NC}"
    fi
}

# ================== 生成 docker-compose.yml ==================
create_docker_compose() {
    local domain=$1
    local root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
    local admin_email="admin@${root_domain}"

    mkdir -p "$DATA_DIR"

    cat > "$COMPOSE_FILE" << EOF
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
      - ${DATA_DIR}:/data
EOF
}

# ================== 显示 DNS 信息 ==================
show_dns_info() {
    local domain=$1
    local ip=$(curl -s ifconfig.me)
    local root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')

    echo -e "\n${GREEN}==== 请配置以下 DNS 记录 ====${NC}"
    echo -e "${GREEN}A       mail      ${ip}${NC}"
    echo -e "${GREEN}CNAME   imap      ${domain}${NC}"
    echo -e "${GREEN}CNAME   pop       ${domain}${NC}"
    echo -e "${GREEN}CNAME   smtp      ${domain}${NC}"
    echo -e "${GREEN}MX      @         ${domain}${NC}"
    echo -e "${GREEN}TXT     @         v=spf1 mx ~all${NC}"
    echo -e "${GREEN}TXT     _dmarc    v=DMARC1; p=none; rua=mailto:admin@${root_domain}${NC}"
    echo -e "=============================="
}

# ================== 安装 ==================
install_posteio() {
    read -p "请输入邮箱域名 (例如 mail.example.com): " domain
    create_docker_compose "$domain"
    cd "$INSTALL_DIR"
    echo "正在启动 Poste.io 服务..."
    docker-compose up -d || { echo -e "${RED}启动失败！${NC}"; exit 1; }
    show_dns_info "$domain"

    local ip=$(curl -s ifconfig.me)
    echo -e "${GREEN}▶ 安装完成！${NC}"
    echo -e "${GREEN}▶ 管理页面: https://${domain}/admin${NC}"
    echo -e "${GREEN}▶ 默认管理员账号: admin@${domain#mail.}${NC}"
    echo -e "${GREEN}▶ 访问地址(IP:8808): http://${ip}:8808${NC}"
}

# ================== 更新 ==================
update_posteio() {
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${RED}未找到安装目录！请先安装 Poste.io${NC}"
        return
    fi
    cd "$INSTALL_DIR"
    echo "正在更新服务..."
    docker-compose pull
    docker-compose up -d
    echo -e "${GREEN}▶ 更新完成！${NC}"
}

# ================== 卸载 ==================
uninstall_posteio() {
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${RED}未找到安装目录！${NC}"
        return
    fi
    read -p "⚠️ 确认要卸载并删除数据吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        cd "$INSTALL_DIR"
        docker-compose down
        docker images | awk '/poste\.io/ {print $3}' | xargs -r docker rmi -f
        rm -rf "$INSTALL_DIR"
        echo -e "${GREEN}▶ 已完全卸载 Poste.io，包括数据和镜像！${NC}"
    else
        echo "已取消卸载。"
    fi
}

# ================== 菜单 ==================
main_menu() {
    while true; do
        clear
        echo -e "${GREEN}===== Poste.io 管理菜单 =====${NC}"
        echo -e "${GREEN}1) 安装 Poste.io${NC}"
        echo -e "${GREEN}2) 更新 Poste.io${NC}"
        echo -e "${GREEN}3) 卸载 Poste.io${NC}"
        echo -e "${GREEN}4) 退出${NC}"
        echo -e "=============================="
        read -p "请选择操作 [1-4]: " choice
        case $choice in
            1) install_posteio ;;
            2) update_posteio ;;
            3) uninstall_posteio ;;
            4) exit 0 ;;
            *) echo -e "${RED}无效选择${NC}" ; sleep 1 ;;
        esac
        read -p "按回车返回菜单..." dummy
    done
}

# ================== 执行 ==================
check_root
check_docker
main_menu
