#!/usr/bin/env bash

# ==============================================================================
#  next-socks5 一键安全管理面板（纯净版）
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

REQUIRED_CMDS="curl tar sed grep awk"
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
    info "正在查询 GitHub 获取最新 Release 版本号..."
    TMP_API="$(mktemp)"
    if curl -sSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${REPO}/releases/latest" > "$TMP_API"; then
        VERSION="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$TMP_API" | head -n 1)"
    fi
    rm -f "$TMP_API"

    if [ -z "$VERSION" ]; then
        warn "API 获取失败，尝试网页流解析..."
        VERSION=$(curl -sS "https://github.com/${REPO}/releases/latest" 2>/dev/null | grep -o 'tag/[vV]*[0-9.]*' | awk -F '/' 'NR==1 {print $2}')
    fi

    if [ -z "$VERSION" ]; then
        die "无法获取最新版本号，请检查 GitHub 网络连通性。"
    fi
    export VERSION
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

# ── 2. 高安全级别 TOML 配置文件生成器 ──────────────────────────────────────────────────
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
handshake_ms = 10000        # deadline for greeting + auth + request (anti-slowloris)
connect_ms = 10000          # upstream dial + DNS resolution budget
tcp_idle_ms = 300000        # relay idle timeout (both directions idle)
udp_idle_ms = 60000         # UDP association idle timeout

[limits]
max_connections = 1024     # optional: cap on concurrent connections
udp_max_targets = 1024     # distinct targets tracked per UDP association

[egress]
block_loopback = true      # 127.0.0.0/8, ::1
block_link_local = true    # 169.254.0.0/16 (cloud metadata), fe80::/10
block_private = true       # 10/8, 172.16/12, 192.168/16, fc00::/7
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

# ── 3. 面板常规功能模块 ──────────────────────────────────────────────────────
get_status_info() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        panel_status="${GREEN}运行中${RESET}"
    else
        panel_status="${RED}未运行${RESET}"
    fi

    if [ -f "$INSTALL_BIN" ]; then
        local raw_ver
        raw_ver=$("$INSTALL_BIN" --version 2>/dev/null | head -n 1 | awk '{print $2}')
        panel_version="${raw_ver:-已安装}"
    else
        panel_version="${RED}未安装${RESET}"
    fi

    if [ -f "$CONF_FILE" ]; then
        panel_port=$(grep -i 'listen' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ' )
    else
        panel_port="127.0.0.1:1080"
    fi
}

menu_install() {
    if [ -f "$INSTALL_BIN" ]; then
        warn "系统中已存在安装好的实例文件。"
        read -r -p "$(echo -e "${GREEN}是否确定完全覆盖重新安装？[y/N]: ${RESET}")" res
        [[ "$res" =~ ^[Yy]$ ]] || return
    fi

    echo -e "\n${GREEN}==== [自定义安装配置] ====${RESET}"
    read -r -p "$(echo -e "${GREEN}请输入监听 IP 地址 [默认: 127.0.0.1]: ${RESET}")" input_ip
    local opt_ip="${input_ip:-127.0.0.1}"

    read -r -p "$(echo -e "${GREEN}请输入 SOCKS5 监听端口 [默认: 1080]: ${RESET}")" input_port
    local opt_port="${input_port:-1080}"
    if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [ "$opt_port" -le 0 ] || [ "$opt_port" -gt 65535 ]; then
        opt_port=1080
    fi

    local opt_user="" local opt_pass=""
    if [ "$opt_ip" != "127.0.0.1" ] && [ "$opt_ip" != "localhost" ]; then
        echo -e "${YELLOW}[安全审计] 检测到公网绑定，必须强制设置鉴权！${RESET}"
        while true; do
            read -r -p "$(echo -e "${GREEN}请输入鉴权用户名: ${RESET}")" opt_user
            [ -n "$opt_user" ] && break
        done
        while true; do
            read -r -p "$(echo -e "${GREEN}请输入鉴权密码 (≥16位): ${RESET}")" opt_pass
            if [ ${#opt_pass} -ge 16 ]; then break; fi
            warn "为了你的核心网络安全，公网鉴权密码长度必须大于或等于 16 位！"
        done
    else
        read -r -p "$(echo -e "${GREEN}请输入鉴权用户名 (本地回环默认留空免密): ${RESET}")" opt_user
        if [ -n "$opt_user" ]; then
            read -r -p "$(echo -e "${GREEN}请输入鉴权密码: ${RESET}")" opt_pass
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

    info "正在拉起后台服务..."
    systemctl start "$SERVICE_NAME"
    
    local is_ok=1
    for i in {1..5}; do
        if systemctl is-active --quiet "$SERVICE_NAME"; then is_ok=0; break; fi
        sleep 1
    done

    if [ "$is_ok" -eq 0 ]; then
        ok "next-socks5 高安全级代理服务部署成功！"
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
    ok "next-socks5 核心组件及配置文件已全部安全卸载收回。"
}

menu_edit_config() {
    [ -f "$CONF_FILE" ] || die "未发现任何配置文件，请先执行安装步骤。"
    local current_bind
    current_bind=$(grep -i 'listen' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ')
    local current_ip="${current_bind%%:*}" local current_port="${current_bind##*:}"
    local current_user
    current_user=$(grep -i 'username' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ')
    local current_pass
    current_pass=$(grep -i 'password' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ')

    [ -z "$current_ip" ] && current_ip="127.0.0.1"
    [ -z "$current_port" ] && current_port="1080"

    echo -e "\n${GREEN}==== [修改内核参数配置] ====${RESET}"
    read -r -p "$(echo -e "${GREEN}请输入监听 IP 地址 [当前: ${current_ip}]: ${RESET}")" input_ip
    local opt_ip="${input_ip:-$current_ip}"

    read -r -p "$(echo -e "${GREEN}请输入 SOCKS5 监听端口 [当前: ${current_port}]: ${RESET}")" input_port
    local opt_port="${input_port:-$current_port}"
    if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [ "$opt_port" -le 0 ] || [ "$opt_port" -gt 65535 ]; then
        opt_port="$current_port"
    fi

    local opt_user="" local opt_pass=""
    if [ "$opt_ip" != "127.0.0.1" ] && [ "$opt_ip" != "localhost" ]; then
        echo -e "${YELLOW}[安全审计] 公网暴露下必须强制设定鉴权密码！${RESET}"
        while true; do
            read -r -p "$(echo -e "${GREEN}请输入用户名 [当前: ${current_user}]: ${RESET}")" input_user
            opt_user="${input_user:-$current_user}"
            [ -n "$opt_user" ] && break
        done
        while true; do
            read -r -p "$(echo -e "${GREEN}请输入鉴权密码 [直接回车保持原样]: ${RESET}")" input_pass
            opt_pass="${input_pass:-$current_pass}"
            if [ ${#opt_pass} -ge 16 ]; then break; fi
            warn "密码必须长度 ≥16 位！"
        done
    else
        if [ -n "$current_user" ]; then
            read -r -p "$(echo -e "${GREEN}请输入用户名 [当前: ${current_user}，回车不变，输入 ${RED}none${GREEN} 清除鉴权]: ${RESET}")" input_user
            if [ -z "$input_user" ]; then
                opt_user="$current_user" opt_pass="$current_pass"
            elif [ "$input_user" = "none" ]; then
                opt_user="" opt_pass=""
            else
                opt_user="$input_user"
                read -r -p "$(echo -e "${GREEN}请输入新密码: ${RESET}")" opt_pass
            fi
        else
            read -r -p "$(echo -e "${GREEN}请输入鉴权用户名 (留空默认不启用): ${RESET}")" opt_user
            if [ -n "$opt_user" ]; then read -r -p "$(echo -e "${GREEN}请输入鉴权密码: ${RESET}")" opt_pass; fi
        fi
    fi

    write_config "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl restart "$SERVICE_NAME"
        ok "配置已覆盖，全套代理服务已同步重启生效！"
    else
        ok "配置已成功重写更新。"
    fi
}

menu_show_node_config() {
    if [ ! -f "$CONF_FILE" ]; then die "未检测到有效的服务配置文件。"; fi
    echo -e "\n${GREEN}========= 当前节点本地配置 =========${RESET}"
    cat "$CONF_FILE"
    echo -e "${GREEN}====================================${RESET}"

    local full_bind
    full_bind=$(grep -i 'listen' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ')
    local bind_ip="${full_bind%%:*}" local bind_port="${full_bind##*:}"
    local connect_ip="$bind_ip"
    if [ "$connect_ip" = "0.0.0.0" ]; then connect_ip="127.0.0.1"; fi

    local auth_user
    auth_user=$(grep -i 'username' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ')
    local auth_pass
    auth_pass=$(grep -i 'password' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ')

    local proxy_args="--socks5-hostname ${connect_ip}:${bind_port}"
    if [ -n "$auth_user" ] && [ -n "$auth_pass" ]; then
        proxy_args="--socks5-hostname ${auth_user}:${auth_pass}@${connect_ip}:${bind_port}"
    fi

    echo -e "\n${YELLOW}[正在通过本地 SOCKS5 实例验证链路基本连通性...]${RESET}"
    if curl -sI --max-time 6 $proxy_args "https://www.baidu.com" > /dev/null; then
        echo -e " 代理链路状态 :   ${GREEN}✔ 通过 (实例成功承载并转发网络流量)${RESET}"
    else
        echo -e " 代理链路状态 :   ${RED}✘ 未通过 (无法通过新建的 SOCKS5 端口触达外部互联网)${RESET}"
        warn "安全审计提示: 请检查本地出网防火墙策略，或检查上方配置中的 egress 网络拦截策略。"
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
    echo -e "${GREEN} 3. 卸载全套组件${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 next-socks5${RESET}"
    echo -e "${GREEN} 6. 停止 next-socks5${RESET}"
    echo -e "${GREEN} 7. 重启 next-socks5${RESET}"
    echo -e "${GREEN} 8. 查看内核日志${RESET}"
    echo -e "${GREEN} 9. 查看配置与连通状态${RESET}"
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
