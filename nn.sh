#!/usr/bin/env bash

# ==============================================================================
#  cf-warp-rust 绿色经典风格一键管理面板 (透明代理分流 & 谷歌出口双效审计版)
# ==============================================================================

# ── 核心环境变量 ──────────────────────────────────────────────────────────────
export REPO="Shannon-x/cf-warp-rust"
export SERVICE_NAME="warp-rust"
export SERVICE_USER="warp"
export INSTALL_BIN="/usr/local/bin/warp-rust"
export CONF_DIR="/etc/warp-rust"
export CONF_FILE="${CONF_DIR}/config.toml"
export DATA_DIR="/var/lib/warp-rust"
export SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 透明代理组件专用环境变量
export PROXY_SERVICE_NAME="warp-google"
export PROXY_SERVICE_FILE="/etc/systemd/system/${PROXY_SERVICE_NAME}.service"
export PROXY_BIN="/usr/local/bin/warp-google"

# ── 终端颜色定义（严格对齐 AnyTLS 模板风格） ──────────────────────────────────
export RESET='\033[0m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'

# ── 基础环境校验 ──────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[错误]${RESET} 请使用 root 权限运行此脚本 (sudo bash)！" >&2
    exit 1
fi

info() { echo -e "${BLUE}[INFO]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
die()  { echo -e "${RED}[ERROR]${RESET} $1" >&2; exit 1; }

for cmd in curl tar sed grep awk; do
    if ! command -v $cmd &> /dev/null; then
        die "缺失基础组件: $cmd，请先使用系统包管理器安装它。"
    fi
done

# 自动探测系统包管理器
OS=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
fi

# ── 1. 动态自适应组件（精准匹配 Musl 静态包） ─────────────────────────────────
detect_target() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  TARGET="x86_64-unknown-linux-musl" ;;
        aarch64) TARGET="aarch64-unknown-linux-musl" ;;
        *) die "暂不支持的系统架构: $ARCH (本面板目前仅支持 x86_64 及 aarch64)" ;;
    esac
}

fetch_latest_version() {
    info "正在查询 GitHub 获取最新 Release 版本号..."
    TMP_API="$(mktemp)"
    if curl -sSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${REPO}/releases/latest" > "$TMP_API"; then
        VERSION="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$TMP_API" | head -1)"
    fi
    rm -f "$TMP_API"

    if [ -z "$VERSION" ]; then
        warn "通过 API 获取最新版本号失败，尝试网页流解析..."
        VERSION=$(curl -sS https://github.com/${REPO}/releases/latest | grep -o 'tag/[vV]*[0-9.]*' | head -n1 | awk -F '/' '{print $2}')
    fi

    if [ -z "$VERSION" ]; then
        die "无法获取最新版本号，请检查网络连通性。"
    fi
    export VERSION
}

download_and_extract() {
    detect_target
    fetch_latest_version
    
    info "正在匹配系统环境形态: ${YELLOW}${TARGET}${RESET}"

    ASSET="warp-rust-${VERSION}-${TARGET}.tar.gz"
    URL_TGZ="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
    URL_SHA="${URL_TGZ}.sha256"

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    info "开始同步下载资产包..."
    curl -fsSL -o "$TMP/$ASSET" "$URL_TGZ" || die "下载资产包失败！请检查网络或版本 ${VERSION} 是否存在该架构。"
    
    if curl -fsSL -o "$TMP/$ASSET.sha256" "$URL_SHA" &> /dev/null; then
        if command -v sha256sum &> /dev/null; then
            LOCAL_SHA=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
            REMOTE_SHA=$(cat "$TMP/$ASSET.sha256" | awk '{print $1}')
            if [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
                ok "数字签名校验通过。"
            fi
        fi
    fi

    tar xzf "$TMP/$ASSET" -C "$TMP"
    
    EXTRACTED_BIN=$(find "$TMP" -type f -name "warp-rust" | head -n 1)
    [ -n "$EXTRACTED_BIN" ] || die "解压成功，但在归档包内未找到 warp-rust 主程序！"
    
    export TARGET_BIN_PATH="$EXTRACTED_BIN"
}

# ── 2. 配置文件与服务管理 ──────────────────────────────────────────────────────
write_config() {
    local bind_ip="$1"
    local bind_port="$2"
    local username="$3"
    local password="$4"

    [ -d "$CONF_DIR" ] || install -m 0755 -d "$CONF_DIR"
    
    cat <<EOF > "$CONF_FILE"
[server]
bind = "${bind_ip}:${bind_port}"
EOF

    if [ -n "$username" ] && [ -n "$password" ]; then
        cat <<EOF >> "$CONF_FILE"

[server.auth]
username = "${username}"
password = "${password}"
EOF
    fi

    cat <<EOF >> "$CONF_FILE"

[logging]
level = "warn,warp_rust=info,wireguard_netstack=warn"
format = "pretty"

[warp]
data_dir = "${DATA_DIR}"
device_model = "warp-rust"
refresh_interval = "24h"
register_cooldown = "10m"
mtu = 1420
tcp_buffer_size = 1048576

[health]
interval = "30s"
timeout = "8s"

[recovery]
reconnect_after        = 1
rebuild_config_after   = 3
reregister_after       = 5
rotate_identity_after  = 10
backoff_min = "500ms"
backoff_max = "30s"

[metrics]
enabled = true
bind = "127.0.0.1:9090"

[hot_reload]
enabled = true

[limits]
max_concurrent_connections = 1024
handshake_timeout = "10s"
idle_timeout = "300s"
relay_buffer_size = 262144
auth_fail_sleep = "1s"
relay_close_grace = "500ms"

[dns]
mode = "system"
servers = ["1.1.1.1:53", "1.0.0.1:53"]
timeout = "3s"
cache_ttl = "60s"
EOF
}

write_systemd() {
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=cf-warp-rust Cloudflare WARP Proxy Client
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${DATA_DIR}
ExecStart=${INSTALL_BIN} --config ${CONF_FILE}
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

# ── 3. 面板功能函数实现 ────────────────────────────────────────────────────────
get_status_info() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        panel_status="${GREEN}运行中 (Active)${RESET}"
    else
        panel_status="${RED}未运行 (Inactive)${RESET}"
    fi

    if [ -f "$INSTALL_BIN" ]; then
        local raw_ver=$("$INSTALL_BIN" --version 2>/dev/null | awk '{print $2}')
        panel_version="${raw_ver:-已安装}"
    else
        panel_version="${RED}未安装${RESET}"
    fi

    if [ -f "$CONF_FILE" ]; then
        panel_port=$(grep -i 'bind' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '"' | tr -d ' ')
    else
        panel_port="127.0.0.1:1080"
    fi

    if systemctl is-active --quiet "$PROXY_SERVICE_NAME" 2>/dev/null; then
        proxy_status="${GREEN}已启用${RESET}"
    else
        proxy_status="${RED}未启用${RESET}"
    fi
}

menu_install() {
    if [ -f "$INSTALL_BIN" ]; then
        warn "系统中已存在运行中的实例文件。"
        echo -ne "${GREEN}是否确定完全覆盖重新安装？[y/N]: ${RESET}"
        read res
        [[ "$res" =~ ^[Yy]$ ]] || return
    fi

    echo -e "\n${GREEN}==== [自定义安装配置] ====${RESET}"
    
    # 修复高版本 Linux 终端下 read -p 带来的色彩代码外露故障
    echo -ne "${GREEN}请输入监听 IP 地址 [默认: 127.0.0.1]: ${RESET}"
    read input_ip
    local opt_ip="${input_ip:-127.0.0.1}"

    echo -ne "${GREEN}请输入 SOCKS5 监听端口 [默认: 1080]: ${RESET}"
    read input_port
    local opt_port="${input_port:-1080}"
    if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [ "$opt_port" -le 0 ] || [ "$opt_port" -gt 65535 ]; then
        opt_port=1080
    fi

    local opt_user=""
    local opt_pass=""

    if [ "$opt_ip" != "127.0.0.1" ] && [ "$opt_ip" != "localhost" ]; then
        echo -e "${YELLOW}[安全审计] 检测到您选择将服务绑定到公网/局域网 (${opt_ip})，必须强制设置账号密码鉴权！${RESET}"
        while true; do
            echo -ne "${GREEN}请输入鉴权用户名 (不能为空): ${RESET}"
            read opt_user
            [ -n "$opt_user" ] && break
            echo -e "${RED}[错误] 用户名不能为空，请重新输入。${RESET}"
        done
        while true; do
            echo -ne "${GREEN}请输入鉴权密码 (为了安全，内核要求必须 ≥16 位): ${RESET}"
            read opt_pass
            if [ ${#opt_pass} -ge 16 ]; then break; fi
            echo -e "${RED}[安全终止] 密码长度不够。公网暴露必须使用 16 位及以上的强密码！${RESET}"
        done
    else
        echo -ne "${GREEN}请输入鉴权用户名 (本地回环默认留空不启用): ${RESET}"
        read opt_user
        if [ -n "$opt_user" ]; then
            echo -ne "${GREEN}请输入鉴权密码: ${RESET}"
            read opt_pass
            if [ -z "$opt_pass" ]; then
                warn "密码为空，已取消鉴权设置。"
                opt_user=""
            fi
        fi
    fi

    download_and_extract

    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER" 2>/dev/null \
          || adduser --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    fi

    install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$INSTALL_BIN"
    install -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" -d "$DATA_DIR"

    write_config "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    write_systemd

    systemctl start "$SERVICE_NAME"
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "AnyTLS-Style WARP 安全部署成功！"
    else
        warn "部署完成，但进程启动异常，请稍后选择 [8] 查看日志。"
    fi
}

menu_update() {
    [ -f "$SERVICE_FILE" ] || die "未检测到系统服务，请先选择 [1] 进行安装。"
    download_and_extract
    systemctl stop "$SERVICE_NAME"
    install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$INSTALL_BIN"
    systemctl start "$SERVICE_NAME"
    ok "组件已成功平滑更新。"
}

menu_uninstall() {
    echo -ne "${GREEN}确定要完全卸载清除吗？[y/N]: ${RESET}"
    read res
    [[ "$res" =~ ^[Yy]$ ]] || return
    if [ -f "$PROXY_SERVICE_FILE" ]; then
        setup_transparent_proxy_disable
    fi
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$INSTALL_BIN" "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$CONF_DIR" "$DATA_DIR"
    userdel "$SERVICE_USER" >/dev/null 2>&1
    ok "清理完毕。"
}

menu_edit_config() {
    [ -f "$CONF_FILE" ] || die "未发现任何配置文件，请先执行安装步骤。"
    
    local current_bind=$(grep -i 'bind' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '"' | tr -d ' ')
    local current_ip=$(echo "$current_bind" | awk -F ':' '{print $1}')
    local current_port=$(echo "$current_bind" | awk -F ':' '{print $2}')
    local current_user=$(grep -i 'username' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '"' | tr -d ' ')
    local current_pass=$(grep -i 'password' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '"' | tr -d ' ')

    [ -z "$current_ip" ] && current_ip="127.0.0.1"
    [ -z "$current_port" ] && current_port="1080"

    echo -e "\n${GREEN}==== [修改内核参数配置] ====${RESET}"
    echo -e "${BLUE}[提示] 直接按回车将维持当前默认值不变${RESET}\n"

    echo -ne "${GREEN}请输入监听 IP 地址 [当前: ${current_ip}]: ${RESET}"
    read input_ip
    local opt_ip="${input_ip:-$current_ip}"

    echo -ne "${GREEN}请输入 SOCKS5 监听端口 [当前: ${current_port}]: ${RESET}"
    read input_port
    local opt_port="${input_port:-$current_port}"
    if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [ "$opt_port" -le 0 ] || [ "$opt_port" -gt 65535 ]; then
        opt_port="$current_port"
    fi

    local opt_user=""
    local opt_pass=""

    if [ "$opt_ip" != "127.0.0.1" ] && [ "$opt_ip" != "localhost" ]; then
        echo -e "${YELLOW}[安全审计] 检测到服务暴露在非回环地址 (${opt_ip})，必须强制设定鉴权密码！${RESET}"
        local prompt_user_desc="请输入鉴权用户名"
        [ -n "$current_user" ] && prompt_user_desc="请输入鉴权用户名 [当前: ${current_user}]"
        
        while true; do
            echo -ne "${GREEN}${prompt_user_desc}: ${RESET}"
            read input_user
            opt_user="${input_user:-$current_user}"
            [ -n "$opt_user" ] && break
            echo -e "${RED}[错误] 公网暴露下用户名不能为空。${RESET}"
        done

        local prompt_pass_desc="请输入鉴权密码 (≥16位)"
        [ -n "$current_pass" ] && prompt_pass_desc="请输入鉴权密码 [当前已设置，直接回车保持不变]"

        while true; do
            echo -ne "${GREEN}${prompt_pass_desc}: ${RESET}"
            read input_pass
            opt_pass="${input_pass:-$current_pass}"
            if [ ${#opt_pass} -ge 16 ]; then break; fi
            echo -e "${RED}[安全终止] 密码长度不够 (${#opt_pass}位)。公网暴露必须使用 16 位及以上的强密码！${RESET}"
        done
    else
        local p_user_text="请输入鉴权用户名 (留空不启用)"
        [ -n "$current_user" ] && p_user_text="请输入鉴权用户名 [当前: ${current_user}]"
        echo -ne "${GREEN}${p_user_text}: ${RESET}"
        read input_user
        
        if [ -z "$input_user" ] && [ -n "$current_user" ]; then
            opt_user="$current_user"
            opt_pass="$current_pass"
        else
            opt_user="$input_user"
            if [ -n "$opt_user" ]; then
                echo -ne "${GREEN}请输入鉴权密码: ${RESET}"
                read input_pass
                opt_pass="$input_pass"
            fi
        fi
    fi

    write_config "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl restart "$SERVICE_NAME" && ok "配置已覆盖，服务已成功重启使新参数生效！"
        if systemctl is-active --quiet "$PROXY_SERVICE_NAME" 2>/dev/null; then
            systemctl restart "$PROXY_SERVICE_NAME"
        fi
    else
        ok "配置已成功重写更新。"
    fi
}

menu_show_node_config() {
    if [ ! -f "$CONF_FILE" ]; then
        die "未检测到有效的服务配置文件。"
    fi
    
    echo -e "\n${GREEN}========= 当前节点本地配置 =========${RESET}"
    cat "$CONF_FILE" | grep -A 5 "\[server\]"
    echo -e "${GREEN}====================================${RESET}"

    local full_bind=$(grep -i 'bind' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '"' | tr -d ' ')
    local bind_ip=$(echo "$full_bind" | awk -F ':' '{print $1}')
    local bind_port=$(echo "$full_bind" | awk -F ':' '{print $2}')

    local connect_ip="$bind_ip"
    if [ "$connect_ip" = "0.0.0.0" ]; then connect_ip="127.0.0.1"; fi

    local auth_user=$(grep -i 'username' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '"' | tr -d ' ')
    local auth_pass=$(grep -i 'password' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '"' | tr -d ' ')

    local proxy_args="--socks5-hostname ${connect_ip}:${bind_port}"
    if [ -n "$auth_user" ] && [ -n "$auth_pass" ]; then
        proxy_args="--socks5-hostname ${auth_user}:${auth_pass}@${connect_ip}:${bind_port}"
    fi

    echo -e "\n${YELLOW}[正在通过 SOCKS5 代理验证流量连通性...]${RESET}"
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        warn "警告: 当前本地检测到后台服务未开启，验证可能无法成功！"
    fi

    TMP_TRACE="$(mktemp)"
    if curl -sS --max-time 6 $proxy_args "https://1.1.1.1/cdn-cgi/trace" > "$TMP_TRACE" 2>&1; then
        local trace_ip=$(grep -i '^ip=' "$TMP_TRACE" | awk -F '=' '{print $2}')
        local trace_warp=$(grep -i '^warp=' "$TMP_TRACE" | awk -F '=' '{print $2}')
        local trace_colo=$(grep -i '^colo=' "$TMP_TRACE" | awk -F '=' '{print $2}')

        echo -e "${GREEN}========= Cloudflare 真实性报告 =========${RESET}"
        if [ "$trace_warp" = "on" ] || [ "$trace_warp" = "plus" ]; then
            echo -e " 隧道验证状态 :  ${GREEN}✔ 通过 (流量确实从 Cloudflare 网络流出)${RESET}"
            echo -e " WARP 激活状态:  ${GREEN}on${RESET}"
        else
            echo -e " 隧道验证状态 :  ${RED}✘ 未通过 (可能没有走代理隧道)${RESET}"
            echo -e " WARP 激活状态:  ${RED}${trace_warp:-off}${RESET}"
        fi
        echo -e " CF 分配出口IP:  ${YELLOW}${trace_ip}${RESET}"
        echo -e " CF 边缘数据中心: ${YELLOW}${trace_colo}${RESET}"
        echo -e "${GREEN}=========================================${RESET}\n"
    else
        echo -e "${RED}[验证失败]${RESET} 无法通过代理连接到 Cloudflare 验证端点。"
        echo -e "错误回显: $(cat "$TMP_TRACE" | head -n 2)\n"
    fi
    rm -f "$TMP_TRACE"
}

# ── 3.5 透明代理核心逻辑 ──────────────────────────────────────────────────────
setup_transparent_proxy() {
    [ -f "$CONF_FILE" ] || die "未检测到已安装的 warp-rust 实例，请先执行选项 [1]！"
    
    local current_bind=$(grep -i 'bind' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '"' | tr -d ' ')
    local local_socks_port=$(echo "$current_bind" | awk -F ':' '{print $2}')
    [ -z "$local_socks_port" ] && local_socks_port="1080"

    echo -e "\n${GREEN}==================================================${RESET}"
    info "配置 Google 流量透明代理..."
    echo ""
    echo -e "${YELLOW} 本操作将：${RESET}"
    echo "    • 安装 redsocks 透明代理工具"
    echo "    • 添加 iptables 规则，将 Google IP 段自动导入并分流至本地 WARP (端口: $local_socks_port)"
    echo "    • 屏蔽 Google IPv6 地址（防止 IPv4/IPv6 归属不一致产生分流穿透）"
    echo "    • 注册 systemd 系统级服务，确保开机自启自动生效"
    echo ""
    echo -ne "  确认继续? [y/N]: "
    read confirm_proxy
    [[ ! "$confirm_proxy" =~ ^[Yy]$ ]] && { warn "已取消"; return; }

    mkdir -p /etc/
    cat > /etc/redsocks.conf <<REOF
base {
    log_debug = off;
    log_info  = on;
    log       = "syslog:daemon";
    daemon    = on;
    redirector = iptables;
}
redsocks {
    local_ip   = 127.0.0.1;
    local_port = 12345;
    ip         = 127.0.0.1;
    port       = ${local_socks_port};
    type       = socks5;
}
REOF

    echo '#!/bin/sh
exit 101' > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d

    # 深度改动点：去掉 -qq 以及静默转发，让 APT/YUM 安装流程彻底公开透明，100% 避免后台假死不知情！
    info "正在使用包管理器部署必要底层组件 (redsocks / iptables)，请观察实时输出..."
    case $OS in
        ubuntu|debian)
            apt-get update -y
            apt-get install -y redsocks iptables
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y redsocks iptables
            else
                yum install -y redsocks iptables
            fi
            ;;
        *)
            apt-get install -y redsocks iptables || yum install -y redsocks iptables
            ;;
    esac

    rm -f /usr/sbin/policy-rc.d

    local GOOGLE_V6_LIST=(
        "2001:4860::/32"
        "2404:6800::/32"
        "2404:f340::/32"
        "2600:1900::/28"
        "2607:f8b0::/32"
        "2620:11a:a000::/40"
        "2620:120:e000::/40"
        "2800:3f0::/32"
        "2a00:1450::/32"
        "2c0f:fb50::/32"
    )

    info "添加 Google IPv6 黑洞路由（共 ${#GOOGLE_V6_LIST[@]} 条）..."
    for v6 in "${GOOGLE_V6_LIST[@]}"; do
        ip -6 route add blackhole "$v6" 2>/dev/null || true
    done

    if ! grep -q "precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
    fi

    ok "Google IPv6 黑洞路由已添加"

    # 主控脚本生成
    cat > "$PROXY_BIN" <<'SCRIPT'
#!/usr/bin/env bash
GOOGLE_IPS="
8.8.4.0/24
8.8.8.0/24
34.0.0.0/9
35.184.0.0/13
35.192.0.0/12
35.224.0.0/12
35.240.0.0/13
64.233.160.0/19
66.102.0.0/20
66.249.64.0/19
72.14.192.0/18
74.125.0.0/16
104.132.0.0/14
108.177.0.0/17
142.250.0.0/15
172.217.0.0/16
172.253.0.0/16
173.194.0.0/16
209.85.128.0/17
216.58.192.0/19
216.239.32.0/19
"

GOOGLE_V6_IPS="
2001:4860::/32
2404:6800::/32
2404:f340::/32
2600:1900::/28
2607:f8b0::/32
2620:11a:a000::/40
2620:120:e000::/40
2800:3f0::/32
2a00:1450::/32
2c0f:fb50::/32
"

add_v6_blackhole() {
    for v6 in $GOOGLE_V6_IPS; do
        ip -6 route add blackhole "$v6" 2>/dev/null || true
    done
}

del_v6_blackhole() {
    for v6 in $GOOGLE_V6_IPS; do
        ip -6 route del blackhole "$v6" 2>/dev/null || true
    done
}

start() {
    pkill redsocks 2>/dev/null
    redsocks -c /etc/redsocks.conf
    iptables -t nat -N WARP_GOOGLE 2>/dev/null || iptables -t nat -F WARP_GOOGLE
    for ip in $GOOGLE_IPS; do
        iptables -t nat -A WARP_GOOGLE -d "$ip" -p tcp -j REDIRECT --to-ports 12345
    done
    iptables -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null \
        || iptables -t nat -A OUTPUT -j WARP_GOOGLE

    add_v6_blackhole
    echo "WARP Google 透明代理已启动（IPv4 劫持 + IPv6 黑洞）"
}

stop() {
    pkill redsocks 2>/dev/null
    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    iptables -t nat -F WARP_GOOGLE 2>/dev/null
    iptables -t nat -X WARP_GOOGLE 2>/dev/null
    del_v6_blackhole
    echo "WARP Google 透明代理已停止"
}

status() {
    echo -e "\033[0;32m=== 1. 组件状态审计 ===\033[0m"
    systemctl is-active --quiet warp-rust && echo "cf-warp-rust 内核: 运行中" || echo "cf-warp-rust 内核: 未运行"
    pgrep -x redsocks >/dev/null && echo "Redsocks 管道缓存: 运行中" || echo "Redsocks 管道缓存: 未运行"
    
    echo -e "\n\033[0;32m=== 2. 防火墙分流拦截规则 ===\033[0m"
    local rules_cnt=$(iptables -t nat -L WARP_GOOGLE -n 2>/dev/null | wc -l)
    if [ "$rules_cnt" -gt 0 ]; then
        echo "iptables 分流规则: 已成功挂载 (共 $((rules_cnt - 2)) 条 Google CIDR 拦截链)"
    else
        echo "iptables 分流规则: 未挂载规则"
    fi
    echo "IPv6 封锁黑洞路由数: $(ip -6 route show type blackhole 2>/dev/null | grep -c "/" || echo "0")"

    echo -e "\n\033[0;32m=== 3. 真实 Google 流量分流连通性测试 (双重探针) ===\033[0m"
    echo -e "正在向 \033[0;33mGoogle DNS (8.8.8.8)\033[0m 注入测试探针流量..."

    local TMP_GOOG=$(mktemp)
    
    if curl -sS -H "Host: 1.1.1.1" --connect-timeout 4 --max-time 6 "http://8.8.8.8/cdn-cgi/trace" > "$TMP_GOOG" 2>&1 && grep -q "warp=" "$TMP_GOOG"; then
        local g_ip=$(grep -i '^ip=' "$TMP_GOOG" | awk -F '=' '{print $2}')
        local g_warp=$(grep -i '^warp=' "$TMP_GOOG" | awk -F '=' '{print $2}')
        local g_colo=$(grep -i '^colo=' "$TMP_GOOG" | awk -F '=' '{print $2}')
        
        echo -e " 谷歌流分流状态:  \033[0;32m✔ 成功拦截劫持 (Google 流量已走 WARP 出口)\033[0m"
        echo -e " WARP 隧道激活态:  \033[0;32m${g_warp}\033[0m"
        echo -e " Google 专用出口IP: \033[0;33m${g_ip}\033[0m"
        echo -e " 出口边缘数据中心:  \033[0;33m${g_colo}\033[0m"
    else
        echo -e " 谷歌流分流状态:  \033[0;31m✘ 拦截失败 / 穿透走原生公网网络\033[0m"
        echo -e " 诊断原因: 流量未被 iptables 规则成功导入 redsocks 管道，或本地 warp-rust 进程尚未就绪。"
    fi
    rm -f "$TMP_GOOG"
    echo ""
}

case "$1" in
    start)   start   ;;
    stop)    stop    ;;
    restart) stop; sleep 1; start ;;
    status)  status  ;;
    *) echo "用法: $0 {start|stop|restart|status}" ;;
esac
SCRIPT
    chmod +x "$PROXY_BIN"

    "$PROXY_BIN" start

    cat <<EOF > "$PROXY_SERVICE_FILE"
[Unit]
Description=WARP Google Transparent Proxy
After=network.target warp-rust.service
Wants=warp-rust.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${PROXY_BIN} start
ExecStop=${PROXY_BIN} stop

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$PROXY_SERVICE_NAME" >/dev/null 2>&1

    echo ""
    echo -e "${GREEN}  ┌─────────────────────────────────────────────────┐${RESET}"
    echo -e "${GREEN}  │  ✔  透明代理配置完成                           │${RESET}"
    echo -e "${GREEN}  │     Google 流量现已自动走 WARP 出口             │${RESET}"
    echo -e "${GREEN}  └─────────────────────────────────────────────────┘${RESET}"
    echo ""
}

setup_transparent_proxy_disable() {
    if [ ! -f "$PROXY_BIN" ]; then
        warn "系统中未发现已配置的透明代理组件。"
        return
    fi
    info "正在卸载并移除全局透明代理劫持规则..."
    systemctl stop "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    "$PROXY_BIN" stop >/dev/null 2>&1
    rm -f "$PROXY_BIN" "$PROXY_SERVICE_FILE" /etc/redsocks.conf
    systemctl daemon-reload
    ok "透明代理规则已完全净化卸载。"
}

# ── 4. 主循环控制中心 ─────────────────────────────────────────────────────────
while true; do
    get_status_info
    
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}       CF-WARP-RUST 面板       ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $panel_status"
    echo -e "${GREEN}版本 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}绑定 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1. 安装 WARP-Rust${RESET}"
    echo -e "${GREEN} 2. 更新 WARP-Rust${RESET}"
    echo -e "${GREEN} 3. 卸载 WARP-Rust${RESET}"
    echo -e "${GREEN} 4. 修改配置 (自定义IP/端口/密码)${RESET}"
    echo -e "${GREEN} 5. 启动 WARP-Rust${RESET}"
    echo -e "${GREEN} 6. 停止 WARP-Rust${RESET}"
    echo -e "${GREEN} 7. 重启 WARP-Rust${RESET}"
    echo -e "${GREEN} 8. 查看日志${RESET}"
    echo -e "${GREEN} 9. 查看节点配置与出口状态${RESET}"
    echo -e "${GREEN}# ────────────────────────── 透明代理（Google 流量走 WARP）──────────────────────────${RESET}"
    echo -e "${GREEN}10. 开启 Google 流量透明代理 [状态: ${proxy_status}]${RESET}"
    echo -e "${GREEN}11. 关闭/卸载 透明代理规则${RESET}"
    echo -e "${GREEN}12. 查看透明代理分流状态与诊断 (带 Google 出口 CF 连通性校验)${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    
    echo -ne "${GREEN}请输入选项 [0-12]: ${RESET}"
    read choice
    
    case "$choice" in
        1) menu_install ;;
        2) menu_update ;;
        3) menu_uninstall ;;
        4) menu_edit_config ;;
        5) systemctl start "$SERVICE_NAME" && ok "动作: 启动成功" ;;
        6) systemctl stop "$SERVICE_NAME" && ok "动作: 停止成功" ;;
        7) systemctl restart "$SERVICE_NAME" && ok "动作: 重启成功" ;;
        8) journalctl -u "$SERVICE_NAME" -n 50 -f ;;
        9) menu_show_node_config ;;
        10) setup_transparent_proxy ;;
        11) setup_transparent_proxy_disable ;;
        12) [ -f "$PROXY_BIN" ] && "$PROXY_BIN" status || warn "透明代理未部署，无可用分析报告。" ;;
        0) clear; exit 0 ;;
        *) warn "未识别的无效序号！"; sleep 1 ;;
    esac
    echo
    echo -ne "${GREEN}按任意键返回主控制面板...${RESET}"
    read -n 1 -s -r
done
