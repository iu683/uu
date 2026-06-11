#!/usr/bin/env bash

# ==============================================================================
#  MicaProxy 进阶实例化安全一键管理面板 (支持 HTTP / SOCKS5 双协议)
# ==============================================================================

# ── 核心环境变量 ──────────────────────────────────────────────────────────────
export REPO="judy-gotv/Rust-SOCKS5-HTTP"
export TEMPLATE_NAME="micaproxy"
export SERVICE_USER="micaproxy"
export SERVICE_GROUP="micaproxy"
export INSTALL_BIN="/opt/MicaProxy/MicaProxy"
export BASE_CONF_DIR="/etc/MicaProxy/instances"
export DATA_DIR="/var/lib/micaproxy"
export LOG_DIR="/opt/MicaProxy/log"
export SERVICE_FILE="/etc/systemd/system/${TEMPLATE_NAME}@.service"

# 当前操作的默认实例名
CURRENT_INSTANCE="default"

# ── 终端颜色定义 ──────────────────────────────────
export RESET='\033[0m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'

# ── GITHUB 代理加速源列表 ─────────────────────────
GITHUB_PROXIES=(
    "" 
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
    local mode=${1:-"v4"}
    local ip=""
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
}

# 依赖检查与自动补全
REQUIRED_CMDS="curl tar sed grep awk openssl wget"
MISSING_CMDS=""
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" &> /dev/null; then MISSING_CMDS="$MISSING_CMDS $cmd"; fi
done

if [ -n "$MISSING_CMDS" ]; then
    info "检测到系统缺失必要组件:${YELLOW}$MISSING_CMDS${RESET}，正在自动修复..."
    case "$OS" in
        ubuntu|debian) apt-get update -qy && apt-get install -y $MISSING_CMDS >/dev/null 2>&1 ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then dnf install -y $MISSING_CMDS >/dev/null 2>&1
            else yum install -y $MISSING_CMDS >/dev/null 2>&1; fi ;;
        *) die "未知系统，请手动安装组件: $MISSING_CMDS" ;;
    esac
    ok "基础依赖补全成功！"
fi

# ── 💡 代理轮询获取最新核心 ───────────────────────────────────────────────
detect_target() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  TARGET="micaproxy-linux-amd64" ;;
        aarch64) TARGET="micaproxy-linux-arm64" ;;
        armv7l)  TARGET="micaproxy-linux-armv7" ;;
        *) die "暂不支持的系统架构: $ARCH" ;;
    esac
}

fetch_latest_version() {
    info "正在轮询获取 MicaProxy 最新 Release 版本号..."
    VERSION=""
    for proxy in "${GITHUB_PROXIES[@]}"; do
        local api_url="${proxy}https://api.github.com/repos/${REPO}/releases/latest"
        local resp
        resp=$(wget -qO- --timeout=5 --tries=1 --no-check-certificate "$api_url" 2>/dev/null)
        local tmp_ver
        tmp_ver=$(echo "$resp" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
        if [[ -n "$tmp_ver" && "$tmp_ver" != "null" ]]; then
            VERSION="$tmp_ver"
            SELECTED_PROXY="$proxy"
            ok "成功获取到最新版本: ${GREEN}${VERSION}${RESET}"
            break
        fi
    done
    if [ -z "$VERSION" ]; then
        VERSION="v3.0.6"
        SELECTED_PROXY=""
        warn "降级采用稳定默认版本: ${VERSION}"
    fi
    export VERSION; export SELECTED_PROXY
}

download_bin() {
    detect_target
    fetch_latest_version
    URL_BIN="${SELECTED_PROXY}https://github.com/${REPO}/releases/download/${VERSION}/${TARGET}"
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT

    info "开始同步下载资产包..."
    info "下载地址: ${CYAN}${URL_BIN}${RESET}"
    curl -fsSL --connect-timeout 10 -o "$TMP_DIR/MicaProxy" "$URL_BIN" || die "下载 MicaProxy 核心失败！"
    export TARGET_BIN_PATH="$TMP_DIR/MicaProxy"
}

# ── 2. 安全环境初始化与隔离硬化级配置写入 ──────────────────────────────────────────
init_security_environment() {
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        groupadd "$SERVICE_GROUP" 2>/dev/null || true
        useradd --system -g "$SERVICE_GROUP" --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER" 2>/dev/null \
          || adduser --system --ingroup "$SERVICE_GROUP" --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    fi
    install -m 0755 -d /opt/MicaProxy
    install -m 0750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" -d "$LOG_DIR"
    install -m 0755 -d "$BASE_CONF_DIR"
    install -m 0750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" -d "$DATA_DIR"
}

write_config() {
    local instance="$1" local proto="$2" local bind_ip="$3" local bind_port="$4" local username="$5" local password="$6"
    local conf_file="${BASE_CONF_DIR}/${instance}.toml"
    
    cat <<EOF > "$conf_file"
[[outbounds]]
name = "default"
type = "default"

[[listeners]]
name = "${instance}-listener"
listen = "${bind_ip}:${bind_port}"
protocol = "${proto}"
outbound = "default"
EOF

    if [ -n "$username" ] && [ -n "$password" ]; then
        cat <<EOF >> "$conf_file"
username = "${username}"
password = "${password}"
EOF
    fi

    # 如果是 socks5，额外补全 UDP 支持结构
    if [ "$proto" = "socks5" ]; then
        cat <<EOF >> "$conf_file"

[socks5]
enabled = true
udp_enabled = true
udp_idle_timeout_secs = 120
udp_buffer_bytes = 8192
EOF
    fi

    cat <<EOF >> "$conf_file"

[runtime]
driver = "epoll"
EOF
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "$conf_file"
    chmod 0640 "$conf_file"
}

write_hardened_systemd() {
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=MicaProxy Service instance %%i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${DATA_DIR}
ExecStart=${INSTALL_BIN} -c ${BASE_CONF_DIR}/%%i.toml
Restart=on-failure
RestartSec=2s
LimitNOFILE=65535

# ==== 沙盒安全硬化控制 ====
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes

# 路径沙盒可见性控制
ReadWritePaths=${LOG_DIR} ${DATA_DIR}
ReadOnlyPaths=${INSTALL_BIN} ${BASE_CONF_DIR}/%%i.toml

# 网络绑定最小特权集声明
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ── 节点配置总结报告 ──────────────────────────────────────────────────────────
print_node_summary() {
    local instance="$1"
    local conf_file="${BASE_CONF_DIR}/${instance}.toml"
    if [ ! -f "$conf_file" ]; then return; fi

    local proto
    proto=$(awk -F '=' '/^[[:space:]]*protocol[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
    [ -z "$proto" ] && proto="socks5"

    local bind_port
    bind_port=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); split($2, a, ":"); print a[length(a)]}' "$conf_file")
    [ -z "$bind_port" ] && bind_port="1080"
    
    local auth_user
    auth_user=$(awk -F '=' '/^[[:space:]]*username[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")
    local auth_pass
    auth_pass=$(awk -F '=' '/^[[:space:]]*password[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")

    local public_ip
    public_ip=$(get_public_ip)

    echo -e "\n${GREEN}====== MicaProxy 实例 [ ${instance} ] 配置详情 ======${RESET}"
    echo -e "${GREEN}实例协议     :${RESET} ${CYAN}${proto^^}${RESET}"
    echo -e "${GREEN}IP地址       :${RESET} ${public_ip}"
    echo -e "${GREEN}端口         :${RESET} ${bind_port}"
    if [ -n "$auth_user" ]; then
        echo -e "${GREEN}用户名       :${RESET} ${auth_user}"
        echo -e "${GREEN}密码         :${RESET} ${auth_pass}"
    else
        echo -e "${GREEN}鉴权模式     :${RESET} ${YELLOW}无密码 (免密模式)${RESET}"
    fi
    echo -e "${GREEN}配置文件路径 :${RESET} ${conf_file}"
    
    echo -e "${GREEN}====== 👉 通用客户端连接链接 ======${RESET}"
    if [ "$proto" = "socks5" ]; then
        if [ -n "$auth_user" ]; then
            echo -e "${YELLOW}socks5://${auth_user}:${auth_pass}@${public_ip}:${bind_port}#${instance}${RESET}"
        else
            echo -e "${YELLOW}socks5://${public_ip}:${bind_port}#${instance}${RESET}"
        fi
        echo -e "${GREEN}====== 🚀 Telegram 内置一键代理链接 ======${RESET}"
        if [ -n "$auth_user" ]; then
            echo -e "${YELLOW}https://t.me/socks?server=${public_ip}&port=${bind_port}&user=${auth_user}&pass=${auth_pass}${RESET}"
        else
            echo -e "${YELLOW}https://t.me/socks?server=${public_ip}&port=${bind_port}${RESET}"
        fi
    elif [ "$proto" = "http" ]; then
        if [ -n "$auth_user" ]; then
            echo -e "${YELLOW}http://${auth_user}:${auth_pass}@${public_ip}:${bind_port}${RESET}"
        else
            echo -e "${YELLOW}http://${public_ip}:${bind_port}${RESET}"
        fi
    fi
    echo ""
}

# ── 面板核心数据状态提取 ───────────────────────────────────────────────────────
get_status_info() {
    if systemctl is-active --quiet "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"; then
        panel_status="${GREEN}运行中${RESET}"
    else
        panel_status="${RED}未运行${RESET}"
    fi

    if [ -f "$INSTALL_BIN" ]; then
        panel_version="已加载 (v3.0.6+ 适用)"
    else
        panel_version="${RED}未安装核心${RESET}"
    fi

    local conf_file="${BASE_CONF_DIR}/${CURRENT_INSTANCE}.toml"
    if [ -f "$conf_file" ]; then
        local proto
        proto=$(awk -F '=' '/^[[:space:]]*protocol[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
        local p_num=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
        panel_port="${p_num} (${proto^^})"
    else
        panel_port="未建立配置"
    fi
}

menu_switch_instance() {
    echo -e "\n${GREEN}==== [切换/管理不同多开实例] ====${RESET}"
    echo "当前正在操作的实例名: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo "系统已存在的实例列表:"
    local files=("$BASE_CONF_DIR"/*.toml)
    if [ -e "${files[0]}" ]; then
        for f in "${files[@]}"; do
            local name=$(basename "$f" .toml)
            local proto_type=$(awk -F '=' '/^[[:space:]]*protocol[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$f")
            local status_str="${RED}已停止${RESET}"
            systemctl is-active --quiet "${TEMPLATE_NAME}@${name}" && status_str="${GREEN}活跃中${RESET}"
            echo -e " - ${CYAN}${name}${RESET} [协议: ${proto_type^^} | 状态: ${status_str}]"
        done
    else
        echo " (暂无任何多开实例，请去主菜单执行安装/新建)"
    fi
    echo ""
    read -r -p "请输入你想切换/新建的实例名称 (英文/数字): " input_name
    if [ -n "$input_name" ]; then
        CURRENT_INSTANCE="$input_name"
        ok "操作目标已切换为: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    fi
}

menu_install() {
    init_security_environment
    local conf_file="${BASE_CONF_DIR}/${CURRENT_INSTANCE}.toml"
    if [ -f "$conf_file" ]; then
        warn "实例 [ ${CURRENT_INSTANCE} ] 已有配置文件存在。"
        read -r -p "$(echo -e "${GREEN}是否确定完全覆盖重写该实例？[y/N]: ${RESET}")" res
        [[ "$res" =~ ^[Yy]$ ]] || return
    fi

    echo -e "\n${GREEN}==== [自定义实例 ${CURRENT_INSTANCE} 配置] ====${RESET}"
    
    # ── 新增协议选择 ──
    echo -e "${GREEN}请选择当前实例运行的协议类型:${RESET}"
    echo " 1. SOCKS5 代理 (支持 UDP 转发)"
    echo " 2. HTTP 代理 (普通网页转发)"
    read -r -p "请输入序号 [默认 1]: " proto_choice
    local opt_proto="socks5"
    if [ "$proto_choice" = "2" ]; then
        opt_proto="http"
    fi

    read -r -p "$(echo -e "${GREEN}请输入监听 IP 地址 [默认 0.0.0.0]: ${RESET}")" input_ip
    local opt_ip="${input_ip:-0.0.0.0}"

    local rand_port=$((RANDOM % 50001 + 10000))
    read -r -p "$(echo -e "${GREEN}请输入监听端口 [默认随机: ${rand_port}]: ${RESET}")" input_port
    local opt_port="${input_port:-$rand_port}"
    
    local rand_user="user_$(openssl rand -hex 4)"
    local rand_pass="$(openssl rand -hex 10)"
    local opt_user="" local opt_pass=""

    read -r -p "$(echo -e "${GREEN}请输入自定义用户名 [回车默认随机, 输入 ${RED}none${GREEN} 选免密]: ${RESET}")" input_user
    if [ -z "$input_user" ]; then
        opt_user="$rand_user"
        read -r -p "$(echo -e "${GREEN}请输入密码 [默认随机: ${YELLOW}${rand_pass}${GREEN}]: ${RESET}")" input_pass
        opt_pass="${input_pass:-$rand_pass}"
    elif [ "$input_user" = "none" ]; then
        opt_user="" ; opt_pass=""
    else
        opt_user="$input_user"
        read -r -p "$(echo -e "${GREEN}请输入密码 [默认随机: ${YELLOW}${rand_pass}${GREEN}]: ${RESET}")" input_pass
        opt_pass="${input_pass:-$rand_pass}"
    fi

    if [ ! -f "$INSTALL_BIN" ]; then
        download_bin
        install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$INSTALL_BIN"
    fi

    write_config "$CURRENT_INSTANCE" "$opt_proto" "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    write_hardened_systemd

    info "正在拉起安全实例: ${CURRENT_INSTANCE} (${opt_proto^^}) ..."
    systemctl enable "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" >/dev/null 2>&1
    systemctl start "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"
    
    local is_ok=1
    for i in {1..5}; do
        if systemctl is-active --quiet "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"; then is_ok=0; break; fi
        sleep 1
    done

    if [ "$is_ok" -eq 0 ]; then
        ok "MicaProxy 实例 [ ${CURRENT_INSTANCE} ] 部署成功，协议为 ${opt_proto^^}！"
        print_node_summary "$CURRENT_INSTANCE"
    else
        warn "实例部署完成，但沙盒启动异常，请通过 [8] 查看日志。"
    fi
}

menu_update() {
    [ -f "$INSTALL_BIN" ] || die "未安装核心，请先执行核心安装。"
    download_bin
    info "正在安全停止所有运行中的子实例..."
    systemctl stop "${TEMPLATE_NAME}@*" >/dev/null 2>&1 || true
    install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$INSTALL_BIN"
    info "正在重新拉起当前实例..."
    systemctl start "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    ok "MicaProxy 编译核心升级完毕！"
}

menu_uninstall() {
    warn "此操作将清除当前控制实例。"
    read -r -p "$(echo -e "${RED}确定销毁实例 [ ${CURRENT_INSTANCE} ] 吗？[y/N]: ${RESET}")" res
    [[ "$res" =~ ^[Yy]$ ]] || return

    systemctl stop "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    systemctl disable "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    rm -f "${BASE_CONF_DIR}/${CURRENT_INSTANCE}.toml"
    ok "实例 [ ${CURRENT_INSTANCE} ] 销毁成功。"

    local files=("$BASE_CONF_DIR"/*.toml)
    if [ ! -e "${files[0]}" ]; then
        info "检测到无任何存活实例，开始清理全局组件..."
        systemctl stop "${TEMPLATE_NAME}@*" >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE" "$INSTALL_BIN"
        rm -rf "/opt/MicaProxy" "$BASE_CONF_DIR" "$DATA_DIR"
        userdel "$SERVICE_USER" >/dev/null 2>&1 || true
        systemctl daemon-reload
        ok "全局 MicaProxy 组件已彻底干净卸载！"
        CURRENT_INSTANCE="default"
    fi
}

menu_edit_config() {
    local conf_file="${BASE_CONF_DIR}/${CURRENT_INSTANCE}.toml"
    [ -f "$conf_file" ] || die "当前实例未发现任何配置，请先执行新建。"
    
    local current_proto
    current_proto=$(awk -F '=' '/^[[:space:]]*protocol[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
    [ -z "$current_proto" ] && current_proto="socks5"

    local current_bind
    current_bind=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
    local current_ip="${current_bind%%:*}" local current_port="${current_bind##*:}"
    
    local current_user
    current_user=$(awk -F '=' '/^[[:space:]]*username[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")
    local current_pass
    current_pass=$(awk -F '=' '/^[[:space:]]*password[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")

    [ -z "$current_ip" ] && current_ip="0.0.0.0"
    [ -z "$current_port" ] && current_port="1080"

    echo -e "\n${GREEN}==== [修改实例 ${CURRENT_INSTANCE} 参数] ====${RESET}"
    
    echo -e "${GREEN}请选择变更后的协议类型 [当前: ${current_proto^^}]:${RESET}"
    echo " 1. SOCKS5 代理"
    echo " 2. HTTP 代理"
    read -r -p "请输入序号 (直接回车保持当前形态): " proto_choice
    local opt_proto="$current_proto"
    if [ "$proto_choice" = "1" ]; then opt_proto="socks5"; elif [ "$proto_choice" = "2" ]; then opt_proto="http"; fi

    read -r -p "$(echo -e "${GREEN}请输入监听 IP [当前: ${current_ip}]: ${RESET}")" input_ip
    local opt_ip="${input_ip:-$current_ip}"

    read -r -p "$(echo -e "${GREEN}请输入监听端口 [当前: ${current_port}, 输入 rand 随机]: ${RESET}")" input_port
    local opt_port="$current_port"
    if [ "$input_port" = "rand" ]; then opt_port=$((RANDOM % 50001 + 10000))
    elif [ -n "$input_port" ]; then opt_port="$input_port" ; fi

    local opt_user="" local opt_pass=""
    read -r -p "$(echo -e "${GREEN}请输入用户名 [当前: ${current_user:-无密码}, 输入 none 免密]: ${RESET}")" input_user
    if [ -z "$input_user" ]; then
        opt_user="$current_user" ; opt_pass="$current_pass"
    elif [ "$input_user" = "none" ]; then
        opt_user="" ; opt_pass=""
    else
        opt_user="$input_user"
        read -r -p "$(echo -e "${GREEN}请输入新密码: ${RESET}")" input_pass
        opt_pass="${input_pass:-$current_pass}"
    fi

    write_config "$CURRENT_INSTANCE" "$opt_proto" "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    if systemctl is-active --quiet "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"; then
        systemctl restart "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"
        ok "参数更新完成，沙盒实例已重启生效！"
        print_node_summary "$CURRENT_INSTANCE"
    else
        ok "配置已成功重写更新。"
    fi
}

# ── 4. 主循环控制中心 ─────────────────────────────────────────────────────────
while true; do
    get_status_info
    clear
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}     MicaProxy 安全双协议多实例面板        ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}操作目标实例 :${RESET} ${CYAN}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}当前实例绑定 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}实例运行状态 :${RESET} $panel_status"
    echo -e "${GREEN}编译核心状态 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN} 1. 新建/安装当前控制实例 (支持 HTTP/SOCKS5)${RESET}"
    echo -e "${GREEN} 2. 升级更新 MicaProxy 核心文件${RESET}"
    echo -e "${GREEN} 3. 销毁当前控制实例${RESET}"
    echo -e "${GREEN} 4. 修改当前实例配置 (可切协议)${RESET}"
    echo -e "${GREEN} 5. 启动当前实例${RESET}"
    echo -e "${GREEN} 6. 停止当前实例${RESET}"
    echo -e "${GREEN} 7. 重启当前实例${RESET}"
    echo -e "${GREEN} 8. 查看实例沙盒内核日志${RESET}"
    echo -e "${GREEN} 9. 导出当前实例分享链接/参数${RESET}"
    echo -e "${YELLOW} 10. ⚡ 切换实例/多开新建其他协议实例${RESET}"
    echo -e "${GREEN} 0. 安全退出${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    
    read -r -p "$(echo -e "${GREEN}请输入选项: ${RESET}")" choice
    
    case "$choice" in
        1) menu_install ;;
        2) menu_update ;;
        3) menu_uninstall ;;
        4) menu_edit_config ;;
        5) systemctl start "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" && ok "动作: 实例启动成功" ;;
        6) systemctl stop "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" && ok "动作: 实例安全挂起" ;;
        7) systemctl restart "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" && ok "动作: 实例同步重启" ;;
        8) (trap 'echo -e "\n"' INT; journalctl -u "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" -n 50 -f) ;;
        9) print_node_summary "$CURRENT_INSTANCE" ;;
        10) menu_switch_instance ;;
        0) clear; exit 0 ;;
        *) warn "未识别的无效序号！"; sleep 1 ;;
    esac
    
    read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键返回主控制面板...${RESET}")"
done
