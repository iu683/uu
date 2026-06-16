#!/usr/bin/env bash
#
# nftables 端口转发管理工具 (全功能版: Alpine/双栈/域名动态同步/备份与恢复)
#

# ============== 常量定义 ==============
CONF_DIR="/etc/nftables.d"
CONF_FILE="${CONF_DIR}/port-forward.conf"
BACKUP_DIR="${CONF_DIR}/backups"
MAIN_CONF="/etc/nftables.conf"
LOG_FILE="/var/log/nft-forward.log"
CRON_DDNS_SCRIPT="${CONF_DIR}/ddns_sync.sh"

# ============== 颜色定义 ==============
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

# ============== 辅助输出 ==============
info()   { printf '\033[32m[信息]\033[0m %s\n' "$1"; }
warn()   { printf '\033[33m[警告]\033[0m %s\n' "$1"; }
err()    { printf '\033[31m[错误]\033[0m %s\n' "$1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "此脚本需要 root 权限运行。"
        exit 1
    fi
}

is_alpine() {
    [[ -f /etc/alpine-release ]]
}

is_nftables_active() {
    if is_alpine; then
        rc-service nftables status 2>/dev/null | grep -q "started"
    else
        systemctl is-active --quiet nftables 2>/dev/null
    fi
}

get_nft_version() {
    if command -v nft &>/dev/null; then
        nft --version 2>/dev/null | awk '{print $2}'
    else
        echo "未安装"
    fi
}

restart_and_enable_nft() {
    if is_alpine; then
        rc-update add nftables default >/dev/null 2>&1 || true
        rc-service nftables restart >/dev/null 2>&1 || true
    else
        systemctl enable --now nftables >/dev/null 2>&1 || true
        systemctl restart nftables >/dev/null 2>&1 || true
    fi
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

detect_ip_type() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.' ok=1
        read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if (( octet > 255 )); then ok=0; fi
        done
        [[ $ok -eq 1 ]] && { echo "4"; return; }
    fi
    if [[ "$ip" =~ : ]] && [[ ! "$ip" =~ [^0-9a-fA-F:] ]]; then
        echo "6"
        return
    fi
    if [[ "$ip" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "2"
        return
    fi
    echo "1"
}

resolve_domain() {
    local domain="$1"
    local resolved=""
    if command -v getent &>/dev/null; then
        resolved=$(getent ahosts "$domain" | awk '{print $1}' | head -n1)
    elif command -v nslookup &>/dev/null; then
        resolved=$(nslookup "$domain" 2>/dev/null | awk '/^Address: / { print $2 }' | head -n1)
    fi
    if [[ -z "$resolved" ]]; then
        resolved=$(ping -c 1 -W 1 "$domain" 2>/dev/null | head -n1 | awk -F'[()]' '{print $2}')
    fi
    echo "$resolved"
}

detect_pkg_manager() {
    if is_alpine; then echo "apk"
    elif command -v apt-get &>/dev/null; then echo "apt"
    elif command -v dnf &>/dev/null; then echo "dnf"
    elif command -v yum &>/dev/null; then echo "yum"
    else echo "unknown"; fi
}

enable_ip_forward() {
    if is_alpine; then
        mkdir -p /etc/sysctl.d
        cat > /etc/sysctl.d/forward.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
        sysctl -p /etc/sysctl.d/forward.conf >/dev/null 2>&1 || true
    else
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
        mkdir -p "$(dirname "${SYSCTL_CONF}")"
        cat > "${SYSCTL_CONF}" <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
        sysctl -p "${SYSCTL_CONF}" >/dev/null 2>&1 || true
    fi
}

init_conf() {
    mkdir -p "${CONF_DIR}" "${BACKUP_DIR}" 2>/dev/null || return 1
    touch "${LOG_FILE}" 2>/dev/null || true

    if [[ ! -f "${MAIN_CONF}" ]]; then
        cat > "${MAIN_CONF}" <<'NFTCONF'
#!/usr/sbin/nft -f
flush ruleset
include "/etc/nftables.d/*.conf"
NFTCONF
        chmod +x "${MAIN_CONF}" 2>/dev/null || true
    elif ! grep -qF 'include "/etc/nftables.d/*.conf"' "${MAIN_CONF}" 2>/dev/null; then
        echo 'include "/etc/nftables.d/*.conf"' >> "${MAIN_CONF}"
    fi
}

declare -a RULES=()

sanitize_note() {
    printf "%s" "${1//|/ }"
}

load_rules() {
    RULES=()
    [[ -f "${CONF_FILE}" ]] || return
    local pending_note="" pending_domain=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*备注:[[:space:]]*(.*)$ ]]; then
            pending_note=$(sanitize_note "${BASH_REMATCH[1]}")
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*DOMAIN:[[:space:]]*(.*)$ ]]; then
            pending_domain="${BASH_REMATCH[1]}"
            continue
        fi
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        
        if [[ "$line" =~ tcp\ dport\ ([0-9]+)\ dnat\ to\ ([0-9.]+):([0-9]+) ]]; then
            local lp="${BASH_REMATCH[1]}"
            local dp="${BASH_REMATCH[3]}"
            if [[ -n "${pending_domain:-}" ]]; then
                RULES+=("${lp}|${pending_domain}|${dp}|${pending_note}")
            else
                RULES+=("${lp}|${BASH_REMATCH[2]}|${dp}|${pending_note}")
            fi
            pending_note=""
            pending_domain=""
        elif [[ "$line" =~ tcp\ dport\ ([0-9]+)\ dnat\ ip6\ to\ \[(.*)\]:([0-9]+) ]] || [[ "$line" =~ tcp\ dport\ ([0-9]+)\ dnat\ ip6\ to\ ([0-9a-fA-F:]+):([0-9]+) ]]; then
            local lp="${BASH_REMATCH[1]}"
            local dp="${BASH_REMATCH[3]}"
            [[ "$line" =~ dnat\ ip6\ to\ \[(.*)\]:([0-9]+) ]] && dp="${BASH_REMATCH[2]}"
            
            if [[ -n "${pending_domain:-}" ]]; then
                RULES+=("${lp}|${pending_domain}|${dp}|${pending_note}")
            else
                local extracted_ip="${BASH_REMATCH[2]}"
                [[ "$line" =~ dnat\ ip6\ to\ \[(.*)\]:([0-9]+) ]] && extracted_ip="${BASH_REMATCH[1]}"
                RULES+=("${lp}|${extracted_ip}|${dp}|${pending_note}")
            fi
            pending_note=""
            pending_domain=""
        fi
    done < "${CONF_FILE}"
}

write_conf_file() {
    local tmp_file="${CONF_FILE}.tmp.$$"
    cat > "${tmp_file}" <<EOF
#!/usr/sbin/nft -f
table ip port_forward_v4 { destroy; }
table ip6 port_forward_v6 { destroy; }
table ip port_forward_v4 {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
EOF

    local rule lport target dport note type actual_ip
    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport target dport note <<< "$rule"
        type=$(detect_ip_type "$target")
        actual_ip="$target"
        [[ "$type" == "2" ]] && actual_ip=$(resolve_domain "$target")
        if [[ "$(detect_ip_type "$actual_ip")" == "4" ]]; then
            echo "        # 备注: ${note}" >> "${tmp_file}"
            [[ "$type" == "2" ]] && echo "        # DOMAIN: ${target}" >> "${tmp_file}"
            echo "        tcp dport ${lport} dnat to ${actual_ip}:${dport}" >> "${tmp_file}"
            echo "        udp dport ${lport} dnat to ${actual_ip}:${dport}" >> "${tmp_file}"
        fi
    done

    cat >> "${tmp_file}" <<EOF
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
EOF

    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport target dport note <<< "$rule"
        type=$(detect_ip_type "$target")
        actual_ip="$target"
        [[ "$type" == "2" ]] && actual_ip=$(resolve_domain "$target")
        if [[ "$(detect_ip_type "$actual_ip")" == "4" ]]; then
            echo "        ip daddr ${actual_ip} tcp dport ${dport} ct status dnat masquerade" >> "${tmp_file}"
            echo "        ip daddr ${actual_ip} udp dport ${dport} ct status dnat masquerade" >> "${tmp_file}"
        fi
    done

    cat >> "${tmp_file}" <<EOF
    }
}
table ip6 port_forward_v6 {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
EOF

    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport target dport note <<< "$rule"
        type=$(detect_ip_type "$target")
        actual_ip="$target"
        [[ "$type" == "2" ]] && actual_ip=$(resolve_domain "$target")
        if [[ "$(detect_ip_type "$actual_ip")" == "6" ]]; then
            echo "        # 备注: ${note}" >> "${tmp_file}"
            [[ "$type" == "2" ]] && echo "        # DOMAIN: ${target}" >> "${tmp_file}"
            echo "        tcp dport ${lport} dnat ip6 to [${actual_ip}]:${dport}" >> "${tmp_file}"
            echo "        udp dport ${lport} dnat ip6 to [${actual_ip}]:${dport}" >> "${tmp_file}"
        fi
    done

    cat >> "${tmp_file}" <<EOF
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
EOF

    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport target dport note <<< "$rule"
        type=$(detect_ip_type "$target")
        actual_ip="$target"
        [[ "$type" == "2" ]] && actual_ip=$(resolve_domain "$target")
        if [[ "$(detect_ip_type "$actual_ip")" == "6" ]]; then
            echo "        ip6 daddr ${actual_ip} tcp dport ${dport} ct status dnat masquerade" >> "${tmp_file}"
            echo "        ip6 daddr ${actual_ip} udp dport ${dport} ct status dnat masquerade" >> "${tmp_file}"
        fi
    done
    cat >> "${tmp_file}" <<EOF
    }
}
EOF
    mv -f "${tmp_file}" "${CONF_FILE}" 2>/dev/null
}

reload_rules() {
    nft -f "${CONF_FILE}"
}

setup_ddns_cron() {
    cat > "${CRON_DDNS_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
CONF_FILE="/etc/nftables.d/port-forward.conf"
[[ -f "$CONF_FILE" ]] || exit 0
if grep -q "DOMAIN:" "$CONF_FILE"; then
EOF
    echo "    $(realpath "$0") --reload-backend" >> "${CRON_DDNS_SCRIPT}"
    echo "fi" >> "${CRON_DDNS_SCRIPT}"
    chmod +x "${CRON_DDNS_SCRIPT}" 2>/dev/null

    if ! crontab -l 2>/dev/null | grep -q "${CRON_DDNS_SCRIPT}"; then
        (crontab -l 2>/dev/null; echo "*/5 * * * * ${CRON_DDNS_SCRIPT} >/dev/null 2>&1") | crontab - 2>/dev/null || true
    fi
}

# ============== 备份与恢复模块 ==============
do_backup_manual() {
    if [[ ! -f "${CONF_FILE}" ]] || [[ ! -s "${CONF_FILE}" ]]; then
        err "当前没有任何生效的规则配置文件，无需备份。"
        return
    fi
    mkdir -p "${BACKUP_DIR}"
    local bkp_name="manual_forward_bak_$(date '+%Y%m%d_%H%M%S').conf"
    cp "${CONF_FILE}" "${BACKUP_DIR}/${bkp_name}"
    info "手动备份成功！备份文件已保存至: ${YELLOW}${BACKUP_DIR}/${bkp_name}${RESET}"
}

do_restore_manual() {
    if [[ ! -d "${BACKUP_DIR}" ]]; then
        err "未检测到任何备份目录。"
        return
    fi
    
    local bkp_files=($(ls "${BACKUP_DIR}"/*.conf 2>/dev/null | sort -r))
    if [[ ${#bkp_files[@]} -eq 0 ]]; then
        err "备份文件夹内没有发现可用的 .conf 备份文件。"
        return
    fi

    echo -e "\n${YELLOW}=== 历史备份文件列表 ===${RESET}"
    local idx=1 file
    for file in "${bkp_files[@]}"; do
        printf "[%2s] %s\n" "$idx" "$(basename "$file")"
        ((idx++))
    done
    echo "========================"
    
    read -rp "请选择需要恢复的备份序号 (0 取消): " choice
    if [[ -z "$choice" || "$choice" == "0" ]]; then return; fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#bkp_files[@]} )); then
        local selected_file="${bkp_files[$((choice-1))]}"
        
        # 恢复前对当前环境做一次紧急兜底备份
        if [[ -f "${CONF_FILE}" ]]; then
            cp "${CONF_FILE}" "${BACKUP_DIR}/auto_emergency_before_restore.conf"
        fi
        
        cp -f "${selected_file}" "${CONF_FILE}"
        if reload_rules; then
            info "历史备份恢复并应用成功！"
            setup_ddns_cron
        else
            err "载入备份文件失败，正在尝试回滚旧配置..."
            [[ -f "${BACKUP_DIR}/auto_emergency_before_restore.conf" ]] && cp -f "${BACKUP_DIR}/auto_emergency_before_restore.conf" "${CONF_FILE}"
            reload_rules
        fi
    else
        err "无效的序号输入"
    fi
}

# ============== 传统业务功能 ==============
do_install() {
    if ! command -v nft &>/dev/null; then
        info "准备安装依赖..."
        local pm=$(detect_pkg_manager)
        case "$pm" in
            apk) apk add nftables bash curl iproute2 ;;
            *) $pm update -y && $pm install -y nftables curl ;;
        esac
    fi
    enable_ip_forward && init_conf && restart_and_enable_nft && setup_ddns_cron
    info "环境初始化圆满完成！已开启每5分钟域名动态同步机制。"
}

do_list() {
    load_rules
    if [[ ${#RULES[@]} -eq 0 ]]; then info "当前没有配置任何端口转发规则。"; return; fi
    printf "\n\033[1m%-6s %-8s %-10s    %-35s %s\033[0m\n" "序号" "类型" "本机端口" "目标地址/域名" "备注"
    echo "────────────────────────────────────────────────────────────────────────────────────────"
    local idx=1 rule lport target dport note type label
    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport target dport note <<< "$rule"
        type=$(detect_ip_type "$target")
        if [[ "$type" == "2" ]]; then label="域名"; else [[ "$type" == "6" ]] && label="IPv6" || label="IPv4"; fi
        if [[ "$type" == "6" ]]; then
            printf "%-6s %-8s %-10s -> %-35s %s\n" "$idx" "$label" "$lport" "[${target}]:${dport}" "${note:--}"
        else
            printf "%-6s %-8s %-10s -> %-35s %s\n" "$idx" "$label" "$lport" "${target}:${dport}" "${note:--}"
        fi
        ((idx++))
    done
    echo ""
}

do_add() {
    command -v nft &>/dev/null || { err "nftables 未安装"; return; }
    init_conf || return
    enable_ip_forward && load_rules

    local lport target dport note type
    while true; do
        read -rp "请输入本机监听端口 (1-65535): " lport
        validate_port "$lport" && break
        err "端口输入无效"
    done
    for rule in "${RULES[@]}"; do
        IFS='|' read -r rp _ _ _ <<< "$rule"
        if [[ "$rp" == "$lport" ]]; then err "本机端口 ${lport} 规则已存在"; return; fi
    done
    while true; do
        read -rp "请输入目标 IP 地址 或 目标域名: " target
        type=$(detect_ip_type "$target")
        if [[ "$type" == "1" ]]; then err "格式不正确"; elif [[ "$type" == "2" ]]; then
            local rip=$(resolve_domain "$target")
            [[ -z "$rip" ]] && warn "该域名目前解析不出 IP，系统稍后会自动重试。" || info "成功解析当前 IP 为: ${rip}"
            break
        else break; fi
    done
    while true; do
        read -rp "请输入目标端口 [默认 $lport]: " dport
        dport="${dport:-$lport}"
        validate_port "$dport" && break
        err "目标端口不合法"
    done
    read -rp "请输入本条转发备注: " note
    note=$(sanitize_note "$note")

    RULES+=("${lport}|${target}|${dport}|${note}")
    write_conf_file && reload_rules && setup_ddns_cron && info "规则添加并加载成功！" || err "配置重载失败"
}

do_delete() {
    load_rules
    if [[ ${#RULES[@]} -eq 0 ]]; then info "无规则可供删除。"; return; fi
    do_list
    read -rp "请输入要删除的规则序号 (0 取消): " choice
    if [[ -z "$choice" || "$choice" == "0" ]]; then return; fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#RULES[@]} )); then
        unset 'RULES[$((choice-1))]'
        RULES=("${RULES[@]}")
        write_conf_file && reload_rules && info "成功删除规则。"
    else err "无效序号"; fi
}

do_clear_all() {
    load_rules
    if [[ ${#RULES[@]} -eq 0 ]]; then return; fi
    read -rp "确认彻底清空所有规则？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return
    RULES=()
    write_conf_file && reload_rules
    crontab -l 2>/dev/null | grep -v "${CRON_DDNS_SCRIPT}" | crontab - 2>/dev/null || true
    rm -f "${CRON_DDNS_SCRIPT}" 2>/dev/null
    info "已全部清空。"
}

do_diagnose() {
    echo -e "\n========================================"
    echo "            系统环境自检"
    echo "========================================"
    info "系统环境: $(is_alpine && echo 'Alpine Linux' || echo '标准 Linux (Systemd)')"
    info "nftables 服务状态: $(is_nftables_active && echo '运行中' || echo '未运行')"
}

# ============== 交互菜单主循环 ==============
main_menu() {
    check_root
    if [[ "${1:-}" == "--reload-backend" ]]; then
        load_rules
        [[ ${#RULES[@]} -gt 0 ]] && { write_conf_file; reload_rules; }
        exit 0
    fi

    local panel_status panel_version panel_rules_count
    while true; do
        is_nftables_active && panel_status="${GREEN}运行中${RESET}" || panel_status="${RED}未运行${RESET}"
        panel_version=$(get_nft_version)
        load_rules
        panel_rules_count="${#RULES[@]}"

        echo -e "${GREEN}========================================${RESET}"
        echo -e "${GREEN}    nftables 转发面板 (完美终极版)     ${RESET}"
        echo -e "${GREEN}========================================${RESET}"
        echo -e "${GREEN} 状态 :${RESET} $panel_status"
        echo -e "${GREEN} 版本 :${RESET} ${YELLOW}${panel_version}${RESET}"
        echo -e "${GREEN} 规则 :${RESET} 已载入 ${YELLOW}${panel_rules_count}${RESET} 条转发"
        echo -e "${GREEN}========================================${RESET}"
        echo -e "${GREEN} 1. 安装 / 初始化环境 (支持域名/双栈)${RESET}"
        echo -e "${GREEN} 2. 查看当前转发规则${RESET}"
        echo -e "${GREEN} 3. 新增转发规则 (自动识别 IP / 域名)${RESET}"
        echo -e "${GREEN} 4. 删除特定端口转发${RESET}"
        echo -e "${GREEN} 5. 一键清空所有转发规则${RESET}"
        echo -e "${GREEN} 6. 运行系统环境自检${RESET}"
        echo -e "${GREEN} 7. 备份当前转发规则${RESET}"
        echo -e "${GREEN} 8. 恢复历史转发规则${RESET}"
        echo -e "${GREEN} 0. 退出面板${RESET}"
        echo -e "${GREEN}========================================${RESET}"
        
        read -rp "请选择操作 [0-8]: " menu_choice
        case "$menu_choice" in
            1) do_install ;;
            2) do_list ;;
            3) do_add ;;
            4) do_delete ;;
            5) do_clear_all ;;
            6) do_diagnose ;;
            7) do_backup_manual ;;
            8) do_restore_manual ;;
            0) info "感谢使用。" && exit 0 ;;
            *) err "输入错误" ;;
        esac
        echo ""
    done
}

main_menu "$@"
