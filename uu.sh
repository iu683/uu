#!/usr/bin/env bash

# ==============================================================================
#  next-socks5 一键管理面板 
# ==============================================================================

# ── 核心环境变量 ──────────────────────────────────────────────────────────────
export REPO="ZingerLittleBee/next-socks5"
export SERVICE_NAME="next-socks5"
export SERVICE_USER="socks5"
export INSTALL_BIN="/usr/local/bin/next-socks5"
export CONF_DIR="/etc/next-socks5"
export CONF_FILE="${CONF_DIR}/config.toml"
export DATA_DIR="/var/lib/next-socks5"
export SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# ── 终端颜色定义 ──────────────────────────────────
export RESET='\033[0m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'

# ── GITHUB 代理加速源列表 ─────────────────────────
GITHUB_PROXIES=(
    "" # 留空代表首先尝试直连
    "https://v6.gh-proxy.org/"
    "https://gh-proxy.com/"
    "https://hub.glowp.xyz/"
    "https://proxy.vvvv.ee/"
    "https://ghproxy.lvedong.eu.org/"
)

# ── 基础环境校验 ──────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[错误]${RESET} 请使用 root 权限运行此脚本！" >&2
    exit 1
fi

info() { echo -e "${BLUE}[INFO]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
die()  { echo -e "${RED}[ERROR]${RESET} $1" >&2; exit 1; }

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        die "无法识别当前操作系统类型。"
    fi
}
detect_os


get_public_ip() {
    local mode=${1:-"v4"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        # 强制获取 IPv4
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        # 强制获取 IPv6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        # auto 模式：双栈环境优先获取 IPv4 (更适合大众网络)，纯 v6 环境自动fallback到 v6
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        # 如果获取 v4 失败，说明可能是纯 v6 机器，尝试获取 v6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    # 兜底处理：所有接口都失败时，直接输出 127.0.0.1，不报错
    echo "127.0.0.1" && return 0
}

REQUIRED_CMDS="curl tar sed grep awk openssl"
MISSING_CMDS=""

for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING_CMDS="$MISSING_CMDS $cmd"
    fi
done

if [ -n "$MISSING_CMDS" ]; then
    info "检测到系统缺失必要组件:${YELLOW}$MISSING_CMDS${RESET}，正在自动修复..."
    case "$OS" in
        ubuntu|debian)
            apt-get update -qy && apt-get install -y $MISSING_CMDS >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y $MISSING_CMDS >/dev/null 2>&1
            else
                yum install -y $MISSING_CMDS >/dev/null 2>&1
            fi
            ;;
        *)
            die "未知系统，请手动安装组件: $MISSING_CMDS"
            ;;
    esac

    for cmd in $MISSING_CMDS; do
        if ! command -v "$cmd" &> /dev/null; then
            die "自动安装 [ $cmd ] 失败，请检查网络源。"
        fi
    done
    ok "基础依赖补全成功！"
fi

# ── 💡 代理轮询核心函数 ───────────────────────────────────────────────────
# 遍历代理列表，寻找首个对 github.com 握手成功的可用代理
select_available_proxy() {
    info "正在为您筛选可用的 GitHub 加速代理..."
    for proxy in "${GITHUB_PROXIES[@]}"; do
        if [ -z "$proxy" ]; then
            # 测试直连
            if curl -I --connect-timeout 3 -m 5 "https://github.com" &>/dev/null; then
                export SELECTED_PROXY=""
                ok "检测到当前网络可以直连 GitHub，将优先使用原生链接。"
                return 0
            fi
        else
            # 测试代理节点
            if curl -I --connect-timeout 3 -m 5 "${proxy}https://github.com" &>/dev/null; then
                export SELECTED_PROXY="$proxy"
                ok "成功匹配加速代理: ${YELLOW}${proxy}${RESET}"
                return 0
            fi
        fi
    done
    warn "所有 GitHub 代理和直连均不可用，将尝试使用直连盲跑..."
    export SELECTED_PROXY=""
}

# ── 1. 核心下载与组件解压 ───────────────────────────────────────────────────
detect_target() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  TARGET="x86_64-unknown-linux-musl" ;;
        aarch64) TARGET="aarch64-unknown-linux-musl" ;;
        *) die "暂不支持的系统架构: $ARCH (面板目前仅支持 x86_64 及 aarch64)" ;;
    esac
}

fetch_latest_version() {
    info "正在通过代理列表轮询获取最新 Release 版本号..."
    VERSION=""

    # 1. 核心轮询逻辑：一个一个代理去撞，直到拿到真实的版本号
    for proxy in "${GITHUB_PROXIES[@]}"; do
        local api_url="${proxy}https://api.github.com/repos/${REPO}/releases/latest"
        
        # 调试信息，方便看清当前在用哪个代理跑
        if [ -z "$proxy" ]; then
            info "尝试直连请求 GitHub API..."
        else
            info "尝试使用代理: ${YELLOW}${proxy}${RESET}"
        fi

        # 使用 wget 获取并通过 sed/awk 解析 tag_name (避免系统没装 jq)
        local resp
        resp=$(wget -qO- --timeout=5 --tries=1 --no-check-certificate "$api_url" 2>/dev/null)
        local tmp_ver
        tmp_ver=$(echo "$resp" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)

        # 校验获取到的版本号是否合法
        if [[ -n "$tmp_ver" && "$tmp_ver" != "null" ]]; then
            VERSION="$tmp_ver"
            SELECTED_PROXY="$proxy" # 锁定当前好用的代理，供后面下载资产包使用
            ok "成功通过该源获取到最新版本: ${GREEN}${VERSION}${RESET}"
            break
        fi
    done

    # 2. 兜底逻辑：如果全军覆没，使用稳定的保底版本
    if [ -z "$VERSION" ]; then
        VERSION="v0.4.0"
        SELECTED_PROXY="" # 盲跑直连
        warn "所有代理均未能获取到实时版本，将降级采用默认稳定版本: ${VERSION}"
    fi

    export VERSION
    export SELECTED_PROXY
    
    [ -d "$CONF_DIR" ] || install -m 0755 -d "$CONF_DIR"
    echo "$VERSION" > "${CONF_DIR}/.version" 2>/dev/null
}

download_and_extract() {
    detect_target
    fetch_latest_version
    info "正在匹配系统环境形态: ${YELLOW}${TARGET}${RESET}"

    ASSET="next-socks5-${TARGET}.tar.gz"
    # 拼接代理源
    URL_TGZ="${SELECTED_PROXY}https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    info "开始同步下载资产包..."
    info "下载地址: ${CYAN}${URL_TGZ}${RESET}"
    curl -fsSL --connect-timeout 10 -o "$TMP/$ASSET" "$URL_TGZ" || die "下载资产包失败！请重试或更换代理列表。"

    tar xzf "$TMP/$ASSET" -C "$TMP"
    EXTRACTED_BIN=$(find "$TMP" -type f -name "next-socks5" | head -n 1)
    [ -n "$EXTRACTED_BIN" ] || die "解压成功，但在归档包内未找到 next-socks5 主程序！"
    export TARGET_BIN_PATH="$EXTRACTED_BIN"
}

# ── 2. TOML 配置文件生成器 ──────────────────────────────────────────────────
write_config() {
    local bind_ip="$1" local bind_port="$2" local username="$3" local password="$4"
    [ -d "$CONF_DIR" ] || install -m 0755 -d "$CONF_DIR"
    
    cat <<EOF > "$CONF_FILE"
listen = "${bind_ip}:${bind_port}"

[auth]
EOF

    if [ -n "$username" ] && [ -n "$password" ]; then
        cat <<EOF >> "$CONF_FILE"
method = "password"
[[auth.users]]
username = "${username}"
password = "${password}"
EOF
    else
        cat <<EOF >> "$CONF_FILE"
method = "none"
EOF
    fi

    cat <<EOF >> "$CONF_FILE"

[timeouts]
connect_ms = 10000
tcp_idle_ms = 300000
udp_idle_ms = 60000

[udp]
# port_range = "40000-40100"      # bind UDP relay sockets to this range
# advertise = "YOUR_PUBLIC_IP"    # advertised BND IP for clients behind NAT
EOF
}

write_systemd() {
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=next-socks5 - Fast and Lightweight SOCKS5 Server
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${DATA_DIR}
ExecStart=${INSTALL_BIN} serve --config ${CONF_FILE} --no-tui
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

# ── 节点配置总结报告 ──────────────────────────────────────────────────────────
print_node_summary() {
    if [ ! -f "$CONF_FILE" ]; then return; fi

    local bind_port
    bind_port=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); split($2, a, ":"); print a[length(a)]}' "$CONF_FILE")
    [ -z "$bind_port" ] && bind_port="16216"
    
    local auth_method
    auth_method=$(awk -F '=' '/^[[:space:]]*method[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$CONF_FILE")
    
    local auth_user="" local auth_pass=""
    if [ "$auth_method" = "password" ]; then
        auth_user=$(awk -F '=' '/^[[:space:]]*username[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$CONF_FILE")
        auth_pass=$(awk -F '=' '/^[[:space:]]*password[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$CONF_FILE")
    fi

    local public_ip
    public_ip=$(get_public_ip)

    echo -e "\n${GREEN}====== 当前配置详情 ======${RESET}"
    echo -e "${GREEN}IP地址       :${RESET} ${public_ip}"
    echo -e "${GREEN}端口         :${RESET} ${bind_port}"
    if [ -n "$auth_user" ]; then
        echo -e "${GREEN}用户名       :${RESET} ${auth_user}"
        echo -e "${GREEN}密码         :${RESET} ${auth_pass}"
    else
        echo -e "${GREEN}鉴权模式     :${RESET} ${YELLOW}无密码 (免密模式)${RESET}"
    fi
    echo -e "${GREEN}分享存放路径 :${RESET} ${CONF_FILE}"
    echo -e "${YELLOW}📄 V6VPS 请自行替换 IP 地址为 V6 ★${RESET}"
    
    echo -e "${GREEN}====== 👉 通用客户端 Socks5 链接 ======${RESET}"
    if [ -n "$auth_user" ]; then
        echo -e "${YELLOW}socks://${auth_user}:${auth_pass}@${public_ip}:${bind_port}#socks5${RESET}"
    else
        echo -e "${YELLOW}socks://${public_ip}:${bind_port}#uu-socks5${RESET}"
    fi
    
    echo -e "${GREEN}====== 🚀 Telegram 内置一键代理链接 ======${RESET}"
    if [ -n "$auth_user" ]; then
        echo -e "${YELLOW}https://t.me/socks?server=${public_ip}&port=${bind_port}&user=${auth_user}&pass=${auth_pass}${RESET}"
    else
        echo -e "${YELLOW}https://t.me/socks?server=${public_ip}&port=${bind_port}${RESET}"
    fi
    echo ""
}

# ── 3. 面板核心数据抓取 ───────────────────────────────────────────────────────
get_status_info() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        panel_status="${GREEN}运行中${RESET}"
    else
        panel_status="${RED}未运行${RESET}"
    fi

    if [ -f "$INSTALL_BIN" ]; then
        if [ -f "${CONF_DIR}/.version" ]; then
            panel_version=$(cat "${CONF_DIR}/.version")
        else
            local raw_ver
            raw_ver=$("$INSTALL_BIN" --version 2>/dev/null | grep -oE '[vV]?[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
            if [ -n "$raw_ver" ]; then
                panel_version="$raw_ver"
                echo "$raw_ver" > "${CONF_DIR}/.version" 2>/dev/null
            else
                panel_version="v0.4.0"
            fi
        fi
    else
        panel_version="${RED}未安装${RESET}"
    fi

    if [ -f "$CONF_FILE" ]; then
        panel_port=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$CONF_FILE")
    else
        panel_port="未设定"
    fi
}

menu_install() {
    if [ -f "$INSTALL_BIN" ]; then
        warn "系统中已存在安装好的实例文件。"
        read -r -p "$(echo -e "${GREEN}是否确定完全覆盖重新安装？[y/N]: ${RESET}")" res
        [[ "$res" =~ ^[Yy]$ ]] || return
    fi

    echo -e "\n${GREEN}==== [自定义安装配置] ====${RESET}"
    read -r -p "$(echo -e "${GREEN}请输入监听 IP 地址 [默认 ::]: ${RESET}")" input_ip
    local opt_ip="${input_ip:-::}"

    local rand_port=$((RANDOM % 50001 + 10000))
    read -r -p "$(echo -e "${GREEN}请输入 SOCKS5 监听端口 [回车默认随机端口: ${rand_port}]: ${RESET}")" input_port
    local opt_port="${input_port:-$rand_port}"
    if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [ "$opt_port" -le 0 ] || [ "$opt_port" -gt 65535 ]; then
        opt_port=$rand_port
    fi

    local rand_user="user_$(openssl rand -hex 4)"
    local rand_pass="$(openssl rand -hex 10)"
    local opt_user="" local opt_pass=""

    read -r -p "$(echo -e "${GREEN}请输入自定义用户名 [回车默认随机: ${YELLOW}${rand_user}${GREEN}, 输入 ${RED}none${GREEN} 选免密]: ${RESET}")" input_user
    if [ -z "$input_user" ]; then
        opt_user="$rand_user"
        read -r -p "$(echo -e "${GREEN}请输入自定义密码 [回车默认随机: ${YELLOW}${rand_pass}${GREEN}]: ${RESET}")" input_pass
        opt_pass="${input_pass:-$rand_pass}"
    elif [ "$input_user" = "none" ]; then
        opt_user=""
        opt_pass=""
    else
        opt_user="$input_user"
        read -r -p "$(echo -e "${GREEN}请输入自定义密码 [回车默认随机: ${YELLOW}${rand_pass}${GREEN}]: ${RESET}")" input_pass
        opt_pass="${input_pass:-$rand_pass}"
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

    info "正在拉起后台服务..."
    systemctl start "$SERVICE_NAME"
    
    local is_ok=1
    for i in {1..5}; do
        if systemctl is-active --quiet "$SERVICE_NAME"; then is_ok=0; break; fi
        sleep 1
    done

    if [ "$is_ok" -eq 0 ]; then
        ok "next-socks5 代理服务部署成功！"
        print_node_summary
    else
        warn "部署完成，但初始化响应异常，请稍后选择 [8] 查看实时日志。"
    fi
}

menu_update() {
    [ -f "$SERVICE_FILE" ] || die "未检测到系统服务，请先选择 [1] 进行完整安装。"
    download_and_extract
    systemctl stop "$SERVICE_NAME"
    install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$INSTALL_BIN"
    systemctl start "$SERVICE_NAME"
    ok "next-socks5 核心主程序已完成平滑更新。"
}

menu_uninstall() {
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$INSTALL_BIN" "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$CONF_DIR" "$DATA_DIR"
    userdel "$SERVICE_USER" >/dev/null 2>&1
    ok "next-socks5 核心组件及配置文件已全部安全卸载"
}

menu_edit_config() {
    [ -f "$CONF_FILE" ] || die "未发现任何配置文件，请先执行安装步骤。"
    
    local current_bind
    current_bind=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$CONF_FILE")
    local current_ip="${current_bind%%:*}" local current_port="${current_bind##*:}"
    
    local current_method
    current_method=$(awk -F '=' '/^[[:space:]]*method[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$CONF_FILE")
    
    local current_user="" local current_pass=""
    if [ "$current_method" = "password" ]; then
        current_user=$(awk -F '=' '/^[[:space:]]*username[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$CONF_FILE")
        current_pass=$(awk -F '=' '/^[[:space:]]*password[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$CONF_FILE")
    fi

    [ -z "$current_ip" ] && current_ip="::"
    [ -z "$current_port" ] && current_port="1080"

    echo -e "\n${GREEN}==== [修改内核参数配置] ====${RESET}"
    read -r -p "$(echo -e "${GREEN}请输入监听 IP 地址 [当前: ${current_ip}]: ${RESET}")" input_ip
    local opt_ip="${input_ip:-$current_ip}"

    local rand_port=$((RANDOM % 50001 + 10000))
    read -r -p "$(echo -e "${GREEN}请输入 SOCKS5 监听端口 [当前: ${current_port}, 回车保持原样, 输入 ${YELLOW}rand${GREEN} 随机重置]: ${RESET}")" input_port
    local opt_port="$current_port"
    if [ "$input_port" = "rand" ]; then
        opt_port="$rand_port"
    elif [ -n "$input_port" ]; then
        if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -gt 0 ] && [ "$input_port" -le 65535 ]; then
            opt_port="$input_port"
        fi
    fi

    local opt_user="" local opt_pass=""

    read -r -p "$(echo -e "${GREEN}请输入用户名 [当前: ${current_user:-无密码}, 输入 ${RED}none${GREEN} 彻底清除密码, 回车默认保持原样/不设置]: ${RESET}")" input_user
    
    if [ -z "$input_user" ]; then
        opt_user="$current_user"
        opt_pass="$current_pass"
    elif [ "$input_user" = "none" ]; then
        opt_user=""
        opt_pass=""
    else
        opt_user="$input_user"
        read -r -p "$(echo -e "${GREEN}请输入新密码 [当前: ${current_pass:-无密码}, 回车默认保持原样/不设置]: ${RESET}")" input_pass
        opt_pass="${input_pass:-$current_pass}"
    fi

    write_config "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl restart "$SERVICE_NAME"
        ok "配置已覆盖，全套代理服务已同步重启生效！"
        print_node_summary
    else
        ok "配置已成功重写更新。"
    fi
}

menu_show_node_config() {
    if [ ! -f "$CONF_FILE" ]; then 
        die "未检测到有效的服务配置文件，请先执行选择 [1] 进行完整安装。"
    fi

    print_node_summary

    local full_bind
    full_bind=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$CONF_FILE")
    local bind_ip="${full_bind%%:*}" local bind_port="${full_bind##*:}"
    local connect_ip="$bind_ip"
    if [ "$connect_ip" = "0.0.0.0" ]; then connect_ip="127.0.0.1"; fi

    local auth_method
    auth_method=$(awk -F '=' '/^[[:space:]]*method[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$CONF_FILE")
    
    local auth_user="" local auth_pass=""
    if [ "$auth_method" = "password" ]; then
        auth_user=$(awk -F '=' '/^[[:space:]]*username[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$CONF_FILE")
        auth_pass=$(awk -F '=' '/^[[:space:]]*password[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$CONF_FILE")
    fi

    local proxy_args="--socks5-hostname ${connect_ip}:${bind_port}"
    if [ -n "$auth_user" ] && [ -n "$auth_pass" ]; then
        proxy_args="--socks5-hostname ${auth_user}:${auth_pass}@${connect_ip}:${bind_port}"
    fi
}

# ── 4. 主循环控制中心 ─────────────────────────────────────────────────────────
while true; do
    get_status_info
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}        next-socks5 面板       ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $panel_status"
    echo -e "${GREEN}版本 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}绑定 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1. 安装 next-socks5${RESET}"
    echo -e "${GREEN} 2. 更新 next-socks5${RESET}"
    echo -e "${GREEN} 3. 卸载 next-socks5${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 next-socks5${RESET}"
    echo -e "${GREEN} 6. 停止 next-socks5${RESET}"
    echo -e "${GREEN} 7. 重启 next-socks5${RESET}"
    echo -e "${GREEN} 8. 查看日志${RESET}"
    echo -e "${GREEN} 9. 查看配置${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    
    read -r -p "$(echo -e "${GREEN}请输入选项: ${RESET}")" choice
    
    case "$choice" in
        1) menu_install ;;
        2) menu_update ;;
        3) menu_uninstall ;;
        4) menu_edit_config ;;
        5) systemctl start "$SERVICE_NAME" && ok "动作: 核心启动成功" ;;
        6) systemctl stop "$SERVICE_NAME" && ok "动作: 核心停止成功" ;;
        7) systemctl restart "$SERVICE_NAME" && ok "动作: 核心重启成功" ;;
        8) (trap 'echo -e "\n"' INT; journalctl -u "$SERVICE_NAME" -n 50 -f) ;;
        9) menu_show_node_config ;;
        0) clear; exit 0 ;;
        *) warn "未识别的无效序号！"; sleep 1 ;;
    esac
    
    read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键返回主控制面板...${RESET}")"
done
