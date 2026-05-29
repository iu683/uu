#!/bin/bash
set -euo pipefail

# =========================================================
# AnyTLS 一键部署脚本 (Alpine Linux 专属版)
# =========================================================

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# ================== 基础变量 ==================
SCRIPT_VERSION="1.0"
SERVICE_NAME="anytls"
BINARY_NAME="anytls-server"
BINARY_DIR="/usr/local/bin"
BINARY_PATH="${BINARY_DIR}/${BINARY_NAME}"

ANYTLS_DIR="/etc/anytls"
ANYTLS_CONFIG="${ANYTLS_DIR}/config.env"
ANYTLS_SERVICE="/etc/init.d/${SERVICE_NAME}"
LOG_FILE="/var/log/anytls-manager.log"
RUN_USER="anytls"

TMP_DIR=$(mktemp -d -t anytls.XXXXXX)

# ================== Root 检查 ==================
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[错误] 请使用 root 运行${RESET}"
    exit 1
fi

# ================== 清理 ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# ================== 日志 ==================
log() {
    echo "$(date '+%F %T') - $1" >> "$LOG_FILE"
}

pause() {
    read -n1 -s -r -p "按任意键返回菜单..." < /dev/tty
    echo
}

# ================== 用户 ==================
create_user() {
    id "$RUN_USER" &>/dev/null || \
        adduser -S -D -H -s /sbin/nologin "$RUN_USER"
}

# ================== 公网IP ==================
get_public_ip() {
    local ip
    for cmd in "curl -4fsSL --max-time 5" "wget -4qO- --timeout=5"; do
        for url in \
            "https://api.ipify.org" \
            "https://ip.sb" \
            "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && {
                echo "$ip"
                return
            }
        done
    done

    for cmd in "curl -6fsSL --max-time 5" "wget -6qO- --timeout=5"; do
        for url in \
            "https://api64.ipify.org" \
            "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && {
                echo "[$ip]"
                return
            }
        done
    done

    echo "无法获取公网IP"
}

# ================== 依赖 ==================
check_deps() {
    # Alpine 换源与更新依赖
    apk add --no-cache curl wget unzip iproute2 bash
}

# ================== 端口 ==================
check_port() {
    if ss -tulnH "( sport = :$1 )" | grep -q . || return 0; then
        echo -e "${RED}端口 $1 已占用${RESET}"
        return 1
    fi
}

random_port() {
    # Alpine BusyBox 没有 shuf，用 awk 替代
    awk 'BEGIN{srand(); print int(rand()*(65000-10000+1))+10000}'
}

random_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c16 || true
}

# ================== 架构 ==================
detect_arch() {
    case "$(uname -m)" in
        x86_64) echo amd64 ;;
        aarch64) echo arm64 ;;
        armv7l) echo armv7 ;;
        *)
            echo -e "${RED}不支持架构 $(uname -m)${RESET}"
            exit 1
            ;;
    esac
}

# ================== 自动获取 GitHub 最新版本号 ==================
get_latest_version() {
    local latest_release
    latest_release=$(curl -fsSL --max-time 5 "https://api.github.com/repos/anytls/anytls-go/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
    if [[ -z "$latest_release" ]]; then
        latest_release=$(curl -fsSLI --max-time 5 "https://github.com/anytls/anytls-go/releases/latest" 2>/dev/null | grep -i 'location:' | sed -E 's/.*\/v?([^/\r\n]+).*/\1/')
    fi
    echo "${latest_release:-0.0.12}"
}

# ================== 配置 ==================
write_config() {
    mkdir -p "$ANYTLS_DIR"
    cat > "$ANYTLS_CONFIG" <<EOF
ANYTLS_PORT=$1
ANYTLS_PASSWORD=$2
EOF
    chmod 600 "$ANYTLS_CONFIG"
    chown -R ${RUN_USER}:${RUN_USER} "$ANYTLS_DIR"
}

# ================== 输出节点 ==================
output_node_links() {
    local ip
    ip=$(get_public_ip)

    local hostname
    hostname=$(hostname | cut -d. -f1 | sed 's/ /_/g')

    echo -e "${GREEN}====== AnyTLS 节点信息 ======${RESET}"
    echo -e "${YELLOW}IP      : ${ip}${RESET}"
    echo -e "${YELLOW}端口    : $1${RESET}"
    echo -e "${YELLOW}密码    : $2${RESET}"
    echo -e "${GREEN}---------------------------${RESET}"
    echo -e "${YELLOW}📄 V6VPS 请自行替换 IP 地址为 V6 ★${RESET}"
    echo -e "${YELLOW}[信息] V2rayN 链接：${RESET}"
    echo -e "${CYAN}anytls://$2@$ip:$1/?insecure=1#$hostname-Anytls${RESET}"
    echo -e "${YELLOW}[信息] Surge 配置：${RESET}"
    echo -e "${CYAN}$hostname-Anytls = anytls, $ip, $1, password=$2, tfo=true, skip-cert-verify=true, reuse=false${RESET}"
    echo -e "${YELLOW}---------------------------------${RESET}"
}

# ================== 安装 ==================
install_ss() {
    echo -e "${GREEN}[信息] 开始安装 AnyTLS...${RESET}"

    check_deps
    create_user
    mkdir -p "$ANYTLS_DIR"

    local arch
    arch=$(detect_arch)

    echo -e "${GREEN}[信息] 正在获取 AnyTLS 最新版本...${RESET}"
    local version
    version=$(get_latest_version)
    echo -e "${GREEN}[信息] 检测到最新版本为: v${version}${RESET}"

    local url="https://github.com/anytls/anytls-go/releases/download/v${version}/anytls_${version}_linux_${arch}.zip"

    cd "$TMP_DIR"
    wget "$url" -O anytls.zip
    unzip -o anytls.zip -d "$TMP_DIR"

    local real_binary_path
    real_binary_path=$(find "$TMP_DIR" -type f -name "$BINARY_NAME" | head -n 1)
    if [[ -z "$real_binary_path" ]]; then
        echo -e "${RED}[错误] 压缩包内未找到可执行程序 ${BINARY_NAME}${RESET}"
        return 1
    fi

    install -m755 "$real_binary_path" "$BINARY_PATH"
    echo "$version" > "${ANYTLS_DIR}/version.txt"

    local port input_port
    while true; do
        read -p "请输入监听端口 (默认随机): " input_port < /dev/tty
        port=${input_port:-$(random_port)}

        if [[ "$port" =~ ^[0-9]+$ ]] &&
            [ "$port" -ge 1 ] &&
            [ "$port" -le 65535 ]; then

            check_port "$port" || continue
            break
        fi

        echo -e "${RED}端口无效${RESET}"
    done

    local input_password password
    read -p "请输入密码 (默认随机): " input_password < /dev/tty
    password=${input_password:-$(random_password)}

    write_config "$port" "$password"

    # 生成 Alpine OpenRC 服务脚本
    cat > "$ANYTLS_SERVICE" <<'EOF'
#!/sbin/openrc-run

description="AnyTLS Service"
cfgfile="/etc/anytls/config.env"
command="/usr/local/bin/anytls-server"

depend() {
    need net
    after firewall
}

start_pre() {
    if [ ! -f "$cfgfile" ]; then
        eerror "Configuration file $cfgfile missing!"
        return 1
    fi
    . "$cfgfile"
    command_args="-l :${ANYTLS_PORT} -p ${ANYTLS_PASSWORD}"
    
    # OpenRC 运行参数与权限控制
    command_background="yes"
    pidfile="/run/${RC_SVCNAME}.pid"
    command_user="anytls:anytls"
    
    # 允许非 root 绑定低端口 (Alpine 适用)
    capabilities="cap_net_bind_service=ep"
}
EOF
    chmod +x "$ANYTLS_SERVICE"

    rc-update add "$SERVICE_NAME" default
    rc-service "$SERVICE_NAME" restart

    if ! rc-service "$SERVICE_NAME" status | grep -q "started"; then
        echo -e "${RED}AnyTLS 启动失败${RESET}"
        return 1
    fi

    echo -e "${GREEN}[完成] AnyTLS 安装成功${RESET}"
    output_node_links "$port" "$password"
    log "安装成功"
}

# ================== 更新 AnyTLS 主程序 ==================
update_ss() {
    if [[ ! -f "${ANYTLS_DIR}/version.txt" || ! -f "$ANYTLS_CONFIG" ]]; then
        echo -e "${RED}[错误] 未检测到已安装的 AnyTLS 服务，请先执行安装。${RESET}"
        return 1
    fi

    local current_version
    current_version=$(cat "${ANYTLS_DIR}/version.txt")
    
    echo -e "${GREEN}[信息] 正在获取最新版本...${RESET}"
    local latest_version
    latest_version=$(get_latest_version)

    echo -e "${GREEN}当前版本: v${current_version}${RESET}"
    echo -e "${GREEN}最新版本: v${latest_version}${RESET}"

    if [[ "$current_version" == "$latest_version" ]]; then
        read -p "当前已是最新版本，是否仍要重新下载覆盖？[y/N]: " remode < /dev/tty
        if [[ ! "$remode" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}已取消更新。${RESET}"
            return 0
        fi
    fi

    echo -e "${GREEN}[信息] 开始升级主程序到 v${latest_version}...${RESET}"
    local arch
    arch=$(detect_arch)
    local url="https://github.com/anytls/anytls-go/releases/download/v${latest_version}/anytls_${latest_version}_linux_${arch}.zip"

    cd "$TMP_DIR"
    wget "$url" -O anytls.zip || { echo -e "${RED}下载失败${RESET}"; return 1; }
    unzip -o anytls.zip -d "$TMP_DIR"

    local real_binary_path
    real_binary_path=$(find "$TMP_DIR" -type f -name "$BINARY_NAME" | head -n 1)
    if [[ -z "$real_binary_path" ]]; then
        echo -e "${RED}[错误] 压缩包内未找到可执行程序 ${BINARY_NAME}${RESET}"
        return 1
    fi

    rc-service "$SERVICE_NAME" stop || true
    install -m755 "$real_binary_path" "$BINARY_PATH"
    echo "$latest_version" > "${ANYTLS_DIR}/version.txt"
    rc-service "$SERVICE_NAME" start

    if rc-service "$SERVICE_NAME" status | grep -q "started"; then
        echo -e "${GREEN}[完成] AnyTLS 成功升级至 v${latest_version}!${RESET}"
        log "升级成功至 v${latest_version}"
    else
        echo -e "${RED}[错误] 升级后服务启动失败，请检查日志。${RESET}"
    fi
}

# ================== 修改配置 ==================
modify_ss() {
    [[ -f "$ANYTLS_CONFIG" ]] || {
        echo -e "${RED}配置不存在${RESET}"
        return
    }

    # 读取旧配置
    ANYTLS_PORT=$(grep 'ANYTLS_PORT=' "$ANYTLS_CONFIG" | cut -d= -f2)
    ANYTLS_PASSWORD=$(grep 'ANYTLS_PASSWORD=' "$ANYTLS_CONFIG" | cut -d= -f2)

    echo "当前端口: $ANYTLS_PORT"
    echo "当前密码: $ANYTLS_PASSWORD"

    local port password

    read -p "新端口 [当前:${ANYTLS_PORT}]: " port < /dev/tty
    port=${port:-$ANYTLS_PORT}

    if [[ "$port" != "$ANYTLS_PORT" ]]; then
        check_port "$port" || return 1
    fi

    read -p "新密码 [默认保持]: " password < /dev/tty
    password=${password:-$ANYTLS_PASSWORD}

    write_config "$port" "$password"
    rc-service "$SERVICE_NAME" restart

    echo -e "${GREEN}修改成功${RESET}"
    output_node_links "$port" "$password"
}

# ================== 卸载 ==================
uninstall_ss() {
    rc-service "$SERVICE_NAME" stop || true
    rc-update del "$SERVICE_NAME" default || true

    rm -f "$ANYTLS_SERVICE"
    rm -f "$BINARY_PATH"
    rm -rf "$ANYTLS_DIR"

    # Alpine 删除用户
    deluser "$RUN_USER" &>/dev/null || true

    echo -e "${GREEN}卸载完成${RESET}"
}

# ================== 菜单 ==================
show_menu() {
    clear
    local status
    if rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q "started"; then
        status="${GREEN}●运行中${RESET}"
    else
        status="${RED}●未运行${RESET}"
    fi

    local version="未安装"
    [[ -f "${ANYTLS_DIR}/version.txt" ]] &&
        version="v$(cat "${ANYTLS_DIR}/version.txt")"

    local port="-"
    [[ -f "$ANYTLS_CONFIG" ]] &&
        port=$(grep 'ANYTLS_PORT=' "$ANYTLS_CONFIG" | cut -d= -f2)

    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}    AnyTLS 管理面板 (Alpine)   ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1. 安装 AnyTLS${RESET}"
    echo -e "${GREEN}2. 更新 AnyTLS${RESET}"
    echo -e "${GREEN}3. 卸载 AnyTLS${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 AnyTLS${RESET}"
    echo -e "${GREEN}6. 停止 AnyTLS${RESET}"
    echo -e "${GREEN}7. 重启 AnyTLS${RESET}"
    echo -e "${GREEN}8. 查看运行状态${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
}

# ================== 主循环 ==================
while true; do
    show_menu

    set +e
    read -r -p $'\033[32m请输入选项: \033[0m' choice < /dev/tty
    set -e

    case $choice in
        1) install_ss; pause ;;
        2) update_ss; pause ;;
        3) uninstall_ss; pause ;;
        4) modify_ss; pause ;;
        5) rc-service "$SERVICE_NAME" start; echo -e "${GREEN}[完成] AnyTLS 已启动${RESET}"; pause ;;
        6) rc-service "$SERVICE_NAME" stop; echo -e "${GREEN}[完成] AnyTLS 已停止${RESET}"; pause ;;
        7) rc-service "$SERVICE_NAME" restart; echo -e "${GREEN}[完成] AnyTLS 已重启${RESET}"; pause ;;
        8) rc-service "$SERVICE_NAME" status; pause ;;
        9)
            [[ -f "$ANYTLS_CONFIG" ]] && {
                local p_port p_pass
                p_port=$(grep 'ANYTLS_PORT=' "$ANYTLS_CONFIG" | cut -d= -f2)
                p_pass=$(grep 'ANYTLS_PASSWORD=' "$ANYTLS_CONFIG" | cut -d= -f2)
                output_node_links "$p_port" "$p_pass"
            }
            pause
            ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}无效输入${RESET}"
            pause
            ;;
    esac
done
