#!/bin/sh
set -e

# =========================================================
# Snell v6 (双栈+DNS增强+自定义监听) Alpine OpenRC 管理脚本
# =========================================================

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
SNELL_DEFAULT_VERSION="6.0.0b2"

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
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [ -n "$ip" ] && echo "$ip" && return
        done
    done
    echo "你的服务器IP"
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
        *) return 1 ;;
    esac
}

_get_snell_latest_version() {
    local latest_version
    latest_version=$(curl -sL -A "Mozilla/5.0" "https://kb.nssurge.com/surge-knowledge-base/release-notes/snell" | grep -oE 'v6\.[0-9]+\.[0-9]+(b[0-9]+)?' | head -n 1 2>/dev/null || echo "")
    if [ -n "$latest_version" ]; then
        echo "${latest_version#v}"
    else
        echo "$SNELL_DEFAULT_VERSION"
    fi
}

# 精准无误的配置提取引擎
_get_conf_value() {
    local key="$1"
    if [ -f "$SNELL_CONFIG" ]; then
        grep -E "^${key}\s*=" "$SNELL_CONFIG" | awk -F'=' '{print $2}' | sed 's/ //g' | tr -d '\r\n'
    fi
}

# ================== 配置 Snell (支持自定义监听与完美修复) ==================
configure_snell() {
    mkdir -p "$SNELL_DIR"
    echo -e "${GREEN}[信息] 开始配置 Snell v6 增强参数...${RESET}"

    # 读取并解析旧配置
    local old_listen=$(_get_conf_value "listen")
    local old_port=""
    if [ -n "$old_listen" ]; then
        local first_listen="${old_listen%%,*}"
        old_port=$(echo "$first_listen" | awk -F: '{print $NF}')
    fi
    local old_key=$(_get_conf_value "psk")
    local old_obfs=$(_get_conf_value "obfs")
    local old_dns_pref=$(_get_conf_value "dns-ip-preference")
    local old_tfo=$(_get_conf_value "tfo")
    local old_dns=$(_get_conf_value "dns")

    # 1. 端口引导
    local default_port="${old_port:-$(random_port)}"
    echo -n "请输入端口 (当前/默认: $default_port): "
    read -r input_port
    port=${input_port:-$default_port}
    if [ "$port" != "$old_port" ]; then
        check_port "$port" || return 1
    fi

    # 2. 密钥引导
    local default_key="${old_key:-$(random_key)}"
    echo -n "请输入 Snell 核心密钥 (当前/默认: $default_key): "
    read -r input_key
    key=${input_key:-$default_key}

    # 3. 监听地址策略引导 (新增特性)
    local current_listen_str="双栈全监听"
    if [ "$old_listen" = "0.0.0.0:$port" ]; then
        current_listen_str="仅监听 IPv4"
    elif [ "$old_listen" = "[::]:$port" ]; then
        current_listen_str="仅监听 IPv6"
    fi
    echo -e "${YELLOW}请选择 Snell v6 监听地址策略 (当前配置: $current_listen_str)：${RESET}"
    echo "1. 双栈全监听  (0.0.0.0 和 [::] 同时绑定，全能推荐)"
    echo "2. 仅监听 IPv4 (仅绑定 0.0.0.0)"
    echo "3. 仅监听 IPv6 (仅绑定 [::]，适合纯 IPv6 小鸡)"
    echo -n "请选择序号 (直接回车保持当前不变): "
    read -r listen_choice
    case $listen_choice in
        1) listen_addr="0.0.0.0:$port,[::]:$port" ;;
        2) listen_addr="0.0.0.0:$port" ;;
        3) listen_addr="[::]:$port" ;;
        *) listen_addr="${old_listen:-0.0.0.0:$port,[::]:$port}" ;;
    esac

    # 4. OBFS 混淆引导
    local current_obfs_str="${old_obfs:-off}"
    echo -e "${YELLOW}配置 OBFS 混淆 (当前配置: $current_obfs_str)：[注意] 无特殊需求不建议启用${RESET}"
    echo "1. TLS   2. HTTP   3. 关闭"
    echo -n "请选择 (直接回车保持当前不变): "
    read -r obfs_choice
    case $obfs_choice in
        1) obfs="tls" ;;
        2) obfs="http" ;;
        3) obfs="off" ;;
        *) obfs="$current_obfs_str" ;;
    esac

    # 5. DNS IP 家族优先级引导
    local current_dns_pref="${old_dns_pref:-default}"
    echo -e "${YELLOW}请选择 Snell v6 DNS 解析 IP 家族优先级 (当前配置: $current_dns_pref)：${RESET}"
    echo "1. default      (系统默认)"
    echo "2. prefer-ipv4  (IPv4 优先)"
    echo "3. prefer-ipv6  (IPv6 优先)"
    echo "4. ipv4-only    (仅解析 IPv4)"
    echo "5. ipv6-only    (仅解析 IPv6)"
    echo -n "请选择序号 (直接回车保持当前不变): "
    read -r dns_pref_choice
    case $dns_pref_choice in
        1) dns_pref="default" ;;
        2) dns_pref="prefer-ipv4" ;;
        3) dns_pref="prefer-ipv6" ;;
        4) dns_pref="ipv4-only" ;;
        5) dns_pref="ipv6-only" ;;
        *) dns_pref="$current_dns_pref" ;;
    esac

    # 6. TFO 引导
    local current_tfo_str="开启"
    [ "$old_tfo" = "0" ] || [ "$old_tfo" = "false" ] && current_tfo_str="关闭"
    echo -e "${YELLOW}是否开启 TCP Fast Open (TFO)？(当前配置: $current_tfo_str)${RESET}"
    echo "1. 开启   2. 关闭"
    echo -n "请选择 (直接回车保持当前不变): "
    read -r tfo_choice
    case $tfo_choice in
        1) tfo="true" ;;
        2) tfo="false" ;;
        *) tfo="${old_tfo:-true}" ;;
    esac

    # 7. DNS 引导
    local system_dns=$(get_system_dns)
    local default_dns="${old_dns:-${system_dns:-1.1.1.1,8.8.8.8}}"
    echo -n "请输入自定义 DNS (当前/默认: $default_dns): "
    read -r input_dns
    dns=${input_dns:-$default_dns}

    # 规范化 TFO 的值
    local conf_tfo="true"
    if [ "$tfo" = "0" ] || [ "$tfo" = "false" ]; then conf_tfo="false"; fi

    # 写入 v6 规范配置文件
    cat > "$SNELL_CONFIG" <<EOF
[snell-server]
listen = $listen_addr
psk = $key
obfs = $obfs
tfo = $conf_tfo
dns = $dns
dns-ip-preference = $dns_pref
EOF

    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    # 生成规范节点配置
    cat <<EOF > "$SNELL_DIR/config.txt"
$HOSTNAME-Snell-v6 = snell, $IP, $port, psk=$key, version=6, tfo=$conf_tfo, reuse=true, ecn=true
EOF

    _ok "配置已成功安全写入 $SNELL_CONFIG"
    log "Snell v6 配置已成功同步更新。"
}

# ================== 核心 Alpine 部署逻辑 (防 404/解压兜底) ==================
_download_and_install_binary() {
    local sarch=$( _map_arch ) || { _err "不支持的架构"; return 1; }
    
    _info "正在安装 Alpine 必要系统依赖 (upx, unzip, curl, gcompat)..."
    apk add --no-cache upx unzip curl gcompat >/dev/null 2>&1

    _info "正在获取官方最新稳定版版本号..."
    local version=$( _get_snell_latest_version )
    version="${version#v}"

    local tmp=$(mktemp -d)
    local download_url_A="https://dl.nssurge.com/snell/snell-server-v${version}-linux-${sarch}.zip"
    local download_url_B="https://dl.nssurge.com/snell/snell-server-${version}-linux-${sarch}.zip"
    local download_url_C="https://dl.nssurge.com/snell/snell-server-v6.0.0b2-linux-${sarch}.zip"

    _info "正在通过智能路由下载 Snell v6 核心组件..."
    
    if curl -sL -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" -o "$tmp/snell.zip" --connect-timeout 15 "$download_url_A" && unzip -t "$tmp/snell.zip" >/dev/null 2>&1; then
        _info "方案 A 下载并校验成功！"
    elif curl -sL -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -o "$tmp/snell.zip" --connect-timeout 15 "$download_url_B" && unzip -t "$tmp/snell.zip" >/dev/null 2>&1; then
        _info "方案 B 下载并校验成功！"
    else
        _warn "官方主动拦截，启动终极弹性回滚，下载 v6.0.0b2 保底包..."
        if ! curl -sL -A "Mozilla/5.0" -o "$tmp/snell.zip" --connect-timeout 20 "$download_url_C" || ! unzip -t "$tmp/snell.zip" >/dev/null 2>&1; then
            _err "所有下载源均被防火墙拦截，请稍后再试！"
            rm -rf "$tmp"; return 1
        fi
        version="6.0.0b2"
    fi

    if unzip -oq "$tmp/snell.zip" -d "$tmp/"; then
        _info "正在进行 UPX 壳解压兼容处理..."
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
        _err "未知原因导致解压最终失败"
        rm -rf "$tmp"
        return 1
    fi
}

_deploy_openrc_service() {
    _info "正在写入 Alpine OpenRC 服务管理配置..."
    cat > "$SNELL_RC_SERVICE" <<'EOF'
#!/sbin/openrc-run

description="Snell Server v6"
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
    _ok "Snell v6 已在 Alpine Linux 上成功部署并全栈运行！"
    log "Alpine Snell v6 安装成功"

    echo
    echo -e "${GREEN}===============================================${RESET}"
    echo -e "${GREEN}                🎉 Snell v6 安装成功 🎉         ${RESET}"
    echo -e "${GREEN}===============================================${RESET}"
    echo -e "${GREEN}👉 请复制以下配置到你的 Surge 6 配置文件中：${RESET}"
    echo
    if [ -f "$SNELL_DIR/config.txt" ]; then
        echo -e "${YELLOW}$(cat "$SNELL_DIR/config.txt")${RESET}"
    else
        _warn "未找到节点配置文件文本。"
    fi
    echo -e "${GREEN}===============================================${RESET}"
    echo
}

update_snell_v5() {
    if [ ! -x /usr/local/bin/snell-server-v5 ]; then
        _err "检测到系统未安装 Snell，请先选择选项 1 进行安装！"; return 1
    fi

    _info "开始检查并更新 Snell v6 二进制程序..."
    local ver=$(_download_and_install_binary)
    [ -z "$ver" ] && return 1

    _deploy_openrc_service
    _restart_snell_process
    _ok "Snell 已成功更新至 v6，且当前配置已完好保留并重启完毕！"
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
        VERSION_SHOW=$(/usr/local/bin/snell-server-v5 -v 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(b[0-9]+)?' || echo "v6.x")
    fi

    PORT_SHOW="-"
    if [ -f "$SNELL_CONFIG" ]; then
        local raw_listen=$(_get_conf_value "listen")
        local first_listen="${raw_listen%%,*}"
        PORT_SHOW=$(echo "$first_listen" | awk -F: '{print $NF}')
    fi

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Snell v6 管理面板 (Alpine) ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $STATUS"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}$VERSION_SHOW${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}$PORT_SHOW${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Snell v6${RESET}"
    echo -e "${GREEN}2. 更新 Snell v6${RESET}"
    echo -e "${GREEN}3. 卸载 Snell${RESET}"
    echo -e "${GREEN}4. 修改自定义配置${RESET}"
    echo -e "${GREEN}5. 启动 Snell${RESET}"
    echo -e "${GREEN}6. 停止 Snell${RESET}"
    echo -e "${GREEN}7. 重启 Snell${RESET}"
    echo -e "${GREEN}8. 查看运行日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置 (Surge 6 格式)${RESET}"
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
                _ok "配置已重载，Snell v6 服务已平滑重启！"
                echo -e "\n${GREEN}👉 最新 Surge 6 节点配置：${RESET}"
                if [ -f "$SNELL_DIR/config.txt" ]; then
                    cat "$SNELL_DIR/config.txt"
                    echo ""
                fi
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
                _warn "暂无 Snell 运行日志或日志文件为空。"
            fi
            pause ;;
        9)
            if [ -f "$SNELL_CONFIG" ]; then
                echo -e "${GREEN}====== 当前 Snell v6 内部配置 ======${RESET}"
                cat "$SNELL_CONFIG"
                echo -e "${GREEN}====== Surge 6 专属配置 ======${RESET}"
                if [ -f "$SNELL_DIR/config.txt" ]; then
                    cat "$SNELL_DIR/config.txt"
                    echo ""
                else
                    echo "暂无配置文本"
                fi
            else
                echo -e "${RED}配置文件不存在，请先安装！${RESET}"
            fi
            pause ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${RESET}"; pause ;;
    esac
done
