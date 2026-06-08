#!/usr/bin/env bash

# ==============================================================================
#  MASQUE-WARP 全自动管理面板 (2026 优化版)
# ==============================================================================

export REPO="Diniboy1123/usque"
export SERVICE_NAME="usque"
export SERVICE_USER="root"
export INSTALL_BIN="/usr/local/bin/usque"
export CONF_DIR="/etc/usque"
export CONF_FILE="${CONF_DIR}/config.json"
export SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 配色方案
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

GITHUB_PROXY=(
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
    '' 
)

if [ "$EUID" -ne 0 ]; then
    echo -e "${GREEN}[错误]${RESET} 请使用 root 权限运行此脚本！" >&2
    exit 1
fi

info() { echo -e "${GREEN}[INFO]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
die()  { echo -e "${GREEN}[ERROR]${RESET} $1" >&2; exit 1; }

# 操作系统检测
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        die "无法识别当前操作系统类型。"
    fi
}
detect_os

# 依赖安装
REQUIRED_CMDS="curl grep awk unzip"
MISSING_CMDS=""
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" &> /dev/null; then MISSING_CMDS="$MISSING_CMDS $cmd"; fi
done

if [ -n "$MISSING_CMDS" ]; then
    info "正在自动安装缺失组件: $MISSING_CMDS..."
    case "$OS" in
        ubuntu|debian) apt-get update -qy && apt-get install -y $MISSING_CMDS >/dev/null 2>&1 ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then dnf install -y $MISSING_CMDS >/dev/null 2>&1; else yum install -y $MISSING_CMDS >/dev/null 2>&1; fi ;;
    esac
    ok "依赖补全成功！"
fi

# ── 1. 核心程序下载 ─────────────────────────────────────────────────────────
download_bin() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  TARGET="linux_amd64" ;;
        aarch64) TARGET="linux_arm64" ;;
        *) die "暂不支持的系统架构: $ARCH" ;;
    esac

    info "正在检索 GitHub 最新 Release..."
    local latest_tag=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        latest_tag=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [ -n "$latest_tag" ] && break
    done

    [ -z "$latest_tag" ] && latest_tag="v3.0.0"
    local pure_ver="${latest_tag#v}"
    info "锁定版本: v${pure_ver}"

    local zip_name="usque_${pure_ver}_${TARGET}.zip"
    local tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT

    local download_success=0
    for proxy in "${GITHUB_PROXY[@]}"; do
        local url="https://github.com/${REPO}/releases/download/${latest_tag}/${zip_name}"
        [ -n "$proxy" ] && url="${proxy}${url}"
        info "尝试下载源 [${proxy:-官方直连}]..."
        if curl -fsSL -L --max-time 35 -o "$tmp_dir/$zip_name" "$url"; then
            download_success=1
            break
        fi
    done

    [ "$download_success" -ne 1 ] && die "下载失败，请检查网络。"

    unzip -q -o "$tmp_dir/$zip_name" -d "$tmp_dir"
    if [ -f "$tmp_dir/usque" ]; then
        [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR"
        cp -f "$tmp_dir/usque" "$INSTALL_BIN"
        chmod +x "$INSTALL_BIN"
        ok "内核程序部署成功。"
    else
        die "解压异常，未找到内核文件。"
    fi
}

# ── 2. 全自动免交互注册 (核心修改点) ──────────────────────────────────────────
register_usque() {
    local has_v4=0
    if curl -4sSk --max-time 4 https://www.cloudflare.com/cdn-cgi/trace | grep -q "ip=" 2>/dev/null; then
        has_v4=1
    fi

    local cp_resolv=0
    if [ "$has_v4" -ne 1 ]; then
        info "检测到纯 IPv6 环境，配置临时 DNS64 管道..."
        if [ -f /etc/resolv.conf ]; then cp -f /etc/resolv.conf /etc/resolv.conf.bak; cp_resolv=1; fi
        echo -e "nameserver 2a01:4f8:c2c:123f::1\nnameserver 2001:4860:4860::8888" > /etc/resolv.conf
    fi

    [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR"
    rm -f "$CONF_FILE"
    cd "$CONF_DIR" || exit 1
    
    info "发起匿名无感注册，自动确认服务条款..."
    # 使用 printf 预填 'y' 并换行，解决 Terms of Service 确认问题
    if printf 'y\n' | "${INSTALL_BIN}" register; then
        ok "Cloudflare 凭据注册完成。"
        
        if [ -f "$CONF_FILE" ] && [ "$has_v4" -ne 1 ]; then
            info "执行 IPv6 端点重定向清洗..."
            local p_key=$(grep -o '"private_key": *"[^"]*"' "$CONF_FILE" | awk -F '"' '{print $4}')
            local d_id=$(grep -o '"device_id": *"[^"]*"' "$CONF_FILE" | awk -F '"' '{print $4}')

            if [ -n "$p_key" ] && [ -n "$d_id" ]; then
                cat <<EOF > "$CONF_FILE"
{
  "private_key": "${p_key}",
  "device_id": "${d_id}",
  "endpoint_v4": "2606:4700:102::1",
  "endpoint_v6": "2606:4700:102::1",
  "endpoint": "[2606:4700:102::1]:443",
  "interface": {
    "addresses": {
      "v4": "172.16.0.2/32",
      "v6": "fd00:5555:5555::2/128"
    }
  }
}
EOF
                ok "已将出口重定向至 IPv6 边缘节点。"
            fi
        fi
    else
        [ "$cp_resolv" -eq 1 ] && mv -f /etc/resolv.conf.bak /etc/resolv.conf
        die "注册资产失败，请检查网络出口。"
    fi
    [ "$cp_resolv" -eq 1 ] && mv -f /etc/resolv.conf.bak /etc/resolv.conf
}

# ── 3. Systemd 服务配置 ──────────────────────────────────────────────────────
write_systemd() {
    local bind_ip="$1" local bind_port="$2" local username="$3" local password="$4"
    local exec_args="socks -b ${bind_ip} -p ${bind_port}"
    if [ -n "$username" ] && [ -n "$password" ]; then exec_args="${exec_args} -u ${username} -w ${password}"; fi

    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Cloudflare WARP MASQUE Proxy (Usque)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${CONF_DIR}
ExecStart=${INSTALL_BIN} --config ${CONF_FILE} ${exec_args}
Restart=always
RestartSec=4s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    echo "${bind_ip}:${bind_port}|${username}|${password}" > "${CONF_DIR}/.panel_meta"
}

# ── 4. 状态获取 ──────────────────────────────────────────────────────────────
get_status_info() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        panel_status="运行中"
    else
        panel_status="未运行"
    fi
    
    if [ -f "$INSTALL_BIN" ]; then
        local check_ver=$("$INSTALL_BIN" -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        panel_version="v${check_ver:-已安装}"
    else
        panel_version="未安装"
    fi

    if [ -f "${CONF_DIR}/.panel_meta" ]; then
        local meta=$(cat "${CONF_DIR}/.panel_meta"); panel_port="${meta%%|*}"
    else 
        panel_port="127.0.0.1:1080"
    fi
}

# ── 5. 菜单函数 ──────────────────────────────────────────────────────────────
menu_install() {
    [ -f "$INSTALL_BIN" ] && warn "检测到旧版本，将执行覆盖安装..."
    download_bin
    register_usque
    write_systemd "127.0.0.1" "1080" "" ""
    info "拉起后台服务..."
    systemctl restart "$SERVICE_NAME"
    sleep 2
    systemctl is-active --quiet "$SERVICE_NAME" && ok "部署成功！" || warn "启动失败，请检查日志。"
}

menu_update() {
    [ -f "$SERVICE_FILE" ] || die "服务未安装。"
    systemctl stop "$SERVICE_NAME"
    download_bin
    systemctl start "$SERVICE_NAME"
    ok "升级完成。"
}

menu_uninstall() {
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$INSTALL_BIN" "$SERVICE_FILE"
    systemctl daemon-reload; rm -rf "$CONF_DIR"
    ok "卸载完毕。"
}

menu_edit_config() {
    [ -f "${CONF_DIR}/.panel_meta" ] || die "未发现运行记录。"
    local meta=$(cat "${CONF_DIR}/.panel_meta"); local ip_port="${meta%%|*}"
    local current_ip="${ip_port%%:*}" current_port="${ip_port##*:}"
    local remain="${meta#*|}" current_user="${remain%%|*}" current_pass="${remain##*|}"

    echo ""
    echo "==== 修改监听配置 ===="
    echo -ne "${GREEN}请输入监听 IP [当前: ${current_ip}]: ${RESET}"
    read -r input_ip
    local opt_ip="${input_ip:-$current_ip}"

    echo -ne "${GREEN}请输入 SOCKS5 端口 [当前: ${current_port}]: ${RESET}"
    read -r input_port
    local opt_port="${input_port:-$current_port}"

    local opt_user="" local opt_pass=""
    if [ "$opt_ip" != "127.0.0.1" ]; then
        warn "公网暴露模式建议设定鉴权！"
        echo -ne "${GREEN}请输入用户名: ${RESET}"
        read -r opt_user
        echo -ne "${GREEN}请输入密码 (>=16位): ${RESET}"
        read -r opt_pass
    fi

    write_systemd "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    systemctl restart "$SERVICE_NAME" && ok "配置已生效。"
}

menu_show_node_config() {
    if [ ! -f "${CONF_DIR}/.panel_meta" ] ; then die "未检测到配置。"; fi
    local meta=$(cat "${CONF_DIR}/.panel_meta"); local ip_port="${meta%%|*}"
    local bind_ip="${ip_port%%:*}" bind_port="${ip_port##*:}"
    local remain="${meta#*|}" auth_user="${remain%%|*}" auth_pass="${remain##*|}"

    echo -e "\n========= SOCKS5 服务详情 ========="
    echo " 地址 : ${bind_ip}:${bind_port}"
    [ -n "$auth_user" ] && echo " 鉴权 : ${auth_user}:${auth_pass}" || echo " 鉴权 : 无"
    echo "=================================="

    local connect_ip="$bind_ip"
    [ "$connect_ip" = "0.0.0.0" ] && connect_ip="127.0.0.1"
    local proxy_args="--socks5-hostname ${connect_ip}:${bind_port}"
    if [ -n "$auth_user" ]; then proxy_args="--socks5-hostname ${auth_user}:${auth_pass}@${connect_ip}:${bind_port}"; fi

    info "正在验证隧道连通性..."
    if curl -sS --max-time 8 $proxy_args "https://www.cloudflare.com/cdn-cgi/trace" | grep -q "warp=on\|warp=plus"; then
        ok "隧道验证成功：MASQUE 已连接。"
    else
        warn "隧道未生效或连接失败。"
    fi
}

# ── 主循环 ──────────────────────────────────────────────────────────────────
while true; do
    get_status_info; clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}       CF-WARP MASQUE 面板     ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $panel_status"
    echo -e "${GREEN}版本 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}绑定 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1. 安装 WARP${RESET}"
    echo -e "${GREEN} 2. 更新 WARP${RESET}"
    echo -e "${GREEN} 3. 卸载 WARP${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 WARP${RESET}"
    echo -e "${GREEN} 6. 停止 WARP${RESET}"
    echo -e "${GREEN} 7. 重启 WARP${RESET}"
    echo -e "${GREEN} 8. 查看日志${RESET}"
    echo -e "${GREEN} 9. 查看配置与出口状态${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    


    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice

    case "$choice" in
        1) menu_install ;;
        2) menu_update ;;
        3) menu_uninstall ;;
        4) menu_edit_config ;;
        5) systemctl start "$SERVICE_NAME" && ok "启动成功" ;;
        6) systemctl stop "$SERVICE_NAME" && ok "停止成功" ;;
        7) systemctl restart "$SERVICE_NAME" && ok "重启成功" ;;
        8) (trap 'echo ""' INT; journalctl -u "$SERVICE_NAME" -n 50 -f) ;;
        9) menu_show_node_config ;;
        0) clear; exit 0 ;;
        *) warn "无效选项"; sleep 1 ;;
    esac
    echo -e "\n按任意键返回..."
    read -n 1 -s -r
done
