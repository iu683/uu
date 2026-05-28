#!/bin/bash
set -euo pipefail

# =========================================================
# anytls 安装/卸载管理脚本 (UI 增强安全版)
# 功能：安装 anytls、修改配置、管理服务及查看状态
# =========================================================

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ================== 基础变量 ==================
SCRIPT_VERSION="1.0"
SERVICE_NAME="anytls"
BINARY_NAME="anytls-server"
BINARY_DIR="/usr/local/bin"
BINARY_PATH="${BINARY_DIR}/${BINARY_NAME}"

ANYTLS_DIR="/etc/anytls"
ANYTLS_CONFIG="${ANYTLS_DIR}/config.env" # 采用环境变量文件存储配置
ANYTLS_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"
LOG_FILE="/var/log/anytls-manager.log"
RUN_USER="anytls"

TMP_DIR=$(mktemp -d -t anytls.XXXXXX)

# ================== 检查 Root 权限 ==================
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[错误] 必须使用 root 或 sudo 运行！${RESET}"
    exit 1
fi

# ================== 资源清理 ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# ================== 日志与暂停 ==================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

pause() {
    read -n 1 -s -r -p "按任意键返回菜单..."
    echo
}

# ================== 创建专用系统用户 ==================
create_user() {
    id -u "$RUN_USER" &>/dev/null || \
        useradd -r -s /usr/sbin/nologin "$RUN_USER"
}

# ================== 获取公网 IP ==================
get_public_ip() {
    local ip
    for cmd in "curl -4fsSL --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6fsSL --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "[$ip]" && return
        done
    done
    echo "无法获取公网IP"
}

# ================== 检查依赖 ==================
check_deps() {
    echo -e "${GREEN}[信息] 检查系统依赖...${RESET}"
    install_pkg() {
        if command -v apt >/dev/null 2>&1; then
            apt update -y
            apt install -y "$@"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "$@"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "$@"
        fi
    }
    command -v curl >/dev/null 2>&1 || install_pkg curl
    command -v wget >/dev/null 2>&1 || install_pkg wget
    command -v unzip >/dev/null 2>&1 || install_pkg unzip
    command -v ss >/dev/null 2>&1 || {
        if command -v apt >/dev/null 2>&1; then install_pkg iproute2; else install_pkg iproute; fi
    }
    echo -e "${GREEN}[完成] 依赖检查完成${RESET}"
}

# ================== 检查端口占用 ==================
check_port() {
    if ss -tulnH "( sport = :$1 )" | grep -q .; then
        echo -e "${RED}端口 $1 已被占用${RESET}"
        return 1
    fi
}

# ================== 随机生成工具 ==================
random_port() {
    shuf -i 10000-65000 -n 1
}

random_password() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c16
}

# ================== 自动检测架构 ==================
detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *) echo -e "${RED}不支持的架构: $(uname -m)${RESET}"; exit 1 ;;
    esac
}

# ================== 写入本地环境配置 ==================
write_config() {
    local port="$1"
    local password="$2"
    mkdir -p "$ANYTLS_DIR"
    
    cat > "$ANYTLS_CONFIG" <<EOF
ANYTLS_PORT=$port
ANYTLS_PASSWORD=$password
EOF
    chmod 600 "$ANYTLS_CONFIG"
    chown -R ${RUN_USER}:${RUN_USER} "$ANYTLS_DIR"
}

# ================== 输出节点链接 ==================
output_node_links() {
    local port="$1"
    local password="$2"
    local ip
    ip=$(get_public_ip)
    local hostname
    hostname=$(hostname -s | sed 's/ /_/g')

    echo -e "${GREEN}====== Anytls 配置信息 ======${RESET}"
    echo -e "${YELLOW} IP地址   : ${ip}${RESET}"
    echo -e "${YELLOW} 端口     : ${port}${RESET}"
    echo -e "${YELLOW} 密码     : ${password}${RESET}"
    echo -e "${YELLOW}---------------------------------${RESET}"
    echo -e "${YELLOW}📄 V6VPS 请自行替换 IP 地址为 V6 ★${RESET}"
    echo -e "${YELLOW}[信息] V2rayN 链接：${RESET}"
    echo -e "${CYAN}anytls://$password@$ip:$port/?insecure=1#$hostname${RESET}"
    echo -e "${YELLOW}[信息] Surge 配置：${RESET}"
    echo -e "${CYAN}$hostname = anytls, $ip, $port, password=$password, tfo=true, skip-cert-verify=true, reuse=false${RESET}"
    echo -e "${YELLOW}---------------------------------${RESET}"
}

# ================== 安装 AnyTLS ==================
install_ss() {
    echo -e "${GREEN}[信息] 开始安装 AnyTLS...${RESET}"
    check_deps
    create_user
    mkdir -p "$ANYTLS_DIR"

    # 下载与解压
    local arch
    arch=$(detect_arch)
    local version="0.0.12" # 继承原版本
    local download_url="https://github.com/anytls/anytls-go/releases/download/v${version}/anytls_${version}_linux_${arch}.zip"
    
    cd "$TMP_DIR"
    wget "$download_url" -O "anytls.zip" || { echo -e "${RED}下载失败！${RESET}"; return; }
    unzip -o "anytls.zip" -d "$TMP_DIR"
    install -m 755 "$BINARY_NAME" "$BINARY_PATH"
    echo "$version" > "${ANYTLS_DIR}/version.txt"

    # 配置交互
    local port
    local input_port
    while true; do
        read -p "请输入监听端口 (默认:随机生成): " input_port
        port=${input_port:-$(random_port)}
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            check_port "$port" || continue
            break
        else
            echo -e "${RED}端口无效${RESET}"
        fi
    done

    local password
    local input_password
    read -p "请输入密码 (默认:随机生成): " input_password
    password=${input_password:-$(random_password)}

    write_config "$port" "$password"

    # ===== 配置具有安全沙盒的 Systemd 服务 =====
    cat > "$ANYTLS_SERVICE" <<EOF
[Unit]
Description=anytls Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
EnvironmentFile=${ANYTLS_CONFIG}
ExecStart=${BINARY_PATH} -l :\${ANYTLS_PORT} -p \${ANYTLS_PASSWORD}
Restart=always
RestartSec=3

# 安全沙盒权限赋予
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"

    echo -e "${GREEN}[完成] AnyTLS 已安装并启动${RESET}"
    output_node_links "$port" "$password"
    log "AnyTLS 已成功安装"
}

# ================== 修改 AnyTLS 配置 ==================
modify_ss() {
    echo -e "${GREEN}[信息] 开始修改 AnyTLS 配置...${RESET}"
    if [[ ! -f "$ANYTLS_CONFIG" ]]; then
        echo -e "${RED}配置文件不存在${RESET}"
        return
    fi

    # 载入当前配置
    source "$ANYTLS_CONFIG"
    local old_port=$ANYTLS_PORT
    local old_password=$ANYTLS_PASSWORD

    echo -e "${YELLOW}当前端口 : ${old_port}${RESET}"
    echo -e "${YELLOW}当前密码 : ${old_password}${RESET}"
    echo

    # 1. 端口修改
    local port
    local input_port
    while true; do
        read -p "请输入新端口 [当前:${old_port}]: " input_port
        port=${input_port:-$old_port}
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            if [[ "$port" != "$old_port" ]]; then
                check_port "$port" || continue
            fi
            break
        else
            echo -e "${RED}端口无效${RESET}"
        fi
    done

    # 2. 密码修改
    echo -e "\n1. 保持当前密码"
    echo "2. 手动输入密码"
    echo "3. 自动生成密码"
    local pwd_mode
    read -p "请选择密码模式 [默认:1]: " pwd_mode
    pwd_mode=${pwd_mode:-1}

    local password
    case $pwd_mode in
        2)
            read -p "请输入新密码: " password
            [[ -z "$password" ]] && password=$old_password
            ;;
        3)
            password=$(random_password)
            echo -e "${GREEN}已生成新密码${RESET}"
            ;;
        *)
            password=$old_password
            ;;
    esac

    # 备份并写入新配置
    cp "$ANYTLS_CONFIG" "${ANYTLS_CONFIG}.bak.$(date +%s)"
    write_config "$port" "$password"

    systemctl restart "$SERVICE_NAME"
    echo -e "${GREEN}[完成] 配置修改成功并已重启服务${RESET}\n"
    output_node_links "$port" "$password"
    log "AnyTLS 配置已修改"
}

# ================== 卸载 AnyTLS ==================
uninstall_ss() {
    echo -e "${RED}[警告] 正在卸载 AnyTLS...${RESET}"
    systemctl stop "$SERVICE_NAME" || true
    systemctl disable "$SERVICE_NAME" || true
    rm -f "$ANYTLS_SERVICE"
    rm -rf "$ANYTLS_DIR"
    rm -f "$BINARY_PATH"
    systemctl daemon-reload
    echo -e "${GREEN}[完成] AnyTLS 已彻底卸载${RESET}"
    log "AnyTLS 已卸载"
}

# ================== UI 菜单面板 ==================
show_menu() {
    clear
    # 运行状态判定
    local status
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        status="${GREEN}● 运行中${RESET}"
    else
        status="${RED}● 未运行${RESET}"
    fi

    # 版本读取
    local version_show="未安装"
    if [[ -f "${ANYTLS_DIR}/version.txt" ]]; then
        version_show="v$(cat "${ANYTLS_DIR}/version.txt")"
    fi

    # 端口读取
    local port_show="-"
    if [[ -f "$ANYTLS_CONFIG" ]]; then
        source "$ANYTLS_CONFIG"
        port_show=$ANYTLS_PORT
    fi

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}       AnyTLS 管理面板          ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "状态   : $status"
    echo -e "版本   : ${YELLOW}${version_show}${RESET}"
    echo -e "端口   : ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 AnyTLS${RESET}"
    echo -e "${GREEN}2. 卸载 AnyTLS${RESET}"
    echo -e "${GREEN}3. 修改配置${RESET}"
    echo -e "${GREEN}4. 启动 AnyTLS${RESET}"
    echo -e "${GREEN}5. 停止 AnyTLS${RESET}"
    echo -e "${GREEN}6. 重启 AnyTLS${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# ================== 主循环 ==================
while true; do
    show_menu
    # 规避严格模式下的 read 空输入报错，暂闭 -e
    set +e
    read -r -p $'\033[32m请输入选项: \033[0m' choice
    set -e
    
    case $choice in
        1)
            install_ss
            pause
            ;;
        2)
            uninstall_ss
            pause
            ;;
        3)
            modify_ss
            pause
            ;;
        4)
            systemctl start "$SERVICE_NAME"
            echo -e "${GREEN}[完成] AnyTLS 已启动${RESET}"
            log "AnyTLS 手动启动"
            pause
            ;;
        5)
            systemctl stop "$SERVICE_NAME"
            echo -e "${GREEN}[完成] AnyTLS 已停止${RESET}"
            log "AnyTLS 手动停止"
            pause
            ;;
        6)
            systemctl restart "$SERVICE_NAME"
            echo -e "${GREEN}[完成] AnyTLS 已重启${RESET}"
            log "AnyTLS 手动重启"
            pause
            ;;
        7)
            echo -e "${YELLOW}--- 最近 50 行日志 (按 q 退出) ---${RESET}"
            journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
            pause
            ;;
        8)
            if [[ -f "$ANYTLS_CONFIG" ]]; then
                source "$ANYTLS_CONFIG"
                output_node_links "$ANYTLS_PORT" "$ANYTLS_PASSWORD"
            else
                echo -e "${RED}未检测到已安装的配置${RESET}"
            fi
            pause
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效输入${RESET}"
            pause
            ;;
    esac
done
