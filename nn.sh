#!/bin/bash

# ==============================================================================
# Xray VLESS-Reality Multi-System Management Script
# ==============================================================================

set -euo pipefail

# --- 路径与常量 ---
readonly SCRIPT_VERSION="V-Universal-3.0"
readonly XRAY_CONF_PATH="/usr/local/etc/xray/config.json"
readonly XRAY_BIN_PATH="/usr/local/bin/xray"
readonly INSTALL_URL="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"

# --- 颜色与图标 ---
readonly C_RED='\033[0;31m'    C_GREEN='\033[0;32m'  C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'   C_MAG='\033[0;35m'    C_CYAN='\033[0;36m'
readonly C_NONE='\033[0m'      C_BOLD='\033[1m'

# --- 辅助函数 ---
log_error()   { echo -e "${C_RED}[✘] $1${C_NONE}"; }
log_info()    { echo -e "${C_YELLOW}[!] $1${C_NONE}"; }
log_success() { echo -e "${C_GREEN}[✔] $1${C_NONE}"; }

# 获取包管理器
get_pkg_manager() {
    if command -v apt &>/dev/null; then echo "apt";
    elif command -v dnf &>/dev/null; then echo "dnf";
    elif command -v yum &>/dev/null; then echo "yum";
    elif command -v pacman &>/dev/null; then echo "pacman";
    else echo "unknown"; fi
}

# 依赖自动安装 (多系统支持)
install_deps() {
    local pm=$(get_pkg_manager)
    local deps=("jq" "curl" "wget" "tar" "openssl")
    
    case $pm in
        apt)
            apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y "${deps[@]}" &>/dev/null ;;
        dnf|yum)
            $pm install -y "${deps[@]}" &>/dev/null ;;
        pacman)
            pacman -Sy --noconfirm "${deps[@]}" &>/dev/null ;;
        *)
            log_error "不支持的包管理器，请手动安装: ${deps[*]}" && exit 1 ;;
    esac
}

# 获取 BBR 状态
get_bbr_status() {
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${C_GREEN}已开启 (BBR)${C_NONE}"
    else
        echo -e "${C_RED}未开启${C_NONE}"
    fi
}

# 增强型 UUID 生成
generate_uuid() {
    local uuid
    if [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        # 兜底方案
        python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || \
        openssl rand -hex 4 | tr -d '\n'; echo "-$(openssl rand -hex 2)-4$(openssl rand -hex 1 | cut -c 2-)-$(openssl rand -hex 2 | cut -c 1)8$(openssl rand -hex 1 | cut -c 2-)-$(openssl rand -hex 6)"
    fi
}

# --- 核心 UI 排版 ---
draw_line() { echo -e "${C_CYAN}────────────────────────────────────────────────────────────${C_NONE}"; }

show_status() {
    local version_info service_status
    if [[ ! -f "$XRAY_BIN_PATH" ]]; then
        version_info="${C_RED}未安装${C_NONE}"
        service_status="${C_RED}○ Off${C_NONE}"
    else
        local v=$($XRAY_BIN_PATH version | head -n 1 | awk '{print $2}')
        version_info="${C_CYAN}$v${C_NONE}"
        if systemctl is-active --quiet xray; then
            service_status="${C_GREEN}● Running${C_NONE}"
        else
            service_status="${C_RED}◌ Stopped${C_NONE}"
        fi
    fi

    echo -e " 核心版本: $version_info"
    echo -e " 服务状态: $service_status"
    echo -e " 系统加速: $(get_bbr_status)"
}

# --- 逻辑重写 (核心安装) ---
run_install() {
    local port=$1 uuid=$2 domain=$3
    log_info "正在通过官方脚本安装 Xray 核心..."
    bash <(curl -L "$INSTALL_URL") install &>/dev/null
    
    # 密钥生成
    local key_pair=$($XRAY_BIN_PATH x25519)
    local priv=$(echo "$key_pair" | awk '/Private key:/ {print $3}')
    local pub=$(echo "$key_pair" | awk '/Public key:/ {print $3}')
    
    # 写入配置 (调用原有的 write_config 逻辑)
    write_config "$port" "$uuid" "$domain" "$priv" "$pub"
    
    systemctl enable xray &>/dev/null
    systemctl restart xray
    log_success "安装部署完成！"
}

# --- 主菜单界面 ---
main_menu() {
    while true; do
        clear
        echo -e "${C_BOLD}${C_MAG}╔══════════════════════════════════════════════════════════╗${C_NONE}"
        echo -e "${C_BOLD}${C_MAG}║          Xray VLESS-Reality 管理脚本 ${C_CYAN}($SCRIPT_VERSION)${C_MAG}     ║${C_NONE}"
        echo -e "${C_BOLD}${C_MAG}╚══════════════════════════════════════════════════════════╝${C_NONE}"
        show_status
        draw_line
        echo -e "  ${C_GREEN}1.${C_NONE} 安装/重装 节点"
        echo -e "  ${C_GREEN}2.${C_NONE} 更新 Xray 核心"
        echo -e "  ${C_YELLOW}3.${C_NONE} 重启服务"
        echo -e "  ${C_RED}4.${C_NONE} 卸载服务"
        draw_line
        echo -e "  ${C_CYAN}5.${C_NONE} 修改配置 (Port/UUID/SNI)"
        echo -e "  ${C_CYAN}6.${C_NONE} 查看订阅链接"
        echo -e "  ${C_CYAN}7.${C_NONE} 查看实时日志"
        draw_line
        echo -e "  ${C_BOLD}0. 退出脚本${C_NONE}"
        echo ""
        read -rp "请选择操作 [0-7]: " choice

        case $choice in
            1) install_xray ;;
            2) update_xray ;;
            3) restart_xray ;;
            4) uninstall_xray ;;
            5) modify_config ;;
            6) view_subscription_info ;;
            7) view_xray_log ;;
            0) exit 0 ;;
            *) log_error "无效选项" ;;
        esac
        read -n 1 -s -r -p "按任意键返回菜单..."
    done
}

# 脚本入口
pre_check
install_deps
main_menu
