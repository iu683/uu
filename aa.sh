#!/usr/bin/env bash

# =============================================================================
#  MicaProxy 多实例管理面板 
# =============================================================================

# ── 核心路径与环境变量 ────────────────────────────────────────────────────────
export REPO="judy-gotv/Rust-SOCKS5-HTTP"
export TEMPLATE_NAME="micaproxy"
export BIN_PATH="/opt/MicaProxy/MicaProxy"
export INSTANCE_DIR="/etc/MicaProxy"
export DATA_DIR="/var/lib/micaproxy"
export LOG_DIR="/opt/MicaProxy/log"
export SERVICE_FILE="/etc/systemd/system/${TEMPLATE_NAME}@.service"

# 默认控制的目标实例名称自动改成当前主机名
CURRENT_INSTANCE="$(hostname)"

# ── 终端颜色定义 ─────────────────────────────────────
export RESET='\033[0m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'

GITHUB_PROXIES=(
    ""
    "https://gh-proxy.com/"
    'https://ghfast.top/'
    "https://proxy.vvvv.ee/"
    "https://v6.gh-proxy.org/"
    "https://ghproxy.lvedong.eu.org/"
    "https://hub.glowp.xyz/"
)

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[错误] 请使用 root 权限运行此脚本！${RESET}" >&2
    exit 1
fi

info() { echo -e "${BLUE}[INFO]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
die()  { echo -e "${RED}[ERROR]${RESET} $1" >&2; exit 1; }

REQUIRED_CMDS="curl tar sed grep awk openssl wget"
MISSING_CMDS=""
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" &> /dev/null; then MISSING_CMDS="$MISSING_CMDS $cmd"; fi
done

if [ -n "$MISSING_CMDS" ]; then
    echo -e "${YELLOW}检测到系统缺失必要组件:${YELLOW}$MISSING_CMDS${RESET}，正在自动安装...${RESET}"
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
    echo -e "${YELLOW}基础依赖补全成功${RESET}"
fi

get_public_ip() {
    local mode=${1:-"auto"}
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
    echo "127.0.0.1"
}

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
    echo -e "${YELLOW}正在轮询获取 MicaProxy 最新 Release 版本号...${RESET}"
    VERSION=""
    for proxy in "${GITHUB_PROXIES[@]}"; do
        local api_url="${proxy}https://api.github.com/repos/${REPO}/releases/latest"
        local resp
        resp=$(wget -qO- --timeout=5 --tries=1 --no-check-certificate "$api_url" 2>/dev/null)
        local tmp_ver
        tmp_ver=$(echo "$resp" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
        if [[ -n "$tmp_ver" && "$tmp_ver" != "null" ]]; then
            VERSION="$tmp_ver"
            echo -e "${YELLOW}成功获取到最新版本: ${GREEN}${VERSION}${RESET}"
            break
        fi
    done
    if [ -z "$VERSION" ]; then
        VERSION="v3.0.6"
        echo -e "${YELLOW}降级采用稳定默认版本: ${VERSION}"
    fi
}

download_bin() {
    detect_target
    fetch_latest_version
    TMP_DIR="$(mktemp -d)"
    local download_success=false
    
    for proxy in "${GITHUB_PROXIES[@]}"; do
        local url_bin="${proxy}https://github.com/${REPO}/releases/download/${VERSION}/${TARGET}"
        echo -e "${YELLOW}正在尝试通过镜像源 [ ${CYAN}${proxy:-官方直连}${RESET} ] ${YELLOW}下载资产包...${RESET}"
        if curl -fsSL --connect-timeout 8 --max-time 60 -o "$TMP_DIR/MicaProxy" "$url_bin"; then
            if [ -s "$TMP_DIR/MicaProxy" ]; then
                download_success=true
                echo -e "${YELLOW}核心包同步下载完成！${RESET}"
                break
            fi
        fi
        echo -e "${YELLOW}当前源下载失败或连接超时，正在为您自动切换下一个备用源...${RESET}"
    done

    if [ "$download_success" = "false" ]; then
        rm -rf "$TMP_DIR"
        die "所有 GitHub 镜像代理源及官方通道均尝试失败，请检查网络后重试！"
    fi
    export TARGET_BIN_PATH="$TMP_DIR/MicaProxy"
}

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

init_environment() {
    install -m 0755 -d /opt/MicaProxy
    install -m 0755 -d "$LOG_DIR"
    install -m 0755 -d "$INSTANCE_DIR"
    install -m 0755 -d "$DATA_DIR"
}

write_config() {
    local instance="$1" local proto="$2" local bind_ip="$3" local bind_port="$4" local username="$5" local password="$6" local outbound_type="$7"
    local conf_file="${INSTANCE_DIR}/${instance}.toml"
    
    if [[ "$bind_ip" == *":"* ]] && [[ "$bind_ip" != *"["* ]]; then
        bind_ip="[${bind_ip}]"
    fi

    [ -z "$outbound_type" ] && outbound_type="default"

    cat <<EOF > "$conf_file"
[[outbounds]]
name = "${outbound_type}-outbound"
type = "${outbound_type}"

[[listeners]]
name = "${instance}-listener"
listen = "${bind_ip}:${bind_port}"
protocol = "${proto}"
outbound = "${outbound_type}-outbound"
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
    display_ip="$public_ip"; [[ "$public_ip" =~ ":" ]] && display_ip="[$public_ip]"

    echo -e "\n${GREEN}====== MicaProxy 实例${RESET} ${YELLOW}[ ${instance} ]${RESET} ${GREEN}配置详情 ======${RESET}"
    echo -e "${GREEN}实例协议     :${RESET} ${YELLOW}${proto^^}${RESET}"
    echo -e "${GREEN}外网绑定 IP  :${RESET} ${public_ip}"
    echo -e "${GREEN}监听端口     :${RESET} ${bind_port}"
    if [ -n "$auth_user" ]; then
        echo -e "${GREEN}用户名       :${RESET} ${auth_user}"
        echo -e "${GREEN}密码         :${RESET} ${auth_pass}"
    else
        echo -e "${GREEN}鉴权模式     :${RESET} ${YELLOW}免密模式${RESET}"
    fi
    echo -e "${GREEN}配置文件路径 :${RESET} ${conf_file}"
    echo -e "${GREEN}--------------------------------------------${RESET}"
    
    echo -e "${GREEN}====== 👉 客户端通用格式连接 ======${RESET}"
    if [ "$proto" = "socks5" ]; then
        if [ -n "$auth_user" ]; then
            echo -e "${YELLOW}socks5://${auth_user}:${auth_pass}@${public_ip}:${bind_port}#${instance}${RESET}"
            echo -e "\n${GREEN}====== 🚀 Telegram 内置一键代理链接 ======${RESET}"
            echo -e "${YELLOW}https://t.me/socks?server=${public_ip}&port=${bind_port}&user=${auth_user}&pass=${auth_pass}${RESET}"
        else
            echo -e "${YELLOW}socks5://${public_ip}:${bind_port}#${instance}${RESET}"
            echo -e "\n${GREEN}====== 🚀 Telegram 内置一键代理链接 ======${RESET}"
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

get_status_info() {
    if systemctl is-active --quiet "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"; then
        panel_status="${GREEN}● 运行中${RESET}"
    else
        panel_status="${RED}● 未运行${RESET}"
    fi

    if [ -f "$BIN_PATH" ]; then
        local real_ver=$($BIN_PATH --version 2>/dev/null | head -n 1 | awk '{print $2}')
        [ -z "$real_ver" ] && real_ver=$($BIN_PATH -v 2>/dev/null | head -n 1)
        panel_version="${real_ver:-v3.x}"
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

# ── 🛠️ 深度解析现有配置函数 (用于修改时回显) ──────────────────────────────────────────
parse_existing_config() {
    local conf_file="${INSTANCE_DIR}/${CURRENT_INSTANCE}.toml"
    if [ ! -f "$conf_file" ]; then return 1; fi

    OLD_PROTO=$(awk -F '=' '/^[[:space:]]*protocol[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
    [ -z "$OLD_PROTO" ] && OLD_PROTO="socks5"

    local raw_listen
    raw_listen=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
    # 提取端口号 (最后一个冒号后面)
    OLD_PORT=$(echo "$raw_listen" | awk -F ':' '{print $NF}')
    # 提取IP并去掉两边的方括号
    OLD_IP=$(echo "$raw_listen" | sed "s/:${OLD_PORT}$//g" | tr -d '[]')

    OLD_USER=$(awk -F '=' '/^[[:space:]]*username[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")
    OLD_PASS=$(awk -F '=' '/^[[:space:]]*password[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")
    [ -z "$OLD_USER" ] && OLD_USER="none"

    OLD_OUTBOUND=$(awk -F '=' '/^[[:space:]]*type[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file" | head -n 1)
    [ -z "$OLD_OUTBOUND" ] && OLD_OUTBOUND="default"
    return 0
}

menu_switch_instance() {
    echo -e "\n${GREEN}==== [多开实例矩阵管理中心] ====${RESET}"
    echo -e "${GREEN}当前操作目标实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}当前独立实例列表:${RESET}"

    local files=("${INSTANCE_DIR}"/*.toml)
    local instance_list=()
    local count=0

    if [ -e "${files[0]}" ]; then
        for f in "${files[@]}"; do
            ((count++))
            local name=$(basename "$f" .toml)
            instance_list+=("$name")
            
            local proto_type=$(awk -F '=' '/^[[:space:]]*protocol[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$f")
            local status_str="${RED}已停止${RESET}"
            systemctl is-active --quiet "${TEMPLATE_NAME}@${name}" && status_str="${GREEN}运行中${RESET}"
            
            echo -e " ${CYAN}[ ${count} ] ->${RESET} ${YELLOW}${name}${RESET} ${GREEN}][协议: ${proto_type^^} | 状态: ${status_str}${GREEN}]${RESET}"
        done
    else
        echo -e " ${YELLOW}(当前矩阵内空空如也，请直接在下方输入新名字创建第一个多开实例)${RESET}"
    fi
    echo ""
    echo -e "${GREEN}👉 输入现有实例前面的【数字编号】快速切换切换${RESET}"
    echo -e "${GREEN}👉 或者直接输入一个【全新的英文名字】来新建多开实例${RESET}"
    echo -ne "${YELLOW}请输入选择或名字: ${RESET}"
    read -r input_val || true
    [[ -z "$input_val" ]] && return

    if [[ "$input_val" =~ ^[0-9]+$ ]]; then
        if [ "$input_val" -gt 0 ] && [ "$input_val" -le "$count" ]; then
            local index=$((input_val - 1))
            CURRENT_INSTANCE="${instance_list[$index]}"
            echo -e " ${YELLOW}操作焦点已成功切为编号 [ ${input_val} ] 的实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
        else
            echo -e " ${RED}编号输入超出范围！未做任何变更。${RESET}"
        fi
    else
        CURRENT_INSTANCE="$input_val"
        echo -e " ${GREEN}检测到全新实例名称，已将焦点锁定在: ${YELLOW}${CURRENT_INSTANCE}${RESET} ${GREEN}(请去主菜单按 1 创建它)${RESET}"
    fi
}

menu_install() {
    init_environment
    local is_edit=false
    if [ "$1" = "edit" ]; then is_edit=true; fi

    if [ "$is_edit" = "true" ]; then
        if ! parse_existing_config; then
            die "未检测到实例 [ ${CURRENT_INSTANCE} ] 的旧配置，无法执行，请先按 1 进行全新部署！"
        fi
        echo -e "\n${GREEN}==== [💡 正在修改实例: ${CURRENT_INSTANCE} (直接回车保持原样)] ====${RESET}"
    else
        local conf_file="${INSTANCE_DIR}/${CURRENT_INSTANCE}.toml"
        if [ -f "$conf_file" ]; then
            warn "实例 [ ${CURRENT_INSTANCE} ] 已经存在对应配置文件。"
            read -r -p "$(echo -e "${GREEN}是否确定完全覆盖重写该实例？[y/N]: ${RESET}")" res
            [[ "$res" =~ ^[Yy]$ ]] || return
        fi
        echo -e "\n${GREEN}==== [配置新实例 ${CURRENT_INSTANCE} 参数] ====${RESET}"
        OLD_PROTO="socks5" OLD_IP="0.0.0.0" OLD_PORT="$((RANDOM % 50001 + 10000))" OLD_USER="mica_$(openssl rand -hex 3)" OLD_PASS="$(openssl rand -hex 8)" OLD_OUTBOUND="default"
    fi

    # 1. 协议选择
    if [ "$is_edit" = "true" ]; then
        echo -e "当前协议类型: ${CYAN}${OLD_PROTO^^}${RESET} (1. SOCKS5 | 2. HTTP)"
        read -r -p "请输入新序号 [直接回车不修改]: " proto_choice
    else
        echo "1. SOCKS5 代理模式 (默认，附带完整 UDP 转发能力)"
        echo "2. HTTP 传输代理模式"
        read -r -p "选择形态序号 [1-2]: " proto_choice
    fi
    local opt_proto="$OLD_PROTO"
    if [ "$proto_choice" = "1" ]; then opt_proto="socks5"; elif [ "$proto_choice" = "2" ]; then opt_proto="http"; fi

    # 2. IP 绑定
    read -r -p "$(echo -e "${GREEN}请输入监听网卡 IP [当前: ${YELLOW}${OLD_IP}${GREEN} | 回车不改]: ${RESET}")" input_ip
    local opt_ip="${input_ip:-$OLD_IP}"

    # 3. 端口绑定
    read -r -p "$(echo -e "${GREEN}请输入服务端口 [当前: ${YELLOW}${OLD_PORT}${GREEN} | 回车不改]: ${RESET}")" input_port
    local opt_port="${input_port:-$OLD_PORT}"
    
    # 4. 账号密码鉴权
    local opt_user="" local opt_pass=""
    read -r -p "$(echo -e "${GREEN}配置连接账户 [当前: ${YELLOW}${OLD_USER}${GREEN} | 输入 ${RED}none${GREEN} 开放免密 | 回车不改]: ${RESET}")" input_user
    if [ -z "$input_user" ]; then
        if [ "$OLD_USER" = "none" ]; then opt_user=""; opt_pass=""; else opt_user="$OLD_USER"; opt_pass="$OLD_PASS"; fi
    elif [ "$input_user" = "none" ]; then
        opt_user=""; opt_pass=""
    else
        opt_user="$input_user"
        read -r -p "$(echo -e "${GREEN}请输入新密码 [当前: ${YELLOW}${OLD_PASS}${GREEN}]: ${RESET}")" input_pass
        opt_pass="${input_pass:-$OLD_PASS}"
    fi

    # 5. 出站 Profile 路由类型
    echo -e "\n${GREEN}==== [选择出站 Profile 路由路径] ====${RESET}"
    if [ "$is_edit" = "true" ]; then
        echo -e "${GREEN}当前出站路径:${RESET} ${YELLOW}${OLD_OUTBOUND}${RESET}"
    fi
    echo "1. default (系统默认路由，普通混合网络)"
    echo "2. ipv4    (IPv4-only，强制仅解析A记录/仅走v4)"
    echo "3. ipv6    (IPv6-only，强制仅解析AAAA记录/仅走v6)"
    read -r -p "选择出站路径序号 [1-3, 回车不修改]: " outbound_choice
    local opt_outbound="$OLD_OUTBOUND"
    if [ "$outbound_choice" = "1" ]; then opt_outbound="default"; elif [ "$outbound_choice" = "2" ]; then opt_outbound="ipv4"; elif [ "$outbound_choice" = "3" ]; then opt_outbound="ipv6"; fi

    if [ ! -f "$BIN_PATH" ]; then
        download_bin
        install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$BIN_PATH"
        rm -rf "$(dirname "$TARGET_BIN_PATH")"
    fi

    write_config "$CURRENT_INSTANCE" "$opt_proto" "$opt_ip" "$opt_port" "$opt_user" "$opt_pass" "$opt_outbound"
    write_template_service

    echo -e "${YELLOW}正在加载新配置并重启沙箱实例: ${CURRENT_INSTANCE} ...${RESET}"
    systemctl enable "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" >/dev/null 2>&1
    systemctl restart "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"
    
    sleep 1.5
    if systemctl is-active --quiet "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"; then
        echo -e "${YELLOW}MicaProxy 实例 [ ${CURRENT_INSTANCE} ] 运行参数已完美更新！${RESET}"
        print_node_summary "$CURRENT_INSTANCE"
    else
        echo -e "${RED}实例重启成功，但检测到异常挂起，请按 [8] 抓取滚动日志。${RESET}"
    fi
}

menu_uninstall() {
    echo -e "${YELLOW}[WARN]该操作将彻底销毁清理当前控制聚焦的 [ ${CURRENT_INSTANCE} ] 独立服务。${RESET}"
    read -r -p "$(echo -e "${RED}确认抹除实例吗？[y/N]: ${RESET}")" res
    [[ "$res" =~ ^[Yy]$ ]] || return

    systemctl stop "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    systemctl disable "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    rm -f "${INSTANCE_DIR}/${CURRENT_INSTANCE}.toml"
    echo -e "${GREEN}矩阵实例 [ ${CURRENT_INSTANCE} ] 彻底安全移除。${RESET}"

    local files=("${INSTANCE_DIR}"/*.toml)
    if [ ! -e "${files[0]}" ]; then
        echo -e "${GREEN}检测到矩阵内已无任何活跃节点，深度自动卸载全系统共享组件...${RESET}"
        systemctl stop "${TEMPLATE_NAME}@*" >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE" "$BIN_PATH"
        rm -rf "/opt/MicaProxy" "$DATA_DIR"
        systemctl daemon-reload
        echo -e "${GREEN}全系统宿主机残留已深度彻底清洗清除。${RESET}"
        CURRENT_INSTANCE="$(hostname)"
    fi
}

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
    echo -e "${GREEN} 1. 安装当前实例${RESET}"
    echo -e "${GREEN} 2. 更新内核程序${RESET}"
    echo -e "${GREEN} 3. 卸载当前实例${RESET}"
    echo -e "${GREEN} 4. 修改当前实例${RESET}"
    echo -e "${GREEN} 5. 启动当前实例${RESET}"
    echo -e "${GREEN} 6. 停止当前实例${RESET}"
    echo -e "${GREEN} 7. 重启当前实例${RESET}"
    echo -e "${GREEN} 8. 当前实例日志${RESET}"
    echo -e "${GREEN} 9. 当前实例配置${RESET}"
    echo -e "${GREEN}10. 管理实例     ${YELLOW}← 添加/切换节点${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    
    read -r -p "$(echo -e "${GREEN}选择操作序号: ${RESET}")" choice
    case "$choice" in
        1) menu_install "new" ;;
        2) download_bin && install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$BIN_PATH" && rm -rf "$(dirname "$TARGET_BIN_PATH")" && echo -e "${GREEN}[OK]二进制核心覆盖升级完毕，请视情况手动重启各运行中的实例。${RESET}" ;;
        3) menu_uninstall ;;
        4) menu_install "edit" ;;
        5) systemctl start "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" && echo -e "${GREEN}[OK]启动成功${RESET}" ;;
        6) systemctl stop "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" && echo -e "${GREEN}[OK]停止成功${RESET}" ;;
        7) systemctl restart "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" && echo -e "${GREEN}[OK]重启完毕${RESET}" ;;
        8) (trap 'echo -e "\n"' INT; journalctl -u "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" -n 50 -f) ;;
        9) print_node_summary "$CURRENT_INSTANCE" ;;
        10) menu_switch_instance ;;
        0) exit 0 ;;
        *) echo -e "${YELLOW}[警告] 输入未知操作序号！${RESET}"; sleep 1 ;;
    esac
    read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键重新返回控制台面...${RESET}")"
done
