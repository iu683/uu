#!/bin/sh
# 注意：Alpine 默认使用 sh，这里使用完全兼容 Alpine 的标准 shell 语法
set -e

# ================== 颜色与输出函数 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

_ok()   { echo -e "${GREEN}[OK] $1${RESET}"; }
_warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
_err()  { echo -e "${RED}[ERROR] $1${RESET}"; return 1; }
_info() { echo -e "${GREEN}[INFO] $1${RESET}"; }

# ================== 变量 ==================
SNELL_DIR="/etc/snell"
SNELL_CONFIG="$SNELL_DIR/snell-server.conf"
SNELL_RC_SERVICE="/etc/init.d/snell"
LOG_FILE="/var/log/snell_manager.log"
SNELL_DEFAULT_VERSION="5.0.1"

# ================== 工具函数 ==================
create_user() {
    id -u snell >/dev/null 2>&1 || adduser -S -D -H -s /sbin/nologin snell 2>/dev/null || true
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [ -n "$ip" ] && echo "$ip" && return
        done
    done
    echo "127.0.0.1"
}

check_port() {
    if netstat -tln | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

random_key() {
    cat /dev/urandom | tr -dc A-Za-z0-9 | head -c 16
}

random_port() {
    awk 'BEGIN{srand();print int(rand()*(65000-2000+1))+2000}'
}

get_system_dns() {
    grep -E "^nameserver" /etc/resolv.conf | awk '{print $2}' | paste -sd "," -
}

pause() {
    echo -n "按任意键返回菜单..."
    read -r -n 1 arg
    echo
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

_map_arch() {
    local raw_arch=$(uname -m)
    case "$raw_arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armhf) echo "armv7l" ;;
        *) return 1 ;;
    esac
}

_get_snell_latest_version() {
    local latest_version
    latest_version=$(curl -sL -A "Mozilla/5.0" "https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell" | grep -oE 'v5\.[0-9]+\.[0-9]+' | head -n 1 2>/dev/null || echo "")
    if [ -n "$latest_version" ]; then
        echo "${latest_version#v}"
    else
        echo "$SNELL_DEFAULT_VERSION"
    fi
}

# ================== 配置 Snell v5 ==================
configure_snell() {
    mkdir -p "$SNELL_DIR"
    echo -e "${GREEN}[信息] 开始配置 Snell v5...${RESET}"

    echo -n "请输入端口 (默认: 随机生成): "
    read -r input_port
    port=${input_port:-$(random_port)}
    check_port "$port" || return 1

    echo -n "请输入 Snell 密钥 (默认: 随机生成): "
    read -r key
    key=${key:-$(random_key)}

    echo -e "${YELLOW}配置 OBFS：[注意] 无特殊作用不建议启用${RESET}"
    echo "1. TLS   2. HTTP   3. 关闭"
    echo -n "(默认: 3): "
    read -r obfs_choice
    case $obfs_choice in
        1) obfs="tls" ;;
        2) obfs="http" ;;
        *) obfs="off" ;;
    esac

    echo -e "${YELLOW}是否开启 IPv6 支持？${RESET}"
    echo "1. 开启   2. 关闭"
    echo -n "(默认: 2): "
    read -r ipv6_choice
    if [ "${ipv6_choice:-2}" = "1" ]; then ipv6="1"; else ipv6="0"; fi

    echo -e "${YELLOW}是否开启 TCP Fast Open (TFO)？${RESET}"
    echo "1. 开启   2. 关闭"
    echo -n "(默认: 1): "
    read -r tfo_choice
    if [ "${tfo_choice:-1}" = "2" ]; then tfo="0"; else tfo="1"; fi

    default_dns=$(get_system_dns)
    [ -z "$default_dns" ] && default_dns="1.1.1.1,8.8.8.8"
    echo -n "请输入 DNS (默认: $default_dns): "
    read -r dns
    dns=${dns:-$default_dns}

    if [ "$ipv6" = "1" ]; then LISTEN="::0:$port"; else LISTEN="0.0.0.0:$port"; fi

    cat > "$SNELL_CONFIG" <<EOF
[snell-server]
listen = $LISTEN
psk = $key
obfs = $obfs
ipv6 = $ipv6
tfo = $tfo
dns = $dns
EOF

    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')
    surge_tfo="false"; [ "$tfo" = "1" ] && surge_tfo="true"

    cat <<EOF > "$SNELL_DIR/config.txt"
$HOSTNAME-Snell = snell, $IP, $port, psk=$key, version=5, tfo=$surge_tfo, reuse=true, ecn=true
EOF

    echo -e "${GREEN}[完成] 配置已写入 $SNELL_CONFIG${RESET}"
    echo -e "${GREEN}====== Snell Server v5 配置信息 ======${RESET}"
    echo -e "${YELLOW} 公网地址       : $IP${RESET}"
    echo -e "${YELLOW} 端口           : $port${RESET}"
    echo -e "${YELLOW} 密钥           : $key${RESET}"
    echo -e "${YELLOW} OBFS           : $obfs${RESET}"
    echo -e "${YELLOW} IPv6 支持      : $([ "$ipv6" = "1" ] && echo "开启" || echo "关闭")${RESET}"
    echo -e "${YELLOW} TCP Fast Open  : $([ "$tfo" = "1" ] && echo "开启" || echo "关闭")${RESET}"
    echo -e "${YELLOW} DNS            : $dns${RESET}"
    echo -e "${YELLOW}---------------------------------${RESET}"
    echo -e "${YELLOW}[信息] Surge v5 托管配置示例：${RESET}"
    cat "$SNELL_DIR/config.txt"
    echo -e "${YELLOW}---------------------------------\n${RESET}"
}

configures_snell() {
    if [ ! -f "$SNELL_CONFIG" ]; then _err "未找到配置文件"; return 1; fi
    configure_snell
}

# ================== 核心 Alpine 安装逻辑 ==================
install_snell_v5() {
    local force="${1:-false}"
    
    if [ -x /usr/local/bin/snell-server-v5 ] && [ "$force" != "true" ]; then
        _ok "Snell v5 已安装"; return 0
    fi

    local sarch=$( _map_arch ) || { _err "不支持的架构"; return 1; }
    
    # 强制在 Alpine 下安装完备的基础设施
    _info "正在安装 Alpine 必要系统依赖 (upx, unzip, curl)..."
    apk add --no-cache upx unzip curl >/dev/null 2>&1

    _info "正在获取官方最新稳定版版本号..."
    local version=$( _get_snell_latest_version )
    version="${version#v}"

    local tmp=$(mktemp -d)
    local download_url="https://dl.nssurge.com/snell/snell-server-v${version}-linux-${sarch}.zip"

    _info "正在下载 Snell v$version (架构: $sarch)..."
    if curl -sLo "$tmp/snell.zip" --connect-timeout 60 "$download_url"; then
        if unzip -oq "$tmp/snell.zip" -d "$tmp/"; then
            
            # 【Alpine 的核心灵魂：必须在临时目录原地 UPX 壳解压】
            _info "检测到 Alpine 环境，正在剥离官方二进制 UPX 壳以保障 musl 兼容性..."
            if command -v upx >/dev/null 2>&1; then
                upx -d "$tmp/snell-server" >/dev/null 2>&1 || _warn "UPX 脱壳失败，可能二进制文件没有加壳"
            else
                _err "UPX 工具不可用，无法进行 Alpine 兼容脱壳"
                rm -rf "$tmp"; return 1
            fi

            # 转移到执行目录
            install -m 755 "$tmp/snell-server" /usr/local/bin/snell-server-v5
            rm -rf "$tmp"
            
            create_user
            configure_snell || return 1

            # 【Alpine 专属服务管理：写入 OpenRC 脚本】
            _info "正在写入 Alpine OpenRC 服务管理配置..."
            cat > "$SNELL_RC_SERVICE" <<'EOF'
#!/sbin/openrc-run

description="Snell Server v5"
command="/usr/local/bin/snell-server-v5"
command_args="-c /etc/snell/snell-server.conf"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/snell_output.log"
error_log="/var/log/snell_error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0755 -o snell:snell /etc/snell
}
EOF
            chmod +x "$SNELL_RC_SERVICE"
            rc-update add snell default >/dev/null 2>&1 || true
            rc-service snell restart >/dev/null 2>&1 || true

            _ok "Snell v$version 已在 Alpine Linux 上成功部署并运行！"
            log "Alpine Snell v$version 安装成功"
            return 0
        else
            _err "解压失败"
        fi
    else
        _err "下载失败: $download_url"
    fi

    rm -rf "$tmp"
    return 1
}

uninstall_snell() {
    echo -e "${RED}[警告] 正在彻底从 Alpine 卸载 Snell 服务...${RESET}"
    rc-service snell stop >/dev/null 2>&1 || true
    rc-update del snell >/dev/null 2>&1 || true
    rm -f "$SNELL_RC_SERVICE"
    rm -f /usr/local/bin/snell-server-v5
    rm -rf "$SNELL_DIR"
    _ok "Alpine Snell 服务已完全卸载。"
}

# ================== 菜单 ==================
show_menu() {
    clear
    # Alpine 进程运行状态监测
    if rc-service snell status 2>&1 | grep -q "started"; then
        STATUS="${GREEN}● 运行中 (OpenRC)${RESET}"
    elif pgrep -x "snell-server-v5" >/dev/null; then
        STATUS="${GREEN}● 运行中 (PID 托管)${RESET}"
    else
        STATUS="${RED}● 未运行${RESET}"
    fi

    VERSION_SHOW="未安装"
    if [ -x /usr/local/bin/snell-server-v5 ]; then
        VERSION_SHOW=$(/usr/local/bin/snell-server-v5 -v 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "v5.x")
    fi

    PORT_SHOW="-"
    if [ -f "$SNELL_CONFIG" ]; then
        PORT_SHOW=$(grep '^listen' "$SNELL_CONFIG" | awk -F: '{print $NF}')
    fi

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    Snell v5 管理面板 (Alpine 专版) ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $STATUS"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}$VERSION_SHOW${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}$PORT_SHOW${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Snell v5${RESET}"
    echo -e "${GREEN}2. 更新 Snell v5 (覆盖安装)${RESET}"
    echo -e "${GREEN}3. 卸载 Snell${RESET}"
    echo -e "${GREEN}4. 修改配置项${RESET}"
    echo -e "${GREEN}5. 启动 Snell${RESET}"
    echo -e "${GREEN}6. 停止 Snell${RESET}"
    echo -e "${GREEN}7. 重启 Snell${RESET}"
    echo -e "${GREEN}8. 查看运行日志${RESET}"
    echo -e "${GREEN}9. 查看当前节点配置 (Surge 文本)${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# ================== 主循环 ==================
while true; do
    show_menu
    echo -e -n "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case $choice in
        1) install_snell_v5 "false"; pause ;;
        2) install_snell_v5 "true"; pause ;;
        3) uninstall_snell; pause ;;
        4) configures_snell; rc-service snell restart >/dev/null 2>&1 && _ok "服务已重载并重启"; pause ;;
        5) rc-service snell start >/dev/null 2>&1 || /usr/local/bin/snell-server-v5 -c $SNELL_CONFIG >/dev/null 2>&1 &
           _ok "Snell 已尝试启动"; pause ;;
        6) rc-service snell stop >/dev/null 2>&1 || pkill -f snell-server-v5 || true
           _ok "Snell 已停止"; pause ;;
        7) rc-service snell restart >/dev/null 2>&1 || { pkill -f snell-server-v5 || true; /usr/local/bin/snell-server-v5 -c $SNELL_CONFIG >/dev/null 2>&1 & };
           _ok "Snell 已重启"; pause ;;
        8)
            if [ -f /var/log/snell_error.log ]; then
                echo "--- 最近50行系统运行错误日志 ---"
                tail -n 50 /var/log/snell_error.log
            else
                _warn "暂无 OpenRC 标准服务输出日志，尝试读取管理日志："
                [ -f "$LOG_FILE" ] && tail -n 50 "$LOG_FILE" || echo "暂无任何日志"
            fi
            pause ;;
        9)
            if [ -f "$SNELL_CONFIG" ]; then
                echo -e "${GREEN}====== 当前 Snell 内部配置 ======${RESET}"
                cat "$SNELL_CONFIG"
                echo -e "${GREEN}====== Surge 专属代理配置 ======${RESET}"
                [ -f "$SNELL_DIR/config.txt" ] && cat "$SNELL_DIR/config.txt" || echo "暂无配置文本"
            else
                echo -e "${RED}配置文件不存在，请先安装！${RESET}"
            fi
            pause ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${RESET}"; pause ;;
    esac
done
