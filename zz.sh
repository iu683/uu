#!/bin/bash

# ==========================================
# Mosdns-x 一键管理脚本
# ==========================================

set +e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置
MOSDNS_BINARY="/usr/local/bin/mosdns-x"
MOSDNS_CONFIG_DIR="/etc/mosdns-x"
MOSDNS_CONFIG_FILE="/etc/mosdns-x/config.yaml"
MOSDNS_LOG_DIR="/var/log/mosdns-x"
MOSDNS_LOG_FILE="/var/log/mosdns-x/mosdns-x.log"
MOSDNS_SERVICE_FILE="/etc/systemd/system/mosdns.service"
MOSDNS_LOGROTATE_FILE="/etc/logrotate.d/mosdns-x"
MOSDNS_USER="mosdns"
MOSDNS_GROUP="mosdns"
RESOLV_CONF_BACKUP="/etc/resolv.conf.mosdns-backup"

GITHUB_REPO="pmkol/mosdns-x"
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

# ==========================================
# 输出函数
# ==========================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ==========================================
# 基础函数
# ==========================================

check_root() {
    [[ $EUID -ne 0 ]] && {
        log_error "请使用 root 权限运行"
        exit 1
    }
}

pause() {
    echo
    read -rp "$(echo -e ${GREEN}按回车返回菜单...${NC})"
}

get_architecture() {
    case $(uname -m) in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l) echo "arm" ;;
        *) echo "unsupported" ;;
    esac
}

get_latest_version() {
    curl -s "$GITHUB_API_URL" | grep -o '"tag_name": "[^"]*' | grep -o '[^"]*$' || echo "v25.10.08"
}

get_current_version() {
    if [[ -f "$MOSDNS_BINARY" ]]; then
        $MOSDNS_BINARY version 2>/dev/null | grep -o 'v[0-9.]*' | head -1
    else
        echo "未安装"
    fi
}

# ==========================================
# 安装依赖
# ==========================================

check_dependencies() {
    log_info "安装依赖..."

    apt update

    apt install -y \
        curl \
        wget \
        unzip \
        dnsutils \
        tar \
        systemd \
        ca-certificates \
        iproute2

    log_success "依赖安装完成"
}

# ==========================================
# 创建用户和目录
# ==========================================

setup_user_and_dirs() {

    mkdir -p "$MOSDNS_CONFIG_DIR"
    mkdir -p "$MOSDNS_LOG_DIR"

    if ! id "$MOSDNS_USER" &>/dev/null; then
        useradd -r -s /usr/sbin/nologin "$MOSDNS_USER"
    fi

    chown -R root:root "$MOSDNS_CONFIG_DIR"
    chown -R root:root "$MOSDNS_LOG_DIR"

    chmod 755 "$MOSDNS_CONFIG_DIR"
    chmod 755 "$MOSDNS_LOG_DIR"
}

# ==========================================
# 下载并安装
# ==========================================

install_mosdns_x() {

    local version=$1
    local arch
    arch=$(get_architecture)

    [[ "$arch" == "unsupported" ]] && {
        log_error "不支持当前架构"
        exit 1
    }

    local url="https://github.com/${GITHUB_REPO}/releases/download/${version}/mosdns-linux-${arch}.zip"

    local temp_dir
    temp_dir=$(mktemp -d)

    cd "$temp_dir"

    log_info "下载 Mosdns-x ${version}..."

    wget -q --show-progress -O mosdns.zip "$url"

    unzip -q mosdns.zip

    install -m 755 mosdns "$MOSDNS_BINARY"

    rm -rf "$temp_dir"

    log_success "安装完成"
}

# ==========================================
# 配置文件
# ==========================================

create_config() {

cat > "$MOSDNS_CONFIG_FILE" << 'EOF'
log:
  level: info
  file: /var/log/mosdns-x/mosdns-x.log

plugins:
  - tag: cache
    type: cache
    args:
      size: 1024
      lazy_cache_ttl: 1800

  - tag: forward_all
    type: fast_forward
    args:
      upstream:
        - addr: "udp://223.5.5.5"
        - addr: "tls://dns.alidns.com"

        - addr: "udp://119.29.29.29"
        - addr: "tls://dot.pub"

        - addr: "udp://1.1.1.1"
        - addr: "tls://cloudflare-dns.com"

        - addr: "udp://8.8.8.8"
        - addr: "tls://dns.google"

  - tag: main
    type: sequence
    args:
      exec:
        - cache
        - forward_all

servers:
  - exec: main
    listeners:
      - addr: :53
        protocol: udp
      - addr: :53
        protocol: tcp
EOF

    chmod 644 "$MOSDNS_CONFIG_FILE"

    log_success "配置文件创建完成"
}

# ==========================================
# systemd 服务
# ==========================================

create_service() {

cat > "$MOSDNS_SERVICE_FILE" << EOF
[Unit]
Description=mosdns-x DNS Server
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=$MOSDNS_BINARY start --as-service -c $MOSDNS_CONFIG_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    log_success "服务创建完成"
}

# ==========================================
# logrotate
# ==========================================

create_logrotate() {

cat > "$MOSDNS_LOGROTATE_FILE" << EOF
$MOSDNS_LOG_FILE {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF

    log_success "日志轮转配置完成"
}

# ==========================================
# DNS 配置
# ==========================================

configure_dns() {

    if [[ -f /etc/resolv.conf && ! -f "$RESOLV_CONF_BACKUP" ]]; then
        cp /etc/resolv.conf "$RESOLV_CONF_BACKUP"
    fi

    chattr -i /etc/resolv.conf 2>/dev/null || true

    cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
EOF

    chattr +i /etc/resolv.conf 2>/dev/null || true

    log_success "系统 DNS 已设置为 127.0.0.1"
}

restore_dns() {

    chattr -i /etc/resolv.conf 2>/dev/null || true

    if [[ -f "$RESOLV_CONF_BACKUP" ]]; then
        cp "$RESOLV_CONF_BACKUP" /etc/resolv.conf
    else
        cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
    fi

    log_success "DNS 已恢复"
}

# ==========================================
# 服务管理
# ==========================================

start_service() {
    systemctl enable mosdns >/dev/null 2>&1
    systemctl restart mosdns
    log_success "服务已启动"
}

stop_service() {
    systemctl stop mosdns
    log_success "服务已停止"
}

restart_service() {
    systemctl restart mosdns
    log_success "服务已重启"
}

# ==========================================
# 安装
# ==========================================

install_all() {

    check_dependencies

    setup_user_and_dirs

    local version
    version=$(get_latest_version)

    install_mosdns_x "$version"

    create_config

    create_service

    create_logrotate

    start_service

    configure_dns

    log_success "Mosdns-x 安装完成"
}

# ==========================================
# 更新
# ==========================================

update_mosdns() {

    local latest
    latest=$(get_latest_version)

    log_info "更新到版本: $latest"

    systemctl stop mosdns || true

    install_mosdns_x "$latest"

    systemctl restart mosdns

    log_success "更新完成"
}

# ==========================================
# 卸载
# ==========================================

uninstall_mosdns() {

    systemctl stop mosdns 2>/dev/null || true
    systemctl disable mosdns 2>/dev/null || true

    restore_dns

    rm -f "$MOSDNS_BINARY"
    rm -f "$MOSDNS_SERVICE_FILE"
    rm -f "$MOSDNS_LOGROTATE_FILE"

    read -rp "是否删除配置文件？(y/N): " confirm

    if [[ $confirm =~ ^[Yy]$ ]]; then
        rm -rf "$MOSDNS_CONFIG_DIR"
        rm -rf "$MOSDNS_LOG_DIR"
    fi

    systemctl daemon-reload

    log_success "卸载完成"
}

# ==========================================
# 测试 DNS
# ==========================================

test_dns() {

    domains=(
        google.com
        github.com
        cloudflare.com
        baidu.com
    )

    for domain in "${domains[@]}"; do

        echo -ne "${CYAN}测试 ${domain} ... ${NC}"

        if nslookup "$domain" 127.0.0.1 >/dev/null 2>&1; then
            echo -e "${GREEN}成功${NC}"
        else
            echo -e "${RED}失败${NC}"
        fi
    done
}

# ==========================================
# 查看状态
# ==========================================

show_status() {

    clear

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}        Mosdns-x 状态信息${NC}"
    echo -e "${GREEN}========================================${NC}"

    echo -e "当前版本: ${CYAN}$(get_current_version)${NC}"

    echo -e "服务状态: ${CYAN}$(systemctl is-active mosdns 2>/dev/null || echo 未运行)${NC}"

    if ss -tuln | grep -q ":53 "; then
        echo -e "53端口状态: ${GREEN}监听中${NC}"
    else
        echo -e "53端口状态: ${RED}未监听${NC}"
    fi

    echo -e "配置文件: ${CYAN}$MOSDNS_CONFIG_FILE${NC}"

    echo -e "日志文件: ${CYAN}$MOSDNS_LOG_FILE${NC}"
}

# ==========================================
# 查看日志
# ==========================================

show_logs() {
    journalctl -u mosdns -n 30 --no-pager
}

# ==========================================
# 菜单
# ==========================================

menu() {

while true
do
    clear

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}        Mosdns-x 管理菜单${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} 1. 安装 Mosdns-x${NC}"
    echo -e "${GREEN} 2. 更新 Mosdns-x${NC}"
    echo -e "${GREEN} 3. 卸载 Mosdns-x${NC}"
    echo -e "${GREEN} 4. 启动服务${NC}"
    echo -e "${GREEN} 5. 停止服务${NC}"
    echo -e "${GREEN} 6. 重启服务${NC}"
    echo -e "${GREEN} 7. 查看状态${NC}"
    echo -e "${GREEN} 8. 查看日志${NC}"
    echo -e "${GREEN} 9. 测试 DNS${NC}"
    echo -e "${GREEN}10. 恢复系统 DNS${NC}"
    echo -e "${GREEN} 0. 退出${NC}"
    echo -ne "${GREEN}请输入选项: ${NC}"
    read -r choice

    case $choice in
        1)
            install_all
            pause
            ;;
        2)
            update_mosdns
            pause
            ;;
        3)
            uninstall_mosdns
            pause
            ;;
        4)
            start_service
            pause
            ;;
        5)
            stop_service
            pause
            ;;
        6)
            restart_service
            pause
            ;;
        7)
            show_status
            pause
            ;;
        8)
            show_logs
            pause
            ;;
        9)
            test_dns
            pause
            ;;
        10)
            restore_dns
            pause
            ;;
        0)
            clear
            exit 0
            ;;
        *)
            log_error "无效选项"
            sleep 1
            ;;
    esac

done
}
# ==========================================
# 主函数
# ==========================================

main() {

    check_root || exit 1

    if [[ $# -eq 0 ]]; then
        menu
        return
    fi

    case "$1" in
        install)
            install_all
            ;;
        update)
            update_mosdns
            ;;
        uninstall)
            uninstall_mosdns
            ;;
        start)
            start_service
            ;;
        stop)
            stop_service
            ;;
        restart)
            restart_service
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs
            ;;
        test)
            test_dns
            ;;
        *)
            menu
            ;;
    esac
}

main "$@"
