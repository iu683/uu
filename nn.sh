#!/usr/bin/env bash

# ==============================================================================
#  next-socks5 多实例管理面板 (Linux Systemd )
# ==============================================================================

# ── 核心环境变量与全局隔离变量 ──────────────────────────────────────────────────
export REPO="ZingerLittleBee/next-socks5"
export TEMPLATE_NAME="next-socks5"
export BASE_DIR="/etc/${TEMPLATE_NAME}"
export INSTALL_BIN="/usr/local/bin/${TEMPLATE_NAME}"
export DATA_BASE_DIR="/var/lib/${TEMPLATE_NAME}"

# 注册表文件：持久化记录矩阵内所有活跃的实例名
export REGISTRY_FILE="${BASE_DIR}/.instances.env"

# 默认控制的目标实例名称自动改成当前主机名
CURRENT_INSTANCE="$(hostname -s 2>/dev/null || echo "socks")"

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
    'https://ghfast.top/'
    "https://gh-proxy.com/"
    "https://hub.glowp.xyz/"
    "https://proxy.vvvv.ee/"
    "https://ghproxy.lvedong.eu.org/"
)

# ── 基础环境校验 ──────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[错误] 请使用 root 权限运行此脚本！${RESET}" >&2
    exit 1
fi

info() { echo -e "${BLUE}[INFO]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
die()  { echo -e "${RED}[ERROR]${RESET} $1" >&2; exit 1; }
pause() { echo; read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键重新返回控制面板...${RESET}")"; }

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        die "此脚本为 Alpine Linux 专属定制版，检测到当前系统非 Alpine！"
    fi
}
detect_os

check_port_occupied() {
    local port="$1"
    if ss -tulnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; then
        return 1  # 被占用
    fi
    return 0      # 空闲
}

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

REQUIRED_CMDS="curl tar sed grep awk openssl"
MISSING_CMDS=""
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING_CMDS="$MISSING_CMDS $cmd"
    fi
done

if [ -n "$MISSING_CMDS" ]; then
    echo -e "${YELLOW}[INFO]检测到系统缺失必要组件:${YELLOW}$MISSING_CMDS${RESET}，正在自动修复...${RESET}"
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
    esac
fi

# ── 注册表管理系统 ──────────────────────────────────────────────────────────
register_instance() {
    local name="$1"
    [ -d "$BASE_DIR" ] || install -m 0755 -d "$BASE_DIR"
    touch "$REGISTRY_FILE"
    if ! grep -q "^${name}$" "$REGISTRY_FILE" 2>/dev/null; then
        echo "$name" >> "$REGISTRY_FILE"
    fi
}

unregister_instance() {
    local name="$1"
    if [ -f "$REGISTRY_FILE" ]; then
        sed -i "/^${name}$/d" "$REGISTRY_FILE"
    fi
}

sync_registry() {
    [ -d "$BASE_DIR" ] || install -m 0755 -d "$BASE_DIR"
    touch "$REGISTRY_FILE"
    local temp_reg
    temp_reg=$(mktemp)
    for f in "${BASE_DIR}"/config_*.toml; do
        [ -e "$f" ] || continue
        local name
        name=$(basename "$f" | sed 's/^config_//;s/\.toml$//')
        if [ -n "$name" ]; then echo "$name" >> "$temp_reg"; fi
    done
    mv -f "$temp_reg" "$REGISTRY_FILE"
}

# ── 💡 代理轮询获取内核 ───────────────────────────────────────────────────────
fetch_latest_version() {

    echo -e "${YELLOW}[INFO]正在轮询检索 GitHub 官方最新发行版...${RESET}"
    VERSION="" SELECTED_PROXY=""

    for proxy in "${GITHUB_PROXIES[@]}"; do
        local api_url="${proxy}https://api.github.com/repos/${REPO}/releases/latest"
        if [ -z "$proxy" ]; then
            echo -e "${GREEN}尝试直连请求 GitHub API...${RESET}"
        else
            echo -e "${GREEN}尝试使用代理: ${YELLOW}${proxy}${RESET}"
        fi

        local resp
        resp=$(wget -qO- --timeout=5 --tries=1 --no-check-certificate "$api_url" 2>/dev/null)
        local tmp_ver
        tmp_ver=$(echo "$resp" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)

        if [[ -n "$tmp_ver" && "$tmp_ver" != "null" ]]; then
            VERSION="$tmp_ver"
            SELECTED_PROXY="$proxy"
            echo -e "${GREEN}成功获取到最新版本:${RESET} ${GREEN}${VERSION}${RESET}"
            break
        fi
    done

    if [ -z "$VERSION" ]; then
        VERSION="v0.4.0"
        SELECTED_PROXY=""
        echo -e "${GREEN}所有代理请求失败，将降级采用默认稳定版本: ${VERSION}${RESET}"
    fi
    [ -d "$BASE_DIR" ] || install -m 0755 -d "$BASE_DIR"
    echo "$VERSION" > "${BASE_DIR}/.version" 2>/dev/null
}

download_and_extract() {
    local ARCH
    ARCH=$(uname -m)
    local TARGET=""
    case "$ARCH" in
        x86_64)  TARGET="x86_64-unknown-linux-musl" ;;
        aarch64) TARGET="aarch64-unknown-linux-musl" ;;
        *) die "暂不支持的系统架构: $ARCH" ;;
    esac

    fetch_latest_version
    local ASSET="next-socks5-${TARGET}.tar.gz"
    local URL_TGZ="${SELECTED_PROXY}https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"

    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    echo -e "${GREEN}同步下载二进制核心资产包...${RESET}"
    curl -fsSL --connect-timeout 10 -o "$TMP/$ASSET" "$URL_TGZ" || die "下载资产包失败！"

    tar xzf "$TMP/$ASSET" -C "$TMP"
    local EXTRACTED_BIN
    EXTRACTED_BIN=$(find "$TMP" -type f -name "next-socks5" | head -n 1)
    [ -n "$EXTRACTED_BIN" ] || die "在压缩包内未找到主程序！${RESET}"
    
    install -m 0755 -o root -g root "$EXTRACTED_BIN" "$INSTALL_BIN"
    echo -e "${GREEN}全局主引擎内核同步部署完成。${RESET}"
}

# ── 核心配置与服务生成器 (Systemd 模板隔离) ────────────────────────────────────
write_config() {
    local instance="$1" bind_ip="$2" bind_port="$3" username="$4" password="$5"
    local conf_file="${BASE_DIR}/config_${instance}.toml"
    
    cat <<EOF > "$conf_file"
listen = "${bind_ip}:${bind_port}"

[auth]
EOF

    if [ -n "$username" ] && [ -n "$password" ]; then
        cat <<EOF >> "$conf_file"
method = "password"
[[auth.users]]
username = "${username}"
password = "${password}"
EOF
    else
        cat <<EOF >> "$conf_file"
method = "none"
EOF
    fi

    cat <<EOF >> "$conf_file"

[timeouts]
connect_ms = 10000
tcp_idle_ms = 300000
udp_idle_ms = 60000
EOF
    
    # 建立多实例数据独立沙箱
    local inst_data_dir="${DATA_BASE_DIR}/${instance}"
    install -m 0750 -o socks5 -g socks5 -d "$inst_data_dir"
    register_instance "$instance"
}

write_systemd_template() {
    # 采用 Systemd 动态实例化模板机制 (next-socks5@.service)
    local template_file="/etc/systemd/system/next-socks5@.service"
    cat <<EOF > "$template_file"
[Unit]
Description=next-socks5 SOCKS5 Server - Instance: %I
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=socks5
Group=socks5
WorkingDirectory=${DATA_BASE_DIR}/%I
ExecStart=${INSTALL_BIN} serve --config ${BASE_DIR}/config_%I.toml --no-tui
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

print_node_summary() {
    local instance="$1"
    local conf_file="${BASE_DIR}/config_${instance}.toml"
    [ -f "$conf_file" ] || return

    local bind_port
    bind_port=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); split($2, a, ":"); print a[length(a)]}' "$conf_file")
    [ -z "$bind_port" ] && bind_port="1080"
    
    local auth_method
    auth_method=$(awk -F '=' '/^[[:space:]]*method[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
    
    local auth_user="" auth_pass=""
    if [ "$auth_method" = "password" ]; then
        auth_user=$(awk -F '=' '/^[[:space:]]*username[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")
        auth_pass=$(awk -F '=' '/^[[:space:]]*password[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")
    fi
    local ip
    ip=$(get_public_ip "auto")
    display_ip="$ip"
    if [[ "$ip" == *":"* ]]; then display_ip="[$ip]"; fi

    echo -e "\n${GREEN}====== 矩阵实例${RESET} ${YELLOW}[ ${instance} ]${RESET} ${GREEN}配置详情 ======${RESET}"
    echo -e "${GREEN} 实例名 (ID)   :${RESET} ${instance}"
    echo -e "${GREEN} 公网出口 IP   :${RESET} ${display_ip}"
    echo -e "${GREEN} 服务绑定端口  :${RESET} ${bind_port}"
    if [ -n "$auth_user" ]; then
        echo -e "${GREEN} 用户名 (User) :${RESET} ${auth_user}"
        echo -e "${GREEN} 密码 (Pass)   :${RESET} ${auth_pass}"
    else
        echo -e "${GREEN} 鉴权公开模式  :${RESET} ${YELLOW}无密码公开访问${RESET}"
    fi
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}====== 👉 通用客户端 Socks5 链接 ======${RESET}"
    if [ -n "$auth_user" ]; then
        echo -e "${YELLOW}socks://${auth_user}:${auth_pass}@${display_ip}:${bind_port}#next-${instance}${RESET}"
    else
        echo -e "${YELLOW}socks://${display_ip}:${bind_port}#next-${instance}${RESET}"
    fi
    
    echo -e "${GREEN}====== 🚀 Telegram 内置一键代理链接 ======${RESET}"
    if [ -n "$auth_user" ]; then
        echo -e "${YELLOW}https://t.me/socks?server=${display_ip}&port=${bind_port}&user=${auth_user}&pass=${auth_pass}${RESET}"
    else
        echo -e "${YELLOW}https://t.me/socks?server=${display_ip}&port=${bind_port}${RESET}"
    fi
    echo ""
}

# ── 多开矩阵核心逻辑 ──────────────────────────────────────────────────────────
menu_install_instance() {
    if ! id "socks5" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin socks5 2>/dev/null \
          || adduser --system --no-create-home --shell /usr/sbin/nologin socks5
    fi
    
    [ -d "$BASE_DIR" ] || install -m 0755 -d "$BASE_DIR"
    write_systemd_template

    local is_edit=false
    if [[ "${1:-}" == "edit" ]]; then is_edit=true; fi

    local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.toml"
    local old_ip="::" old_port="" old_user="" old_pass=""

    if [ "$is_edit" = "true" ] && [ -f "$conf_file" ]; then
        echo -e "\n${GREEN}==== [正在修改实例参数: ${CURRENT_INSTANCE}] ====${RESET}"
        local current_bind
        current_bind=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
        old_ip="${current_bind%%:*}" old_port="${current_bind##*:}"
        [ -z "$old_ip" ] && old_ip="::"
        
        local current_method
        current_method=$(awk -F '=' '/^[[:space:]]*method[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
        if [ "$current_method" = "password" ]; then
            old_user=$(awk -F '=' '/^[[:space:]]*username[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")
            old_pass=$(awk -F '=' '/^[[:space:]]*password[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")
        fi
    else
        if [ -f "$conf_file" ]; then
            echo -e "${YELLOW}[WARN]检测到该实例 [ ${CURRENT_INSTANCE} ] 已经存在配置。${RESET}"
            read -r -p "$(echo -e "${GREEN}是否强行完全覆盖并重置该实例？[y/N]: ${RESET}")" confirm || true
            [[ "$confirm" =~ ^[Yy]$ ]] || return
        fi
        echo -e "\n${GREEN}==== [配置新多开实例矩阵: ${CURRENT_INSTANCE}] ====${RESET}"
        old_port=$((RANDOM % 50001 + 10000))
        while ! check_port_occupied "$old_port"; do old_port=$((RANDOM % 50001 + 10000)); done
        old_user="user_$(openssl rand -hex 4)"
        old_pass="$(openssl rand -hex 10)"
    fi

    # 1. IP 引导
    read -r -p "$(echo -e "${GREEN}请输入监听 IP 地址 [当前: ${old_ip}]: ${RESET}")" input_ip
    local opt_ip="${input_ip:-$old_ip}"

    # 2. 端口引导
    local opt_port=""
    while true; do
        read -r -p "$(echo -e "${GREEN}请输入服务端口 [当前: ${YELLOW}${old_port}${GREEN}]: ${RESET}")" input_port
        opt_port="${input_port:-$old_port}"
        
        if [[ "$opt_port" =~ ^[0-9]+$ ]] && [ "$opt_port" -gt 0 ] && [ "$opt_port" -le 65535 ]; then
            if [ "$is_edit" = "true" ] && [ "$opt_port" = "$old_port" ]; then break; fi
            if ! check_port_occupied "$opt_port"; then
                echo -e "${RED}[ERROR]端口 ${opt_port} 目前正被其他进程占用，请换个端口！${RESET}" >&2
                continue
            fi
            break
        else
            echo -e "${RED}[ERROR]端口无效，请输入 1-65535 之间的整数数值。${RESET}" >&2
        fi
    done

    # 3. 账户鉴权引导
    local opt_user="" local opt_pass=""
    read -r -p "$(echo -e "${GREEN}请输入用户名 [当前: ${old_user:-无密码}, 输入 ${RED}none${GREEN} 选免密]: ${RESET}")" input_user
    local select_user="${input_user:-$old_user}"

    if [[ "$select_user" == "none" ]] || [ -z "$select_user" ]; then
        opt_user="" opt_pass=""
    else
        opt_user="$select_user"
        read -r -p "$(echo -e "${GREEN}请输入账户密码 [当前: ${old_pass:-自动随机新密码}]: ${RESET}")" input_pass
        opt_pass="${input_pass:-$old_pass}"
        [ -z "$opt_pass" ] && opt_pass="$(openssl rand -hex 10)"
    fi

    # 4. 下载内核保底
    if [ ! -f "$INSTALL_BIN" ]; then
        echo -e "${YELLOW}[INFO]未在系统全局找到核心引擎，开始请求拉取下载...${RESET}"
        download_and_extract
    fi

    # 5. 写入配置并激活 Systemd 实例
    write_config "$CURRENT_INSTANCE" "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    
    systemctl daemon-reload
    systemctl enable "next-socks5@${CURRENT_INSTANCE}" >/dev/null 2>&1
    echo -e "${YELLOW}[INFO]拉起隔离子服务实例 [ next-socks5@${CURRENT_INSTANCE} ]...${RESET}"
    systemctl restart "next-socks5@${CURRENT_INSTANCE}"

    sleep 1
    if systemctl is-active --quiet "next-socks5@${CURRENT_INSTANCE}"; then
        echo -e "${GREEN}[INFO]矩阵实例 [ ${CURRENT_INSTANCE} ] 启动成功并切入后台分流矩阵！${RESET}"
        print_node_summary "$CURRENT_INSTANCE"
    else
        echo -e "${RED}[INFO]实例下发完成，但 Systemd 响应拉起失败，请检查端口是否冲突或选择 [8] 查看实时日志。${RESET}"
    fi
}

menu_uninstall_instance() {
    echo -e "${YELLOW}[WARN]该操作将彻底销毁清理当前控制聚焦的 [ ${CURRENT_INSTANCE} ] 独立服务。${RESET}"
    read -r -p "$(echo -e "${RED}确定完全卸载移除此实例？[y/N]: ${RESET}")" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    systemctl stop "next-socks5@${CURRENT_INSTANCE}" >/dev/null 2>&1
    systemctl disable "next-socks5@${CURRENT_INSTANCE}" >/dev/null 2>&1
    
    rm -f "${BASE_DIR}/config_${CURRENT_INSTANCE}.toml"
    rm -rf "${DATA_BASE_DIR}/${CURRENT_INSTANCE}"
    
    unregister_instance "$CURRENT_INSTANCE"
    echo -e "${GREEN}[OK]实例 [ ${CURRENT_INSTANCE} ] 现场清理干净。${RESET}"

    # 检测并进行常驻全局彻底自清理
    sync_registry
    if [ ! -s "$REGISTRY_FILE" ]; then
        echo -e "${YELLOW}[INFO]检测到矩阵内所有实例已被排空，自动触发全局常驻组件垃圾回收机制...${RESET}"
        rm -f /etc/systemd/system/next-socks5@.service
        rm -f "$INSTALL_BIN"
        rm -rf "$BASE_DIR" "$DATA_BASE_DIR"
        userdel socks5 >/dev/null 2>&1
        systemctl daemon-reload
        echo -e "${GREEN}[OK]全系统干净卸载，基础常驻依赖与核心已全部解绑！${RESET}"
        CURRENT_INSTANCE="socks"
    fi
}

menu_switch_matrix() {
    echo -e "\n${GREEN}==== [多开实例 Systemd 矩阵切换中心] ====${RESET}"
    echo -e "${GREEN}当前操作目标实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}当前独立实例列表:${RESET}"

    sync_registry
    local count=0
    local -a instance_list=()

    if [ -f "$REGISTRY_FILE" ]; then
        while IFS= read -r name || [ -n "$name" ]; do
            [ -z "$name" ] && continue
            local c_file="${BASE_DIR}/config_${name}.toml"
            [ -f "$c_file" ] || continue

            count=$((count + 1))
            instance_list[$count]="$name"
            
            local port_num
            port_num=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); split($2, a, ":"); print a[length(a)]}' "$c_file")
            
            local status_str="${RED}已停止${RESET}"
            if systemctl is-active --quiet "next-socks5@${name}"; then
                status_str="${GREEN}运行中${RESET}"
            fi
            
            echo -e " ${CYAN}[ ${count} ] ->${GREEN} 实例名: ${YELLOW}${name}${RESET} ${GREEN}[绑定端口: ${port_num} | 运行状态: ${status_str}]${GREEN}"
        done < "$REGISTRY_FILE"
    fi

    if [ "$count" -eq 0 ]; then echo -e " ${YELLOW}(当前矩阵内空空如也，请直接在下方输入新名字创建第一个多开实例)${RESET}"; fi
    
    echo ""
    echo -e "${GREEN}👉 输入已有实例前面的【数字编号】快速切换管理目标${RESET}"
    echo -e "${GREEN}👉 或者直接输入一个【全新的英文别名】来新建独立多开实例${RESET}"
    echo -ne "${YELLOW}请输入选择或名字: ${RESET}"
    read -r input_val || true

    if [ -z "$input_val" ]; then return; fi

    if [[ "$input_val" =~ ^[0-9]+$ ]]; then
        if [ "$input_val" -gt 0 ] && [ "$input_val" -le "$count" ]; then
            CURRENT_INSTANCE="${instance_list[$input_val]}"
            echo -e "${GREEN}操作焦点成功切为已有实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
        else
            echo -e "${RED}编号超出可用范围！${RESET}"
        fi
    else
        if [[ "$input_val" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            CURRENT_INSTANCE="$input_val"
            echo -e "${GREEN}成功锁定并创建新焦点: ${YELLOW}${CURRENT_INSTANCE}${RESET}${GREEN} (请在主菜单选择 [1] 下发部署服务)${RESET}"
        else
            echo -e "${RED}命名不规范，仅限使用英文字母、数字、中划线和下划线！${RESET}"
        fi
    fi
}

get_panel_status_info() {
    if systemctl is-active --quiet "next-socks5@${CURRENT_INSTANCE}" 2>/dev/null; then
        panel_status="${GREEN}运行中${RESET}"
    else
        panel_status="${RED}未运行${RESET}"
    fi

    if [ -f "$INSTALL_BIN" ]; then
        if [ -f "${BASE_DIR}/.version" ]; then
            panel_version=$(cat "${BASE_DIR}/.version")
        else
            panel_version="v0.4.X 内核"
        fi
    else
        panel_version="${RED}未安装核心${RESET}"
    fi

    local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.toml"
    if [ -f "$conf_file" ]; then
        panel_port=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
    else
        panel_port="实例未初始化"
    fi
}

# ── 4. 主循环控制中心 ─────────────────────────────────────────────────────────
while true; do
    get_panel_status_info
    clear
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}      ◈ next-socks5 多实例管理面板 ◈       ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}当前控制目标 :${RESET} ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}目标实例监听 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}服务活跃状态 :${RESET} $panel_status"
    echo -e "${GREEN}核心共享引擎 :${RESET} ${YELLOW}${panel_version}${RESET}"
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
    echo -e "${GREEN}10. 管理实例${RESET}  ${YELLOW}← 添加/切换节点${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    
    read -r -p "$(echo -e "${GREEN}请输入选项: ${RESET}")" choice
    
    case "$choice" in
        1) menu_install_instance "new" ; pause ;;
        2) download_and_extract && echo -e "${GREEN}[OK]二进制核心覆盖升级完毕，请视情况手动重启各运行中的实例。${RESET}"; pause ;;
        3) menu_uninstall_instance ; pause ;;
        4) menu_install_instance "edit" ; pause ;;
        5) systemctl start "next-socks5@${CURRENT_INSTANCE}" && echo -e "${GREEN}[OK]启动成功${RESET}"; pause ;;
        6) systemctl stop "next-socks5@${CURRENT_INSTANCE}" && echo -e "${GREEN}[OK]停止成功${RESET}"; pause ;;
        7) systemctl restart "next-socks5@${CURRENT_INSTANCE}" && echo -e "${GREEN}[OK]重启完毕${RESET}"; pause ;;
        8) 
            echo -e "${YELLOW}正在调取当前实例实时日志 (输入 q 或 Ctrl+C 退出返回面板):${RESET}\n"
            journalctl -u "next-socks5@${CURRENT_INSTANCE}" -n 50 -f 
            ;;
        9) print_node_summary "$CURRENT_INSTANCE" ; pause ;;
        10) menu_switch_matrix ;;
        0) clear; exit 0 ;;
        *) echo -e "${YELLOW}[WARN]无效输入序号！${RESET}"; sleep 0.5 ;;
    esac
done
