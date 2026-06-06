#!/usr/bin/env bash

# ==============================================================================
#  cf-warp-rust 绿色经典风格一键管理面板
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

# 依赖检查
for cmd in curl tar sed grep awk; do
    if ! command -v $cmd &> /dev/null; then
        die "缺失基础组件: $cmd，请先使用系统包管理器安装它。"
    fi
done

# ── 1. 动态自适应组件 ──────────────────────────────────────────────────────────
detect_target() {
    ARCH=$(uname -m)
    if ldd --version 2>&1 | grep -iq "musl"; then
        LIBC="musl"
    else
        LIBC="gnu"
    fi

    case "$ARCH" in
        x86_64)  TARGET="x86_64-unknown-linux-${LIBC}" ;;
        aarch64) TARGET="aarch64-unknown-linux-${LIBC}" ;;
        *) die "暂不支持的系统架构: $ARCH (仅支持 x86_64 及 aarch64)" ;;
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
    curl -fsSL -o "$TMP/$ASSET" "$URL_TGZ" || die "下载资产包失败！"
    curl -fsSL -o "$TMP/$ASSET.sha256" "$URL_SHA" || die "下载 SHA256 校验文件失败！"

    if command -v sha256sum &> /dev/null; then
        LOCAL_SHA=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
        REMOTE_SHA=$(cat "$TMP/$ASSET.sha256" | awk '{print $1}')
        [ "$LOCAL_SHA" = "$REMOTE_SHA" ] || die "SHA256 签名不一致！文件可能已损坏。"
    fi

    tar xzf "$TMP/$ASSET" -C "$TMP"
    EXTRACTED="$TMP/warp-rust-${VERSION}-${TARGET}"
    [ -d "$EXTRACTED" ] || EXTRACTED="$TMP"
    [ -x "$EXTRACTED/warp-rust" ] || die "未找到可执行程序 warp-rust"
}

# ── 2. 配置文件与服务管理 ──────────────────────────────────────────────────────
write_config() {
    local bind_port="$1"
    local username="$2"
    local password="$3"

    [ -d "$CONF_DIR" ] || install -m 0755 -d "$CONF_DIR"
    
    cat <<EOF > "$CONF_FILE"
[server]
bind = "127.0.0.1:${bind_port}"
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
        panel_version="已安装 (最新版)"
    else
        panel_version="${RED}未安装${RESET}"
    fi

    if [ -f "$CONF_FILE" ]; then
        panel_port=$(grep -i 'bind' "$CONF_FILE" | head -n 1 | awk -F ':' '{print $2}' | tr -d '"' | tr -d ' ')
    else
        panel_port="1080"
    fi
}

menu_install() {
    if [ -f "$INSTALL_BIN" ]; then
        warn "系统中已存在运行中的实例文件。"
        read -p "$(echo -e "${GREEN}是否确定完全覆盖重新安装？[y/N]: ${RESET}")" res
        [[ "$res" =~ ^[Yy]$ ]] || return
    fi

    echo -e "\n${GREEN}==== [自定义安装配置] ====${RESET}"
    read -p "$(echo -e "${GREEN}请输入 SOCKS5 监听端口 [默认: 1080]: ${RESET}")" input_port
    local opt_port="${input_port:-1080}"
    if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [ "$opt_port" -le 0 ] || [ "$opt_port" -gt 65535 ]; then
        opt_port=1080
    fi

    read -p "$(echo -e "${GREEN}请输入鉴权用户名 (留空则不启用鉴权): ${RESET}")" opt_user
    local opt_pass=""
    if [ -n "$opt_user" ]; then
        read -p "$(echo -e "${GREEN}请输入鉴权密码: ${RESET}")" opt_pass
        if [ -z "$opt_pass" ]; then
            warn "密码为空，已取消鉴权设置。"
            opt_user=""
        fi
    fi

    download_and_extract

    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER" 2>/dev/null \
          || adduser --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    fi

    install -m 0755 -o root -g root "$EXTRACTED/warp-rust" "$INSTALL_BIN"
    install -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" -d "$DATA_DIR"

    write_config "$opt_port" "$opt_user" "$opt_pass"
    write_systemd

    systemctl start "$SERVICE_NAME"
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "AnyTLS-Style WARP 部署成功！"
    else
        warn "部署完成，但进程启动异常，请稍后选择 [8] 查看日志。"
    fi
}

menu_update() {
    [ -f "$SERVICE_FILE" ] || die "未检测到系统服务，请先选择 [1] 进行安装。"
    download_and_extract
    systemctl stop "$SERVICE_NAME"
    install -m 0755 -o root -g root "$EXTRACTED/warp-rust" "$INSTALL_BIN"
    systemctl start "$SERVICE_NAME"
    ok "组件已成功平滑更新。"
}

menu_uninstall() {
    read -p "$(echo -e "${GREEN}确定要完全卸载清除吗？[y/N]: ${RESET}")" res
    [[ "$res" =~ ^[Yy]$ ]] || return
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
    
    local old_port=$(grep -i 'bind' "$CONF_FILE" | head -n 1 | awk -F ':' '{print $2}' | tr -d '"' | tr -d ' ')
    [ -z "$old_port" ] && old_port="1080"

    local editor="vi"
    if command -v nano &> /dev/null; then editor="nano"; fi
    if command -v vim &> /dev/null; then editor="vim"; fi
    $editor "$CONF_FILE"
    
    local new_port=$(grep -i 'bind' "$CONF_FILE" | head -n 1 | awk -F ':' '{print $2}' | tr -d '"' | tr -d ' ')
    [ -z "$new_port" ] && new_port="$old_port"

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        read -p "$(echo -e "${GREEN}配置已修改，是否立即重启服务生效？[y/N]: ${RESET}")" res
        if [[ "$res" =~ ^[Yy]$ ]]; then
            systemctl restart "$SERVICE_NAME" && ok "服务已重启，当前端口变更为: $new_port"
        fi
    fi
}

menu_show_node_config() {
    if [ ! -f "$CONF_FILE" ]; then
        die "未检测到有效的服务配置文件。"
    fi
    
    echo -e "\n${GREEN}========= 当前节点本地配置 =========${RESET}"
    cat "$CONF_FILE" | grep -A 5 "\[server\]"
    echo -e "${GREEN}====================================${RESET}"

    local current_port=$(grep -i 'bind' "$CONF_FILE" | head -n 1 | awk -F ':' '{print $2}' | tr -d '"' | tr -d ' ')
    [ -z "$current_port" ] && current_port="1080"

    local auth_user=$(grep -i 'username' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '"' | tr -d ' ')
    local auth_pass=$(grep -i 'password' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '"' | tr -d ' ')

    local proxy_args="--socks5-hostname 127.0.0.1:${current_port}"
    if [ -n "$auth_user" ] && [ -n "$auth_pass" ]; then
        proxy_args="--socks5-hostname ${auth_user}:${auth_pass}@127.0.0.1:${current_port}"
    fi

    echo -e "\n${YELLOW}[正在通过本地代理验证流量连通性...]${RESET}"
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

# ── 4. 主循环控制中心 ─────────────────────────────────────────────────────────
while true; do
    get_status_info
    
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}       CF-WARP-RUST 面板       ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $panel_status"
    echo -e "${GREEN}版本 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1. 安装 WARP-Rust${RESET}"
    echo -e "${GREEN}2. 更新 WARP-Rust${RESET}"
    echo -e "${GREEN}3. 卸载 WARP-Rust${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 WARP-Rust${RESET}"
    echo -e "${GREEN}6. 停止 WARP-Rust${RESET}"
    echo -e "${GREEN}7. 重启 WARP-Rust${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置与出口状态${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    
    # 核心修改：将选择提示符完全包装为绿色高亮
    read -p "$(echo -e "${GREEN}请输入选项 [0-9]: ${RESET}")" choice
    
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
        0) clear; exit 0 ;;
        *) warn "未识别的无效序号！"; sleep 1 ;;
    esac
    echo
    read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键返回主控制面板...${RESET}")"
done
