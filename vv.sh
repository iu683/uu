#!/usr/bin/env bash

# =============================================================================
#  MicaProxy 智能编号多实例管理面板
# =============================================================================

# ── 核心路径与环境变量 ────────────────────────────────────────────────────────
export REPO="judy-gotv/Rust-SOCKS5-HTTP"
export TEMPLATE_NAME="micaproxy"
export BIN_PATH="/opt/MicaProxy/MicaProxy"
export INSTANCE_DIR="/etc/MicaProxy"         # 配置文件直接存放在 /etc/MicaProxy 下
export DATA_DIR="/var/lib/micaproxy"
export LOG_DIR="/opt/MicaProxy/log"
export SERVICE_FILE="/etc/systemd/system/${TEMPLATE_NAME}@.service"

# 当前控制的目标实例名称
CURRENT_INSTANCE="default"

# ── 终端颜色定义 ─────────────────────────────────────
export RESET='\033[0m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'

# GITHUB 代理加速源列表
GITHUB_PROXIES=(
    "" 
    "https://v6.gh-proxy.org/"
    "https://gh-proxy.com/"
    "https://hub.glowp.xyz/"
    "https://proxy.vvvv.ee/"
    "https://ghproxy.lvedong.eu.org/"
)

# ── 基础环境校验 ─────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[错误]${RESET} 请使用 root 权限运行此脚本！" >&2
    exit 1
fi

info() { echo -e "${BLUE}[INFO]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
die()  { echo -e "${RED}[ERROR]${RESET} $1" >&2; exit 1; }

# 依赖检查与自动补全
REQUIRED_CMDS="curl tar sed grep awk openssl wget"
MISSING_CMDS=""
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" &> /dev/null; then MISSING_CMDS="$MISSING_CMDS $cmd"; fi
done

if [ -n "$MISSING_CMDS" ]; then
    info "检测到系统缺失必要组件:${YELLOW}$MISSING_CMDS${RESET}，正在自动安装..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian) apt-get update -qy && apt-get install -y $MISSING_CMDS >/dev/null 2>&1 ;;
            centos|rhel|rocky|almalinux|fedora)
                if command -v dnf &>/dev/null; then dnf install -y $MISSING_CMDS >/dev/null 2>&1
                else yum install -y $MISSING_CMDS >/dev/null 2>&1; fi ;;
            *) die "未知系统，请手动安装组件: $MISSING_CMDS" ;;
        esac
    fi
    ok "基础依赖补全成功！"
fi

get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
        ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
    done
    echo "127.0.0.1"
}

# ── 1. 核心编译资产下载 ────────────────────────────────────────────────────────
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

# ── 2. 核心 Systemd 模板写入 ──────────────────────────────────────────────────
write_template_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MicaProxy instance %i  (SOCKS5 / SOCKS5 UDP / HTTP / HTTPS)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -c ${INSTANCE_DIR}/%i.toml
Restart=on-failure
RestartSec=2s
LimitNOFILE=65535

# 安全沙箱
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=no
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
ReadWritePaths=${LOG_DIR}
ReadOnlyPaths=${BIN_PATH} ${INSTANCE_DIR}/

AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$SERVICE_FILE"
    systemctl daemon-reload
}

# ── 3. 配置生成与环境初始化 ──────────────────────────────────────────────────
init_environment() {
    install -m 0755 -d /opt/MicaProxy
    install -m 0755 -d "$LOG_DIR"
    install -m 0755 -d "$INSTANCE_DIR"
    install -m 0755 -d "$DATA_DIR"
}

write_config() {
    local instance="$1" local proto="$2" local bind_ip="$3" local bind_port="$4" local username="$5" local password="$6"
    local conf_file="${INSTANCE_DIR}/${instance}.toml"
    
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
    chmod 0644 "$conf_file"
}

# ── 🎯 核心增强点：集成 Telegram 一键分享链接 ───────────────────────────────────
print_node_summary() {
    local instance="$1"
    local conf_file="${INSTANCE_DIR}/${instance}.toml"
    if [ ! -f "$conf_file" ]; then return; fi

    local proto
    proto=$(awk -F '=' '/^[[:space:]]*protocol[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
    [ -z "$proto" ] && proto="socks5"

    local bind_port
    bind_port=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); split($2, a, ":"); print a[length(a)]}' "$conf_file")
    
    local auth_user
    auth_user=$(awk -F '=' '/^[[:space:]]*username[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")
    local auth_pass
    auth_pass=$(awk -F '=' '/^[[:space:]]*password[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")

    local public_ip
    public_ip=$(get_public_ip)

    echo -e "\n${GREEN}====== MicaProxy 实例 [ ${instance} ] 配置详情 ======${RESET}"
    echo -e "${GREEN}实例协议     :${RESET} ${CYAN}${proto^^}${RESET}"
    echo -e "${GREEN}外网绑定 IP  :${RESET} ${public_ip}"
    echo -e "${GREEN}监听端口     :${RESET} ${bind_port}"
    if [ -n "$auth_user" ]; then
        echo -e "${GREEN}用户名       :${RESET} ${auth_user}"
        echo -e "${GREEN}密码         :${RESET} ${auth_pass}"
    else
        echo -e "${GREEN}鉴权模式     :${RESET} ${YELLOW}免密模式${RESET}"
    fi
    echo -e "${GREEN}配置文件路径 :${RESET} ${conf_file}"
    
    echo -e "${GREEN}====== 👉 客户端通用格式连接 ======${RESET}"
    if [ "$proto" = "socks5" ]; then
        if [ -n "$auth_user" ]; then
            echo -e "${YELLOW}socks5://${auth_user}:${auth_pass}@${public_ip}:${bind_port}#${instance}${RESET}"
            echo -e "\n${GREEN}====== 🚀 Telegram 内置一键代理链接 ======${RESET}"
            echo -e "${CYAN}https://t.me/socks?server=${public_ip}&port=${bind_port}&user=${auth_user}&pass=${auth_pass}${RESET}"
        else
            echo -e "${YELLOW}socks5://${public_ip}:${bind_port}#${instance}${RESET}"
            echo -e "\n${GREEN}====== 🚀 Telegram 内置一键代理链接 ======${RESET}"
            echo -e "${CYAN}https://t.me/socks?server=${public_ip}&port=${bind_port}${RESET}"
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

# ── 面板基础数据提取 ──────────────────────────────────────────────────────────
get_status_info() {
    if systemctl is-active --quiet "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"; then
        panel_status="${GREEN}活跃中 (Running)${RESET}"
    else
        panel_status="${RED}未运行 (Stopped)${RESET}"
    fi

    if [ -f "$BIN_PATH" ]; then
        panel_version="已就绪 (沙箱防御生效中)"
    else
        panel_version="${RED}未下载核心${RESET}"
    fi

    local conf_file="${INSTANCE_DIR}/${CURRENT_INSTANCE}.toml"
    if [ -f "$conf_file" ]; then
        local proto
        proto=$(awk -F '=' '/^[[:space:]]*protocol[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
        local p_num=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
        panel_port="${p_num} (${proto^^})"
    else
        panel_port="未创建配置"
    fi
}

menu_switch_instance() {
    echo -e "\n${GREEN}==== [多开实例矩阵管理中心] ====${RESET}"
    echo -e "当前聚焦的操作目标: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo "目前存储于 ${INSTANCE_DIR} 内的独立实例列表:"

    local files=("${INSTANCE_DIR}"/*.toml)
    local instance_list=()
    local count=0

    if [ -e "${files[0]}" ]; then
        for f in "${files[@]}"; do
            ((count++))
            local name=$(basename "$f" .toml)
            instance_list+=("$name")
            
            local proto_type=$(awk -F '=' '/^[[:space:]]*protocol[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$f")
            local status_str="${RED}已挂起${RESET}"
            systemctl is-active --quiet "${TEMPLATE_NAME}@${name}" && status_str="${GREEN}分流中${RESET}"
            
            echo -e " [ ${CYAN}${count}${RESET} ] -> ${YELLOW}${name}${RESET} [协议: ${proto_type^^} | 状态: ${status_str}]"
        done
    else
        echo " (暂无任何多开实例，请直接输入新名称创建)"
    fi
    echo ""
    echo -e "👉 ${GREEN}输入现有实例前面的【数字编号】快速切换切换${RESET}"
    echo -e "👉 ${GREEN}或者直接输入一个【全新的英文名字】来新建多开实例${RESET}"
    read -r -p "请输入选择或名字: " input_val

    if [ -z "$input_val" ]; then
        return
    fi

    if [[ "$input_val" =~ ^[0-9]+$ ]]; then
        if [ "$input_val" -gt 0 ] && [ "$input_val" -le "$count" ]; then
            local index=$((input_val - 1))
            CURRENT_INSTANCE="${instance_list[$index]}"
            ok "操作焦点已成功切为编号 [ ${input_val} ] 的实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
        else
            warn "编号输入超出范围！未做任何变更。"
        fi
    else
        CURRENT_INSTANCE="$input_val"
        ok "检测到全新实例名称，已将焦点锁定在: ${YELLOW}${CURRENT_INSTANCE}${RESET} (请去主菜单按 1 创建它)"
    fi
}

menu_install() {
    init_environment
    local conf_file="${INSTANCE_DIR}/${CURRENT_INSTANCE}.toml"
    if [ -f "$conf_file" ]; then
        warn "实例 [ ${CURRENT_INSTANCE} ] 已经存在对应配置文件。"
        read -r -p "$(echo -e "${GREEN}是否确定完全覆盖重写该实例？[y/N]: ${RESET}")" res
        [[ "$res" =~ ^[Yy]$ ]] || return
    fi

    echo -e "\n${GREEN}==== [配置新实例 ${CURRENT_INSTANCE} 参数] ====${RESET}"
    echo "1. SOCKS5 代理模式 (默认，附带完整 UDP 转发能力)"
    echo "2. HTTP 传输代理模式"
    read -r -p "选择形态序号 [1-2]: " proto_choice
    local opt_proto="socks5"
    if [ "$proto_choice" = "2" ]; then opt_proto="http"; fi

    read -r -p "$(echo -e "${GREEN}请输入监听网卡 IP [回车默认 0.0.0.0]: ${RESET}")" input_ip
    local opt_ip="${input_ip:-0.0.0.0}"

    local rand_port=$((RANDOM % 50001 + 10000))
    read -r -p "$(echo -e "${GREEN}请输入服务端口 [回车分配随机端口 ${rand_port}]: ${RESET}")" input_port
    local opt_port="${input_port:-$rand_port}"
    
    local rand_user="mica_$(openssl rand -hex 3)"
    local rand_pass="$(openssl rand -hex 8)"
    local opt_user="" local opt_pass=""

    read -r -p "$(echo -e "${GREEN}配置连接账户 [回车默认随机，输入 ${RED}none${GREEN} 选免密开放]: ${RESET}")" input_user
    if [ -z "$input_user" ]; then
        opt_user="$rand_user"
        read -r -p "$(echo -e "${GREEN}配置专属密码 [回车分配随机: ${YELLOW}${rand_pass}${GREEN}]: ${RESET}")" input_pass
        opt_pass="${input_pass:-$rand_pass}"
    elif [ "$input_user" = "none" ]; then
        opt_user="" ; opt_pass=""
    else
        opt_user="$input_user"
        read -r -p "$(echo -e "${GREEN}请输入指定密码: ${RESET}")" input_pass
        opt_pass="${input_pass:-$rand_pass}"
    fi

    if [ ! -f "$BIN_PATH" ]; then
        download_bin
        install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$BIN_PATH"
    fi

    write_config "$CURRENT_INSTANCE" "$opt_proto" "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    write_template_service

    info "正在拉起沙箱隔离实例: ${CURRENT_INSTANCE} ..."
    systemctl enable "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" >/dev/null 2>&1
    systemctl restart "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"
    
    sleep 1.5
    if systemctl is-active --quiet "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"; then
        ok "MicaProxy 多实例矩阵 [ ${CURRENT_INSTANCE} ] 成功拉起且未触碰沙箱警报！"
        print_node_summary "$CURRENT_INSTANCE"
    else
        warn "实例成功部署，但触发了本地未知阻断，请按 [8] 抓取内核滚动日志。"
    fi
}

menu_uninstall() {
    warn "该操作将直接销毁当前选定的实例及其所占用的端口。"
    read -r -p "$(echo -e "${RED}确认抹除实例 [ ${CURRENT_INSTANCE} ] 吗？[y/N]: ${RESET}")" res
    [[ "$res" =~ ^[Yy]$ ]] || return

    systemctl stop "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    systemctl disable "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    rm -f "${INSTANCE_DIR}/${CURRENT_INSTANCE}.toml"
    ok "实例 [ ${CURRENT_INSTANCE} ] 已干净销毁。"

    local files=("${INSTANCE_DIR}"/*.toml)
    if [ ! -e "${files[0]}" ]; then
        info "所有实例均已排空，执行全局组件回收卸载..."
        systemctl stop "${TEMPLATE_NAME}@*" >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE" "$BIN_PATH"
        rm -rf "/opt/MicaProxy" "$DATA_DIR"
        systemctl daemon-reload
        ok "全局所有核心组件、沙箱配置已彻底卸载！"
        CURRENT_INSTANCE="default"
    fi
}

# ── 4. 控制中心核心无限循环 ──────────────────────────────────────────────────
while true; do
    get_status_info
    clear
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN} ◈ MicaProxy SOCKS5/HTTP 多实例管理面板 ◈  ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}当前控制目标 :${RESET} ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}目标实例绑定 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}服务活跃状态 :${RESET} $panel_status"
    echo -e "${GREEN}核心沙箱引擎 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN} 1. 安装 当前控制实例${RESET}"
    echo -e "${GREEN} 2. 更新 当前控制实例${RESET}"
    echo -e "${GREEN} 3. 卸载 当前控制实例${RESET}"
    echo -e "${GREEN} 5. 启动 当前控制实例${RESET}"
    echo -e "${GREEN} 6. 停止 当前控制实例${RESET}"
    echo -e "${GREEN} 7. 重启 当前控制实例${RESET}"
    echo -e "${GREEN} 8. 查看当前实例日志${RESET}"
    echo -e "${GREEN} 9. 查看当前实例配置${RESET}"
    echo -e "${YELLOW}10. ⚡ 切换实例名字/多开新建不限数量的代理${RESET}"
    echo -e "${GREEN} 0. 退出控制面板${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    
    read -r -p "$(echo -e "${GREEN}选择操作序号: ${RESET}")" choice
    case "$choice" in
        1) menu_install ;;
        2) download_bin && install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$BIN_PATH" && ok "核心覆盖成功" ;;
        3) menu_uninstall ;;
        5) systemctl start "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" && ok "拉起成功" ;;
        6) systemctl stop "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" && ok "挂起成功" ;;
        7) systemctl restart "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" && ok "重启完毕" ;;
        8) (trap 'echo -e "\n"' INT; journalctl -u "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" -n 50 -f) ;;
        9) print_node_summary "$CURRENT_INSTANCE" ;;
        10) menu_switch_instance ;;
        0) clear; exit 0 ;;
        *) warn "无效输入！"; sleep 1 ;;
    esac
    read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键重新返回控制台面...${RESET}")"
done
