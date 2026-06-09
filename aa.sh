#!/usr/bin/env sh

# ==============================================================================
#  next-socks5 一键管理面板 (Alpine Linux OpenRC 专属版)
# ==============================================================================

# ── 核心环境变量 ──────────────────────────────────────────────────────────────
export REPO="ZingerLittleBee/next-socks5"
export SERVICE_NAME="next-socks5"
export SERVICE_USER="socks5"
export INSTALL_BIN="/usr/local/bin/next-socks5"
export CONF_DIR="/etc/next-socks5"
export CONF_FILE="${CONF_DIR}/config.toml"
export DATA_DIR="/var/lib/next-socks5"
export SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"

# ── 终端颜色定义 ──────────────────────────────────
export RESET='\033[0m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'

# ── 基础环境校验 ──────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[错误]${RESET} 请使用 root 权限运行此脚本！" >&2
    exit 1
fi

info() { echo -e "${BLUE}[INFO]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
die()  { echo -e "${RED}[ERROR]${RESET} $1" >&2; exit 1; }

# 验证 Alpine 身份
if [ ! -f /etc/alpine-release ]; then
    die "此脚本为 Alpine Linux 专属定制版，检测到当前系统非 Alpine！"
fi

# Alpine 依赖补全 (使用 gawk 确保原脚本中复杂的 awk 语法完全兼容)
REQUIRED_CMDS="curl tar sed gawk grep openssl"
MISSING_CMDS=""

for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
        # awk 映射到 gawk 安装
        if [ "$cmd" = "gawk" ]; then
            MISSING_CMDS="$MISSING_CMDS gawk"
        else
            MISSING_CMDS="$MISSING_CMDS $cmd"
        fi
    fi
done

if [ -n "$MISSING_CMDS" ]; then
    info "检测到系统缺失必要组件:${YELLOW}$MISSING_CMDS${RESET}，正在自动安装..."
    apk update -q && apk add -q --no-cache $MISSING_CMDS >/dev/null 2>&1
    
    for cmd in $REQUIRED_CMDS; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            die "自动安装 [ $cmd ] 失败，请检查 apk 镜像源。"
        fi
    done
    ok "基础依赖补全成功！"
fi

# ── 1. 核心下载与组件解压 ───────────────────────────────────────────────────
detect_target() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  TARGET="x86_64-unknown-linux-musl" ;;
        aarch64) TARGET="aarch64-unknown-linux-musl" ;;
        *) die "暂不支持的系统架构: $ARCH (面板目前仅支持 x86_64 及 aarch64 的 musl 环境)" ;;
    esac
}

fetch_latest_version() {
    info "正在查询 GitHub 获取最新 Release 版本号..."
    TMP_API="$(mktemp)"
    if curl -sSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${REPO}/releases/latest" > "$TMP_API"; then
        VERSION="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$TMP_API" | head -n 1)"
    fi
    rm -f "$TMP_API"

    if [ -z "$VERSION" ]; then
        warn "API 获取失败，尝试网页流解析..."
        VERSION=$(curl -sS "https://github.com/${REPO}/releases/latest" 2>/dev/null | grep -o 'tag/[vV]*[0-9.]*' | gawk -F '/' 'NR==1 {print $2}')
    fi

    if [ -z "$VERSION" ]; then
        VERSION="v0.1.3"
    fi
    export VERSION
    
    [ -d "$CONF_DIR" ] || install -m 0755 -d "$CONF_DIR"
    echo "$VERSION" > "${CONF_DIR}/.version" 2>/dev/null
}

download_and_extract() {
    detect_target
    fetch_latest_version
    info "正在匹配系统环境形态: ${YELLOW}${TARGET}${RESET}"

    ASSET="next-socks5-${TARGET}.tar.gz"
    URL_TGZ="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    info "开始同步下载资产包..."
    curl -fsSL -o "$TMP/$ASSET" "$URL_TGZ" || die "下载资产包失败！"

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
# port_range = "40000-40100"
# advertise = "YOUR_PUBLIC_IP"
EOF
}

# ── Alpine OpenRC 服务脚本生成器 ──────────────────────────────────────────────
write_openrc() {
    cat <<'EOF' > "$SERVICE_FILE"
#!/sbin/openrc-run

description="next-socks5 - Fast and Lightweight SOCKS5 Server"
supervisor="supervisord" # 借用 OpenRC 内置的 supervisor 守护进程实现自动重启与后台化

command="/usr/local/bin/next-socks5"
command_args="serve --config /etc/next-socks5/config.toml --no-tui"
command_user="socks5:socks5"
directory="/var/lib/next-socks5"

output_log="/var/log/next-socks5.log"
error_log="/var/log/next-socks5.err"

# 突破最大文件打开数限制
rc_ulimit="-n 65535"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0750 -o socks5:socks5 /var/lib/next-socks5
}
EOF
    chmod +x "$SERVICE_FILE"
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
}

# ── 节点配置总结报告 ──────────────────────────────────────────────────────────
print_node_summary() {
    if [ ! -f "$CONF_FILE" ]; then return; fi

    local bind_port
    bind_port=$(gawk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); split($2, a, ":"); print a[length(a)]}' "$CONF_FILE")
    [ -z "$bind_port" ] && bind_port="16216"
    
    local auth_method
    auth_method=$(gawk -F '=' '/^[[:space:]]*method[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$CONF_FILE")
    
    local auth_user="" local auth_pass=""
    if [ "$auth_method" = "password" ]; then
        auth_user=$(gawk -F '=' '/^[[:space:]]*username[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$CONF_FILE")
        auth_pass=$(gawk -F '=' '/^[[:space:]]*password[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$CONF_FILE")
    fi

    local public_ip
    public_ip=$(curl -s --max-time 5 ipinfo.io/ip || curl -s --max-time 5 api.ipify.org || echo "你的公网IP")

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
        echo -e "${YELLOW}socks://${auth_user}:${auth_pass}@${public_ip}:${bind_port}#uu-socks5${RESET}"
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
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
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
                panel_version="v0.1.3"
            fi
        fi
    else
        panel_version="${RED}未安装${RESET}"
    fi

    if [ -f "$CONF_FILE" ]; then
        panel_port=$(gawk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$CONF_FILE")
    else
        panel_port="未设定"
    fi
}

menu_install() {
    if [ -f "$INSTALL_BIN" ]; then
        warn "系统中已存在安装好的实例文件。"
        echo -n -e "${GREEN}是否确定完全覆盖重新安装？[y/N]: ${RESET}"
        read -r res
        [[ "$res" =~ ^[Yy]$ ]] || return
    fi

    echo -e "\n${GREEN}==== [自定义安装配置] ====${RESET}"
    echo -n -e "${GREEN}请输入监听 IP 地址 [默认 ::]: ${RESET}"
    read -r input_ip
    local opt_ip="${input_ip:-::}"

    local rand_port=$((RANDOM % 50001 + 10000))
    echo -n -e "${GREEN}请输入 SOCKS5 监听端口 [回车默认随机端口: ${rand_port}]: ${RESET}"
    read -r input_port
    local opt_port="${input_port:-$rand_port}"
    if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [ "$opt_port" -le 0 ] || [ "$opt_port" -gt 65535 ]; then
        opt_port=$rand_port
    fi

    local rand_user="user_$(openssl rand -hex 4)"
    local rand_pass="$(openssl rand -hex 10)"
    local opt_user="" local opt_pass=""

    echo -n -e "${GREEN}请输入自定义用户名 [回车默认随机: ${YELLOW}${rand_user}${GREEN}, 输入 ${RED}none${GREEN} 选免密]: ${RESET}"
    read -r input_user
    if [ -z "$input_user" ]; then
        opt_user="$rand_user"
        echo -n -e "${GREEN}请输入自定义密码 [回车默认随机: ${YELLOW}${rand_pass}${GREEN}]: ${RESET}"
        read -r input_pass
        opt_pass="${input_pass:-$rand_pass}"
    elif [ "$input_user" = "none" ]; then
        opt_user=""
        opt_pass=""
    else
        opt_user="$input_user"
        echo -n -e "${GREEN}请输入自定义密码 [回车默认随机: ${YELLOW}${rand_pass}${GREEN}]: ${RESET}"
        read -r input_pass
        opt_pass="${input_pass:-$rand_pass}"
    fi

    download_and_extract

    # Alpine 使用 adduser 创建系统用户
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        adduser -S -D -H -h "$DATA_DIR" -s /sbin/nologin "$SERVICE_USER" 2>/dev/null
    fi

    install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$INSTALL_BIN"
    install -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" -d "$DATA_DIR"
    write_config "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    write_openrc

    info "正在拉起后台服务..."
    rc-service "$SERVICE_NAME" start
    
    local is_ok=1
    for i in {1..5}; do
        if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then is_ok=0; break; fi
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
    rc-service "$SERVICE_NAME" stop
    install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$INSTALL_BIN"
    rc-service "$SERVICE_NAME" start
    ok "next-socks5 核心主程序已完成平滑更新。"
}

menu_uninstall() {
    rc-service "$SERVICE_NAME" stop >/dev/null 2>&1
    rc-update del "$SERVICE_NAME" default >/dev/null 2>&1
    rm -f "$INSTALL_BIN" "$SERVICE_FILE"
    rm -rf "$CONF_DIR" "$DATA_DIR"
    rm -f /var/log/next-socks5.log /var/log/next-socks5.err
    deluser "$SERVICE_USER" >/dev/null 2>&1
    ok "next-socks5 核心组件及配置文件已全部安全卸载收回。"
}

menu_edit_config() {
    [ -f "$CONF_FILE" ] || die "未发现任何配置文件，请先执行安装步骤。"
    
    local current_bind
    current_bind=$(gawk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$CONF_FILE")
    local current_ip="${current_bind%%:*}" local current_port="${current_bind##*:}"
    
    local current_method
    current_method=$(gawk -F '=' '/^[[:space:]]*method[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$CONF_FILE")
    
    local current_user="" local current_pass=""
    if [ "$current_method" = "password" ]; then
        current_user=$(gawk -F '=' '/^[[:space:]]*username[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$CONF_FILE")
        current_pass=$(gawk -F '=' '/^[[:space:]]*password[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$CONF_FILE")
    fi

    [ -z "$current_ip" ] && current_ip="::"
    [ -z "$current_port" ] && current_port="1080"

    echo -e "\n${GREEN}==== [修改内核参数配置] ====${RESET}"
    echo -n -e "${GREEN}请输入监听 IP 地址 [当前: ${current_ip}]: ${RESET}"
    read -r input_ip
    local opt_ip="${input_ip:-$current_ip}"

    local rand_port=$((RANDOM % 50001 + 10000))
    echo -n -e "${GREEN}请输入 SOCKS5 监听端口 [当前: ${current_port}, 回车保持原样, 输入 ${YELLOW}rand${GREEN} 随机重置]: ${RESET}"
    read -r input_port
    local opt_port="$current_port"
    if [ "$input_port" = "rand" ]; then
        opt_port="$rand_port"
    elif [ -n "$input_port" ]; then
        if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -gt 0 ] && [ "$input_port" -le 65535 ]; then
            opt_port="$input_port"
        fi
    fi

    local opt_user="" local opt_pass=""
    echo -n -e "${GREEN}请输入用户名 [当前: ${current_user:-无密码}, 输入 ${RED}none${GREEN} 彻底清除密码, 回车默认保持原样/不设置]: ${RESET}"
    read -r input_user
    
    if [ -z "$input_user" ]; then
        opt_user="$current_user"
        opt_pass="$current_pass"
    elif [ "$input_user" = "none" ]; then
        opt_user=""
        opt_pass=""
    else
        opt_user="$input_user"
        echo -n -e "${GREEN}请输入新密码 [当前: ${current_pass:-无密码}, 回车默认保持原样/不设置]: ${RESET}"
        read -r input_pass
        opt_pass="${input_pass:-$current_pass}"
    fi

    write_config "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        rc-service "$SERVICE_NAME" restart
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
}

# ── 4. 主循环控制中心 ─────────────────────────────────────────────────────────
while true; do
    get_status_info
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}    next-socks5 面板 (Alpine) ${RESET}"
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
    
    echo -n -e "${GREEN}请输入选项: ${RESET}"
    read -r choice
    
    case "$choice" in
        1) menu_install ;;
        2) menu_update ;;
        3) menu_uninstall ;;
        4) menu_edit_config ;;
        5) rc-service "$SERVICE_NAME" start && ok "动作: 核心启动成功" ;;
        6) rc-service "$SERVICE_NAME" stop && ok "动作: 核心停止成功" ;;
        7) rc-service "$SERVICE_NAME" restart && ok "动作: 核心重启成功" ;;
        8) 
            if [ -f /var/log/next-socks5.log ]; then
                echo -e "${YELLOW}按 Ctrl+C 退出日志查看...${RESET}\n"
                tail -n 50 -f /var/log/next-socks5.log
            else
                warn "暂无日志文件生成。"
            fi
            ;;
        9) menu_show_node_config ;;
        0) clear; exit 0 ;;
        *) warn "未识别的无效序号！"; sleep 1 ;;
    esac
    
    echo -n -e "${GREEN}按任意键返回主控制面板...${RESET}"
    # 兼容 Alpine sh 的单字符读取
    stty raw -echo; dd exit=1 count=1 2>/dev/null; stty -raw echo
done
