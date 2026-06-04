#!/bin/bash

# Mosdns-x Alpine 专属自动化管理脚本
# 功能：安装、更新、配置、OpenRC 守护进程管理

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 
RESET='\033[0m'

# 配置变量
MOSDNS_VERSION=""
MOSDNS_BINARY="/usr/local/bin/mosdns-x"
MOSDNS_CONFIG_DIR="/etc/mosdns-x"
MOSDNS_CONFIG_FILE="/etc/mosdns-x/config.yaml"
MOSDNS_LOG_DIR="/var/log/mosdns-x"
MOSDNS_LOG_FILE="/var/log/mosdns-x/mosdns-x.log"
MOSDNS_SERVICE_FILE="/etc/init.d/mosdns"
MOSDNS_LOGROTATE_FILE="/etc/logrotate.d/mosdns-x"
MOSDNS_USER="mosdns"
MOSDNS_GROUP="mosdns"
RESOLV_CONF_BACKUP="/etc/resolv.conf.mosdns-backup"

# GitHub 配置
GITHUB_REPO="pmkol/mosdns-x"
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
GITHUB_RELEASES_URL="https://github.com/${GITHUB_REPO}/releases"

# 日志函数
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

# 检查系统架构
get_architecture() {
    local arch=$(uname -m)
    case $arch in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l) echo "arm" ;;
        *) echo "unsupported" ;;
    esac
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        log_error "请使用: sudo $0 $@"
        exit 1
    fi
}

# 检查权限和端口可用性
check_permissions() {
    log_info "检查权限和端口可用性..."
    
    # Alpine 默认使用 busybox netstat 或 ss，这里兼容处理
    if ss -tuln 2>/dev/null | grep -q ":53 " || netstat -tuln 2>/dev/null | grep -q ":53 "; then
        log_warning "端口53已被占用！"
        log_warning "Mosdns-x需要端口53，请确保没有其他DNS服务运行"
        
        # 询问是否继续
        read -p "是否继续安装? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "安装已取消"
            exit 0
        fi
    fi
    
    log_success "权限检查完成"
}

# 检查系统依赖 (Alpine 专属修改)
check_dependencies() {
    log_info "检查 Alpine 系统依赖..."
    
    local missing_deps=()
    
    # 映射 Alpine 对应的软件包名 (dnsutils -> bind-tools)
    for cmd in curl wget unzip bind-tools logrotate; do
        if ! command -v $cmd &> /dev/null; then
            if [[ "$cmd" == "bind-tools" || "$cmd" == "nslookup" ]]; then
                missing_deps+=("bind-tools")
            else
                missing_deps+=($cmd)
            fi
        fi
    done
    
    # 确保 bash 自身和 openrc 工具可用
    if ! command -v rc-service &> /dev/null; then
        log_error "未检测到 OpenRC 环境，本脚本仅支持 Alpine Linux (OpenRC) 系统。"
        exit 1
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_info "安装 Alpine 缺失的依赖: ${missing_deps[*]}"
        apk update
        apk add ${missing_deps[@]}
    fi
    
    log_success "系统依赖检查完成"
}

# 获取最新版本
get_latest_version() {
    local version=$(curl -s "$GITHUB_API_URL" | grep -o '"tag_name": "[^"]*' | grep -o '[^"]*$' 2>/dev/null || echo "")
    
    if [[ -z "$version" ]]; then
        version=$(curl -s "$GITHUB_RELEASES_URL" | grep -o 'tag/[^"]*' | head -1 | cut -d'/' -f2 2>/dev/null || echo "")
    fi
    
    if [[ -z "$version" ]]; then
        version="v26.5.25"
    fi
    
    echo "$version"
}

# 检查当前版本
get_current_version() {
    if [[ -f "$MOSDNS_BINARY" ]]; then
        local ver_raw=$($MOSDNS_BINARY version 2>/dev/null || echo "")
        
        if [[ -z "$ver_raw" ]]; then
            echo "已安装 (无法获取版本)"
            return 0
        fi

        local build_time=$(echo "$ver_raw" | grep -oE 'build time: [0-9.]+' | awk '{print $3}')
        local clean_ver=$(echo "$ver_raw" | grep -oE 'version: v[0-9.]+' | awk '{print $2}')
        
        if [[ -z "$clean_ver" ]]; then
            clean_ver=$(echo "$ver_raw" | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
        fi
        
        if [[ "$clean_ver" == "v4.6.0" && -n "$build_time" ]]; then
            echo "v4.6.0 (${build_time})"
        elif [[ -n "$clean_ver" && "$clean_ver" != "v" ]]; then
            echo "$clean_ver"
        else
            echo "$ver_raw" | head -n 1 | cut -c1-20
        fi
    else
        echo "未安装"
    fi
}

# 下载并安装 Mosdns-x
install_mosdns_x() {
    local version=$1
    local arch=$(get_architecture)
    
    if [[ "$arch" == "unsupported" ]]; then
        log_error "不支持的架构: $(uname -m)"
        exit 1
    fi
    
    log_info "下载 Mosdns-x $version (架构: $arch)..."
    
    local download_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/mosdns-linux-${arch}.zip"
    local temp_dir=$(mktemp -d)
    local zip_file="$temp_dir/mosdns-linux-${arch}.zip"
    
    if ! wget -q --show-progress -O "$zip_file" "$download_url"; then
        log_error "下载失败: $download_url"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    log_info "解压并安装..."
    cd "$temp_dir"
    unzip -q "$zip_file"
    
    install -m 755 mosdns "$MOSDNS_BINARY"
    rm -rf "$temp_dir"
    
    log_success "Mosdns-x $version 安装完成"
}

# 创建用户和目录
setup_user_and_dirs() {
    log_info "创建用户和目录..."
    
    mkdir -p "$MOSDNS_CONFIG_DIR"
    mkdir -p "$MOSDNS_LOG_DIR"
    
    # Alpine 使用 shadow 包或 standard adduser
    if ! id "$MOSDNS_USER" &>/dev/null; then
        addgroup -S "$MOSDNS_GROUP" 2>/dev/null || true
        adduser -S -G "$MOSDNS_GROUP" -h "$MOSDNS_CONFIG_DIR" -s /sbin/nologin "$MOSDNS_USER"
        log_info "创建用户: $MOSDNS_USER"
    fi
    
    # 由于 Alpine 运行多以 root 权限监听53端口，默认优化权限归 root
    chown -R root:root "$MOSDNS_CONFIG_DIR"
    chown -R root:root "$MOSDNS_LOG_DIR"
    chmod 755 "$MOSDNS_CONFIG_DIR"
    chmod 755 "$MOSDNS_LOG_DIR"
    
    log_success "用户和目录设置完成"
}

# 创建配置文件
create_config() {
    log_info "创建配置文件..."
    
    cat > "$MOSDNS_CONFIG_FILE" << 'EOF'
# mosdns-x 并发查询（无分流）配置

log:
  level: info
  file: /var/log/mosdns-x/mosdns-x.log

plugins:
  # 缓存插件
  - tag: cache
    type: cache
    args:
      size: 1024
      lazy_cache_ttl: 1800

  # 并发上游：取最先返回的可用答案
  - tag: forward_all
    type: fast_forward
    args:
      upstream:
        # 阿里
        - addr: "udp://223.5.5.5"
        - addr: "tls://dns.alidns.com"

        # DNSPod / doh.pub
        - addr: "udp://119.29.29.29"
        - addr: "tls://dot.pub"

        # Cloudflare
        - addr: "udp://1.1.1.1"
        - addr: "tls://cloudflare-dns.com"

        # Google
        - addr: "udp://8.8.8.8"
        - addr: "tls://dns.google"

  # 主主流线：小缓存 → 并发优选
  - tag: main
    type: sequence
    args:
      exec:
        - cache
        - forward_all

# 监听（双栈 UDP/TCP 53）
servers:
  - exec: main
    listeners:
      - addr: :53
        protocol: udp
      - addr: :53
        protocol: tcp
EOF

    chown root:root "$MOSDNS_CONFIG_FILE"
    chmod 644 "$MOSDNS_CONFIG_FILE"
    
    log_success "配置文件创建完成"
}

# 创建 OpenRC 服务脚本 (Alpine 专属修改替换 systemd)
create_systemd_service() {
    log_info "创建 Alpine OpenRC 服务脚本..."
    
    cat > "$MOSDNS_SERVICE_FILE" << EOF
#!/sbin/openrc-run

description="Mosdns-x DNS forwarder"
supervisor="supervise-daemon"
command="$MOSDNS_BINARY"
command_args="start -d /usr/local/bin -c $MOSDNS_CONFIG_FILE"
# 默认使用 root 权限运行以监听 53 低位端口
command_user="root:root"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0755 -o root:root "$MOSDNS_LOG_DIR"
    checkpath -d -m 0755 -o root:root "$MOSDNS_CONFIG_DIR"
}
EOF

    chmod 755 "$MOSDNS_SERVICE_FILE"
    log_success "OpenRC 服务脚本创建完成"
}

# 创建日志轮转配置
create_logrotate() {
    log_info "创建日志轮转配置..."
    
    cat > "$MOSDNS_LOGROTATE_FILE" << EOF
$MOSDNS_LOG_FILE {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 644 root root
    postrotate
        rc-service mosdns restart > /dev/null 2>&1 || true
    endscript
}
EOF
    log_success "日志轮转配置创建完成"
}

# 配置系统DNS
configure_system_dns() {
    log_info "配置系统DNS..."
    
    if [[ -f "/etc/resolv.conf" && ! -f "$RESOLV_CONF_BACKUP" ]]; then
        cp /etc/resolv.conf "$RESOLV_CONF_BACKUP"
        log_info "已备份原始DNS配置到: $RESOLV_CONF_BACKUP"
    fi
    
    if grep -q "nameserver 127.0.0.1" /etc/resolv.conf 2>/dev/null; then
        log_info "系统DNS已配置为使用Mosdns-x"
        return 0
    fi
    
    # Alpine 默认没有 chattr 命令，如果需要锁定，先检查并尝试装 e2fsprogs-extra
    if ! command -v chattr &> /dev/null; then
        apk add --no-cache e2fsprogs-extra >/dev/null 2>&1 || true
    fi

    if [[ -f "/etc/resolv.conf" ]] && command -v chattr &> /dev/null; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi
    
    echo -e "nameserver 127.0.0.1\n" > /etc/resolv.conf
    
    echo
    if command -v chattr &> /dev/null; then
        log_warning "即将对 /etc/resolv.conf 设置 chattr +i 锁定保护。"
        log_warning "锁定后，其他网络服务（如 udhcpc）将无法修改此文件。"
        read -p "是否确认锁定以防止DNS被覆盖? (Y/n): " -n 1 -r
        echo
        if [[ -z "$REPLY" || $REPLY =~ ^[Yy]$ ]]; then
            chattr +i /etc/resolv.conf
            log_success "系统DNS已配置并锁定为 Mosdns-x (127.0.0.1)"
        else
            log_info "已跳过 chattr 锁定，DNS 已修改但可能在重启后被系统覆盖。"
        fi
    else
        log_warning "未找到 chattr 命令，跳过锁定保护。DNS 已修改但可能在重启或网络重连后被覆盖。"
    fi
}

# 恢复系统DNS
restore_system_dns() {
    log_info "恢复系统DNS配置..."
    
    if [[ -f "/etc/resolv.conf" ]] && command -v chattr &> /dev/null; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi
    
    if [[ -f "$RESOLV_CONF_BACKUP" ]]; then
        cp "$RESOLV_CONF_BACKUP" /etc/resolv.conf
        rm -f "$RESOLV_CONF_BACKUP"
        log_success "已恢复原始DNS配置"
    else
        cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
        log_success "已设置默认DNS配置"
    fi
}

# 启动并启用服务 (Alpine OpenRC 专属修改)
start_service() {
    log_info "启动并启用服务..."
    
    rc-service mosdns start
    rc-update add mosdns default
    
    sleep 2
    
    if rc-service mosdns status | grep -q "started"; then
        log_success "服务启动成功"
    else
        log_error "服务启动失败"
        exit 1
    fi
}

# 验证安装
verify_installation() {
    log_info "验证安装..."
    
    if [[ ! -f "$MOSDNS_BINARY" ]]; then
        log_error "二进制文件不存在: $MOSDNS_BINARY"
        return 1
    fi
    
    if [[ ! -f "$MOSDNS_CONFIG_FILE" ]]; then
        log_error "配置文件不存在: $MOSDNS_CONFIG_FILE"
        return 1
    fi
    
    if ! rc-service mosdns status | grep -q "started"; then
        log_error "服务未运行"
        return 1
    fi
    
    if ! (ss -tuln 2>/dev/null | grep -q ":53 " || netstat -tuln 2>/dev/null | grep -q ":53 "); then
        log_error "端口53未监听"
        return 1
    fi
    
    if ! nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
        log_error "DNS解析测试失败"
        return 1
    fi
    
    log_success "安装验证通过"
    return 0
}

# 修改配置文件的快捷函数
edit_config() {
    if [[ -f "$MOSDNS_CONFIG_FILE" ]]; then
        if command -v nano &> /dev/null; then
            nano "$MOSDNS_CONFIG_FILE"
        elif command -v vi &> /dev/null; then
            vi "$MOSDNS_CONFIG_FILE"
        else
            log_error "未找到编辑器 (nano/vi)，请手动编辑: $MOSDNS_CONFIG_FILE"
            return 1
        fi
        log_info "正在重启服务以使配置生效..."
        rc-service mosdns restart && log_success "配置已重载且服务已重启" || log_error "服务重启失败，请检查配置格式"
    else
        log_error "配置文件不存在，请先安装"
    fi
}

# 更新Mosdns-x (Alpine 专属修改)
update_mosdns_x() {
    local latest_version=$(get_latest_version)
    local current_version=$(get_current_version)
    
    if [[ "$current_version" == "未安装" ]]; then
        log_error "Mosdns-x 未安装，请先运行安装"
        exit 1
    fi
    
    if [[ "$current_version" == "$latest_version" ]]; then
        log_info "已是最新版本: $current_version"
        return 0
    fi
    
    log_info "更新 Mosdns-x: $current_version -> $latest_version"
    
    log_info "正在临时恢复系统公共 DNS 以确保下载期间网络畅通..."
    if [[ -f "/etc/resolv.conf" ]] && command -v chattr &> /dev/null; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi
    echo -e "nameserver 8.8.8.8\nameserver 1.1.1.1\n" > /etc/resolv.conf
    
    log_info "正在停止旧版服务..."
    rc-service mosdns stop || true
    
    install_mosdns_x "$latest_version"
    
    log_info "正在启动新版服务..."
    rc-service mosdns start
    
    log_info "正在重新配置系统 DNS 指向 Mosdns-x..."
    configure_system_dns
    
    log_success "更新完成"
}

# 卸载 Mosdns-x (Alpine 专属修改)
uninstall_mosdns_x() {
    log_info "卸载 Mosdns-x..."
    
    rc-service mosdns stop 2>/dev/null || true
    rc-update del mosdns default 2>/dev/null || true
    
    restore_system_dns
    
    rm -f "$MOSDNS_BINARY"
    rm -f "$MOSDNS_SERVICE_FILE"
    rm -f "$MOSDNS_LOGROTATE_FILE"
    
    read -p "是否删除配置目录和日志目录? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$MOSDNS_CONFIG_DIR"
        rm -rf "$MOSDNS_LOG_DIR"
        deluser "$MOSDNS_USER" 2>/dev/null || true
    fi
    
    log_success "卸载完成"
}

# 测试DNS解析
test_dns() {
    log_info "测试DNS解析..."
    local test_domains=("google.com" "baidu.com" "github.com" "cloudflare.com")
    
    for domain in "${test_domains[@]}"; do
        echo -n "测试 $domain: "
        if nslookup "$domain" 127.0.0.1 >/dev/null 2>&1; then
            echo -e "${GREEN}成功${NC}"
        else
            echo -e "${RED}失败${NC}"
        fi
    done
}

# 查看日志 (Alpine 专属修改，读取文本日志)
show_logs() {
    if [[ -f "$MOSDNS_LOG_FILE" ]]; then
        log_info "显示最近 30 行日志 (输入 Q 或 Ctrl+C 退出)..."
        tail -n 30 "$MOSDNS_LOG_FILE"
    else
        log_error "日志文件不存在: $MOSDNS_LOG_FILE"
    fi
}

main() {
    check_root
    
    while true; do
        local version=$(get_current_version)
        
        local status
        if rc-service mosdns status 2>/dev/null | grep -q "started"; then
            status="${GREEN}运行中${RESET}"
        else
            status="${RED}未运行${RESET}"
        fi
        
        local port_show
        if ss -tuln 2>/dev/null | grep -q ":53 " || netstat -tuln 2>/dev/null | grep -q ":53 "; then
            port_show="53 (已监听)"
        else
            port_show="无监听"
        fi

        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}        Mosdns-x  管理面板      ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}状态   :${RESET} $status"
        echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
        echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1. 安装 Mosdns-x${RESET}"
        echo -e "${GREEN} 2. 更新 Mosdns-x${RESET}"
        echo -e "${GREEN} 3. 卸载 Mosdns-x${RESET}"
        echo -e "${GREEN} 4. 修改配置${RESET}"
        echo -e "${GREEN} 5. 启动 Mosdns-x${RESET}"
        echo -e "${GREEN} 6. 停止 Mosdns-x${RESET}"
        echo -e "${GREEN} 7. 重启 Mosdns-x${RESET}"
        echo -e "${GREEN} 8. 查看日志${RESET}"
        echo -e "${GREEN} 9. 测试DNS解析${RESET}"
        echo -e "${GREEN}10. 还原系统DNS${RESET}"
        echo -e "${GREEN} 0. 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"
        
        read -p $'\e[32m请输入数字: \e[0m' num
        case "$num" in
            1)
                log_info "开始安装 Mosdns-x..."
                check_dependencies
                check_permissions
                setup_user_and_dirs
                local latest_version=$(get_latest_version)
                install_mosdns_x "$latest_version"
                create_config
                create_systemd_service
                create_logrotate
                start_service
                configure_system_dns
                verify_installation
                log_success "安装完成！"
                ;;
            2)
                update_mosdns_x
                ;;
            3)
                uninstall_mosdns_x
                ;;
            4)
                edit_config
                ;;
            5)
                rc-service mosdns start
                log_success "服务已启动"
                ;;
            6)
                rc-service mosdns stop
                log_success "服务已停止"
                ;;
            7)
                rc-service mosdns restart
                log_success "服务已重启"
                ;;
            8)
                show_logs
                ;;
            9)
                test_dns
                ;;
            10)
                restore_system_dns
                ;;
            0)
                exit 0
                ;;
            *)
                log_error "请输入正确的数字 [0-10]"
                ;;
        esac
        echo
        read -p "按回车键返回主菜单..."
        clear
    done
}

# 运行主函数
main "$@"
