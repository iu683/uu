#!/bin/sh
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
SNELL_LOG="/var/log/snell.log"
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

# 从配置文件中安全提取现有配置项的函数
_get_conf_value() {
    local key="$1"
    if [ -f "$SNELL_CONFIG" ]; then
        grep "^${key}" "$SNELL_CONFIG" | awk -F'=' '{print $2}' | sed 's/ //g'
    fi
}

# ================== 配置 Snell (支持读取现有值，回车不变) ==================
configure_snell() {
    mkdir -p "$SNELL_DIR"
    echo -e "${GREEN}[信息] 开始配置 Snell...${RESET}"

    # 读取旧配置（若存在）
    local old_listen=$(_get_conf_value "listen")
    local old_port=""
    [ -n "$old_listen" ] && old_port=$(echo "$old_listen" | awk -F: '{print $NF}')
    local old_key=$(_get_conf_value "psk")
    local old_obfs=$(_get_conf_value "obfs")
    local old_ipv6=$(_get_conf_value "ipv6")
    local old_tfo=$(_get_conf_value "tfo")
    local old_dns=$(_get_conf_value "dns")

    # 1. 端口
    local default_port="${old_port:-$(random_port)}"
    echo -n "请输入端口 (当前/默认: $default_port): "
    read -r input_port
    port=${input_port:-$default_port}
    if [ "$port" != "$old_port" ]; then
        check_port "$port" || return 1
    fi

    # 2. 密钥
    local default_key="${old_key:-$(random_key)}"
    echo -n "请输入 Snell 密钥 (当前/默认: $default_key): "
    read -r input_key
    key=${input_key:-$default_key}

    # 3. OBFS
    local current_obfs_str="${old_obfs:-off}"
    echo -e "${YELLOW}配置 OBFS (当前配置: $current_obfs_str)：[注意] 无特殊作用不建议启用${RESET}"
    echo "1. TLS   2. HTTP   3. 关闭"
    echo -n "请选择 (直接回车保持当前不变): "
    read -r obfs_choice
    case $obfs_choice in
        1) obfs="tls" ;;
        2) obfs="http" ;;
        3) obfs="off" ;;
        *) obfs="$current_obfs_str" ;;
    esac

    # 4. IPv6
    local current_ipv6_str="关闭"
    [ "$old_ipv6" = "1" ] && current_ipv6_str="开启"
    echo -e "${YELLOW}是否开启 IPv6 支持？(当前配置: $current_ipv6_str)${RESET}"
    echo "1. 开启   2. 关闭"
    echo -n "请选择 (直接回车保持当前不变): "
    read -r ipv6_choice
    case $ipv6_choice in
        1) ipv6="1" ;;
        2) ipv6="0" ;;
        *) ipv6="${old_ipv6:-0}" ;;
    esac

    # 5. TFO
    local current_tfo_str="开启"
    [ "$old_tfo" = "0" ] && current_tfo_str="关闭"
    echo -e "${YELLOW}是否开启 TCP Fast Open (TFO)？(当前配置: $current_tfo_str)${RESET}"
    echo "1. 开启   2. 关闭"
    echo -n "请选择 (直接回车保持当前不变): "
    read -r tfo_choice
    case $tfo_choice in
        1) tfo="1" ;;
        2) tfo="0" ;;
        *) tfo="${old_tfo:-1}" ;;
    esac

    # 6. DNS
    local system_dns=$(get_system_dns)
    local default_dns="${old_dns:-${system_dns:-1.1.1.1,8.8.8.8}}"
    echo -n "请输入 DNS (当前/默认: $default_dns): "
    read -r input_dns
    dns=${input_dns:-$default_dns}

    # 组合监听地址
    if [ "$ipv6" = "1" ]; then LISTEN="::0:$port"; else LISTEN="0.0.0.0:$port"; fi

    # 写入配置
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

    _ok "配置已成功写入 $SNELL_CONFIG"
    log "Snell 配置已成功更新。"
}

# ================== 核心 Alpine 部署逻辑 ==================
# 仅下载并覆盖二进制文件，不重装/不覆盖原有配置
_download_and_install_binary() {
    local sarch=$( _map_arch ) || { _err "不支持的架构"; return 1; }
    
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
            _info "检测到 Alpine 环境，正在进行 UPX 壳解压兼容处理..."
            if command -v upx >/dev/null 2>&1; then
                upx -d "$tmp/snell-server" >/dev/null 2>&1 || _warn "UPX 脱壳失败或无需脱壳"
            else
                _err "UPX 工具不可用，无法完成解压"
                rm -rf "$tmp"; return 1
            fi

            install -m 755 "$tmp/snell-server" /usr/local/bin/snell-server-v5
            rm -rf "$tmp"
            echo "$version"
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

# 部署 OpenRC 脚本管理
_deploy_openrc_service() {
    _info "正在写入 Alpine OpenRC 服务管理配置..."
    cat > "$SNELL_RC_SERVICE" <<'EOF'
#!/sbin/openrc-run

description="Snell Server v5"
command="/usr/local/bin/snell-server-v5"
command_args="-c /etc/snell/snell-server.conf"
command_background="yes"
pidfile="/run/snell.pid"
output_log="/var/log/snell.log"
error_log="/var/log/snell.log"

depend() {
    need net
    after firewall
}
EOF
    chmod +x "$SNELL_RC_SERVICE"
    rc-update add snell default >/dev/null 2>&1 || true
}

# 选项 1：全新安装
install_snell_v5() {
    if [ -x /usr/local/bin/snell-server-v5 ]; then
        _ok "Snell 已安装，如需更新请使用选项 2，修改配置请用选项 4。"; return 0
    fi

    local ver=$(_download_and_install_binary)
    [ -z "$ver" ] && return 1

    create_user
    configure_snell || return 1
    _deploy_openrc_service
    
    rc-service snell restart >/dev/null 2>&1 || true
    _ok "Snell 已在 Alpine Linux 上成功部署并运行！"
    log "Alpine Snell 安装成功"

    # ================== 新增：安装完直接显示节点配置 ==================
    echo
    echo -e "${GREEN}===============================================${RESET}"
    echo -e "${GREEN}               🎉 Snell 安装成功 🎉            ${RESET}"
    echo -e "${GREEN}===============================================${RESET}"
    echo -e "${GREEN}👉 请复制以下配置到你的 Surge 配置文件中：${RESET}"
    echo
    if [ -f "$SNELL_DIR/config.txt" ]; then
        echo -e "${YELLOW}$(cat "$SNELL_DIR/config.txt")${RESET}"
    else
        _warn "未找到节点配置文件文本。"
    fi
    echo -e "${GREEN}===============================================${RESET}"
    echo
}

# 选项 2：纯净更新（不覆盖、不重装配置）
update_snell_v5() {
    if [ ! -x /usr/local/bin/snell-server-v5 ]; then
        _err "检测到系统未安装 Snell，请先选择选项 1 进行安装！"; return 1
    fi

    _info "开始检查并更新 Snell 二进制程序（保留当前所有配置不变）..."
    local ver=$(_download_and_install_binary)
    [ -z "$ver" ] && return 1

    _deploy_openrc_service
    _restart_snell_process
    _ok "Snell 已成功更新，且当前配置已完好保留并重启完毕！"
    log "Alpine Snell 成功更新"
}

uninstall_snell() {
    echo -e "${RED}[警告] 正在彻底从 Alpine 卸载 Snell 服务...${RESET}"
    rc-service snell stop >/dev/null 2>&1 || true
    rc-update del snell >/dev/null 2>&1 || true
    pkill -f snell-server-v5 || true
    rm -f "$SNELL_RC_SERVICE"
    rm -f /usr/local/bin/snell-server-v5
    rm -rf "$SNELL_DIR"
    rm -f "$SNELL_LOG"
    _ok "Alpine Snell 服务已完全卸载。"
}

# 统一的启动/重启底层逻辑（确保日志正确重定向）
_restart_snell_process() {
    rc-service snell restart >/dev/null 2>&1 || {
        pkill -f snell-server-v5 || true
        touch "$SNELL_LOG"
        nohup /usr/local/bin/snell-server-v5 -c "$SNELL_CONFIG" >> "$SNELL_LOG" 2>&1 &
    }
}

# ================== 菜单 ==================
show_menu() {
    clear
    if rc-service snell status 2>&1 | grep -q "started" || pgrep -x "snell-server-v5" >/dev/null; then
        STATUS="${GREEN}● 运行中${RESET}"
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
    echo -e "${GREEN}        Snell  管理面板         ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $STATUS"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}$VERSION_SHOW${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}$PORT_SHOW${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Snell${RESET}"
    echo -e "${GREEN}2. 更新 Snell${RESET}"
    echo -e "${GREEN}3. 卸载 Snell${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Snell${RESET}"
    echo -e "${GREEN}6. 停止 Snell${RESET}"
    echo -e "${GREEN}7. 重启 Snell${RESET}"
    echo -e "${GREEN}8. 查看运行日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# ================== 主循环 ==================
while true; do
    show_menu
    echo -e -n "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case $choice in
        1) install_snell_v5; pause ;;
        2) update_snell_v5; pause ;;
        3) uninstall_snell; pause ;;
        4) 
            if [ ! -f "$SNELL_CONFIG" ]; then 
                _err "未找到配置文件，请先安装！"
            else
                configure_snell
                _restart_snell_process
                _ok "配置已重载，Snell 服务已平滑重启！"
                # 重载后同样显示最新节点信息
                echo -e "\n${GREEN}👉  Surge 节点配置：${RESET}"
                [ -f "$SNELL_DIR/config.txt" ] && echo -e "${YELLOW}$(cat "$SNELL_DIR/config.txt")${RESET}\n"
            fi
            pause ;;
        5) 
            rc-service snell start >/dev/null 2>&1 || { 
                if ! pgrep -x "snell-server-v5" >/dev/null; then
                    touch "$SNELL_LOG"
                    nohup /usr/local/bin/snell-server-v5 -c "$SNELL_CONFIG" >> "$SNELL_LOG" 2>&1 &
                fi
            }
            _ok "Snell 已成功启动"
            pause ;;
        6) 
            rc-service snell stop >/dev/null 2>&1 || pkill -f snell-server-v5 || true
            _ok "Snell 已停止"
            pause ;;
        7) 
            _restart_snell_process
            _ok "Snell 已重启"
            pause ;;
        8)
            echo -e "${GREEN}--- Snell 核心运行日志 (最新50行) ---${RESET}"
            if [ -f "$SNELL_LOG" ] && [ -s "$SNELL_LOG" ]; then
                tail -n 50 "$SNELL_LOG"
                echo -e "${YELLOW}------------------------------------------------${RESET}"
                echo -n "是否需要实时追踪新日志输出？(y/n, 默认 n): "
                read -r watch_choice
                if [ "$watch_choice" = "y" ] || [ "$watch_choice" = "Y" ]; then
                    echo -e "${YELLOW}提示: 按 Ctrl+C 即可退出日志实时追踪并返回菜单${RESET}"
                    tail -f "$SNELL_LOG"
                fi
            else
                _warn "暂无 Snell 运行日志或日志文件为空。 (请确保服务已正常启动并产生流量)"
            fi
            pause ;;
        9)
            if [ -f "$SNELL_CONFIG" ]; then
                echo -e "${GREEN}====== 当前 Snell 内部配置 ======${RESET}"
                cat "$SNELL_CONFIG"
                echo -e "${GREEN}====== Surge 专属配置 ======${RESET}"
                [ -f "$SNELL_DIR/config.txt" ] && cat "$SNELL_DIR/config.txt" || echo "暂无配置文本"
            else
                echo -e "${RED}配置文件不存在，请先安装！${RESET}"
            fi
            pause ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${RESET}"; pause ;;
    esac
done
