#!/usr/bin/env bash
#
# nftables 端口转发管理工具 (经典菜单格式 + 终极完全体版)
#

# ============== 常量定义 ==============
CONF_DIR="/etc/nftables.d"
CONF_FILE="${CONF_DIR}/port-forward.conf"
DEFAULT_BACKUP_DIR="${CONF_DIR}/backups"
MAIN_CONF="/etc/nftables.conf"
SYSCTL_CONF="/etc/sysctl.d/99-nft-forward.conf" # 完美的独立配置文件，保留！
LOG_FILE="/var/log/nft-forward.log"
CRON_DDNS_SCRIPT="${CONF_DIR}/ddns_sync.sh"
LOCAL_SCRIPT_PATH="${CONF_DIR}/port_forward_main.sh" # 本地化固定的脚本路径
BIN_LINK_DIR="/usr/local/bin"                        # 系统可执行文件目录

# ============== 颜色定义 ==============
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

# ============== 辅助输出 ==============
info()   { printf '\033[32m[信息]\033[0m %s\n' "$1"; }
warn()   { printf '\033[33m[警告]\033[0m %s\n' "$1"; }
err()    { printf '\033[31m[错误]\033[0m %s\n' "$1"; }

pause_to_menu() {
    echo ""
    read -rp "$(echo -e "${GREEN}按任意键或回车返回主菜单...${RESET}")" _unused
}

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

disable_ip_forward() {
    if is_alpine; then
        rm -f /etc/sysctl.d/forward.conf 2>/dev/null
    else
        rm -f "${SYSCTL_CONF}" 2>/dev/null
    fi
}

init_conf() {
    mkdir -p "${CONF_DIR}" "${DEFAULT_BACKUP_DIR}" 2>/dev/null || return 1
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
    local pending_note="" pending_domain="" pending_proto="ALL"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*备注:[[:space:]]*(.*)$ ]]; then
            pending_note=$(sanitize_note "${BASH_REMATCH[1]}")
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*DOMAIN:[[:space:]]*(.*)$ ]]; then
            pending_domain="${BASH_REMATCH[1]}"
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*PROTO:[[:space:]]*(.*)$ ]]; then
            pending_proto="${BASH_REMATCH[1]}"
            continue
        fi
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        
        if [[ "$line" =~ (tcp|udp)\ dport\ ([0-9]+)\ dnat\ to\ ([0-9.]+):([0-9]+) ]]; then
            local matched_proto="${BASH_REMATCH[1]}"
            local lp="${BASH_REMATCH[2]}"
            local dp="${BASH_REMATCH[4]}"
            local current_target="${BASH_REMATCH[3]}"
            
            local exists=0 rp
            for rule in "${RULES[@]}"; do
                IFS='|' read -r rp _ _ _ _ <<< "$rule"
                if [[ "$rp" == "$lp" ]]; then exists=1; break; fi
            done
            if [[ $exists -eq 0 ]]; then
                local final_proto="${pending_proto:-ALL}"
                if [[ "${pending_proto:-}" == "ALL" ]]; then
                    if ! grep -q "${matched_proto/tcp/udp}\ dport\ ${lp}" "${CONF_FILE}"; then
                        final_proto="${matched_proto^^}"
                    fi
                fi
                if [[ -n "${pending_domain:-}" ]]; then
                    RULES+=("${lp}|${pending_domain}|${dp}|${pending_note}|${final_proto}")
                else
                    RULES+=("${lp}|${current_target}|${dp}|${pending_note}|${final_proto}")
                fi
            fi
            pending_note="" pending_domain="" pending_proto="ALL"

        elif [[ "$line" =~ (tcp|udp)\ dport\ ([0-9]+)\ dnat\ ip6\ to\ \[(.*)\]:([0-9]+) ]] || [[ "$line" =~ (tcp|udp)\ dport\ ([0-9]+)\ dnat\ ip6\ to\ ([0-9a-fA-F:]+):([0-9]+) ]]; then
            local lp="${BASH_REMATCH[2]}"
            local dp="${BASH_REMATCH[4]}"
            local extracted_ip="${BASH_REMATCH[3]}"
            
            local exists=0 rp
            for rule in "${RULES[@]}"; do
                IFS='|' read -r rp _ _ _ _ <<< "$rule"
                if [[ "$rp" == "$lp" ]]; then exists=1; break; fi
            done
            if [[ $exists -eq 0 ]]; then
                local final_proto="${pending_proto:-ALL}"
                if [[ -n "${pending_domain:-}" ]]; then
                    RULES+=("${lp}|${pending_domain}|${dp}|${pending_note}|${final_proto}")
                else
                    RULES+=("${lp}|${extracted_ip}|${dp}|${pending_note}|${final_proto}")
                fi
            fi
            pending_note="" pending_domain="" pending_proto="ALL"
        fi
    done < "${CONF_FILE}"
}

write_conf_file() {
    local tmp_file="${CONF_FILE}.tmp.$$"
    cat > "${tmp_file}" <<EOF
#!/usr/sbin/nft -f

add table ip port_forward_v4
flush table ip port_forward_v4
add table ip6 port_forward_v6
flush table ip6 port_forward_v6

table ip port_forward_v4 {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
EOF

    local rule lport target dport note proto type actual_ip
    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport target dport note proto <<< "$rule"
        proto="${proto:-ALL}"
        type=$(detect_ip_type "$target")
        actual_ip="$target"
        [[ "$type" == "2" ]] && actual_ip=$(resolve_domain "$target")
        if [[ "$(detect_ip_type "$actual_ip")" == "4" ]]; then
            echo "        # 备注: ${note}" >> "${tmp_file}"
            echo "        # PROTO: ${proto}" >> "${tmp_file}"
            [[ "$type" == "2" ]] && echo "        # DOMAIN: ${target}" >> "${tmp_file}"
            if [[ "$proto" == "ALL" || "$proto" == "TCP" ]]; then
                echo "        tcp dport ${lport} dnat to ${actual_ip}:${dport}" >> "${tmp_file}"
            fi
            if [[ "$proto" == "ALL" || "$proto" == "UDP" ]]; then
                echo "        udp dport ${lport} dnat to ${actual_ip}:${dport}" >> "${tmp_file}"
            fi
        fi
    done

    cat >> "${tmp_file}" <<EOF
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
EOF

    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport target dport note proto <<< "$rule"
        proto="${proto:-ALL}"
        type=$(detect_ip_type "$target")
        actual_ip="$target"
        [[ "$type" == "2" ]] && actual_ip=$(resolve_domain "$target")
        if [[ "$(detect_ip_type "$actual_ip")" == "4" ]]; then
            if [[ "$proto" == "ALL" || "$proto" == "TCP" ]]; then
                echo "        ip daddr ${actual_ip} tcp dport ${dport} ct status dnat masquerade" >> "${tmp_file}"
            fi
            if [[ "$proto" == "ALL" || "$proto" == "UDP" ]]; then
                echo "        ip daddr ${actual_ip} udp dport ${dport} ct status dnat masquerade" >> "${tmp_file}"
            fi
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
        IFS='|' read -r lport target dport note proto <<< "$rule"
        proto="${proto:-ALL}"
        type=$(detect_ip_type "$target")
        actual_ip="$target"
        [[ "$type" == "2" ]] && actual_ip=$(resolve_domain "$target")
        if [[ "$(detect_ip_type "$actual_ip")" == "6" ]]; then
            echo "        # 备注: ${note}" >> "${tmp_file}"
            echo "        # PROTO: ${proto}" >> "${tmp_file}"
            [[ "$type" == "2" ]] && echo "        # DOMAIN: ${target}" >> "${tmp_file}"
            if [[ "$proto" == "ALL" || "$proto" == "TCP" ]]; then
                echo "        tcp dport ${lport} dnat ip6 to [${actual_ip}]:${dport}" >> "${tmp_file}"
            fi
            if [[ "$proto" == "ALL" || "$proto" == "UDP" ]]; then
                echo "        udp dport ${lport} dnat ip6 to [${actual_ip}]:${dport}" >> "${tmp_file}"
            fi
        fi
    done

    cat >> "${tmp_file}" <<EOF
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
EOF

    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport target dport note proto <<< "$rule"
        proto="${proto:-ALL}"
        type=$(detect_ip_type "$target")
        actual_ip="$target"
        [[ "$type" == "2" ]] && actual_ip=$(resolve_domain "$target")
        if [[ "$(detect_ip_type "$actual_ip")" == "6" ]]; then
            if [[ "$proto" == "ALL" || "$proto" == "TCP" ]]; then
                echo "        ip6 daddr ${actual_ip} tcp dport ${dport} ct status dnat masquerade" >> "${tmp_file}"
            fi
            if [[ "$proto" == "ALL" || "$proto" == "UDP" ]]; then
                echo "        ip6 daddr ${actual_ip} udp dport ${dport} ct status dnat masquerade" >> "${tmp_file}"
            fi
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
    cat > "${CRON_DDNS_SCRIPT}" <<EOF
#!/usr/bin/env bash
CONF_FILE="/etc/nftables.d/port-forward.conf"
[[ -f "\$CONF_FILE" ]] || exit 0
if grep -q "DOMAIN:" "\$CONF_FILE"; then
    ${LOCAL_SCRIPT_PATH} --reload-backend
fi
EOF
    chmod +x "${CRON_DDNS_SCRIPT}" 2>/dev/null

    if ! crontab -l 2>/dev/null | grep -q "${CRON_DDNS_SCRIPT}"; then
        (crontab -l 2>/dev/null; echo "*/5 * * * * ${CRON_DDNS_SCRIPT} >/dev/null 2>&1") | crontab - 2>/dev/null || true
    fi
}

do_backup_manual() {
    if [[ ! -f "${CONF_FILE}" ]] || [[ ! -s "${CONF_FILE}" ]]; then
        err "当前没有任何生效的规则配置文件，无需导出备份。"
        pause_to_menu
        return
    fi
    local target_dir
    read -rp "$(echo -e "${GREEN}请输入备份导出目录 [默认: ${DEFAULT_BACKUP_DIR}]: ${RESET}")" target_dir
    target_dir="${target_dir:-$DEFAULT_BACKUP_DIR}"
    
    mkdir -p "${target_dir}" 2>/dev/null
    if [[ ! -d "${target_dir}" ]]; then
        err "无法创建或访问指定目录: ${target_dir}"
        pause_to_menu
        return
    fi

    local bkp_name="manual_forward_bak_$(date '+%Y%m%d_%H%M%S').conf"
    cp "${CONF_FILE}" "${target_dir}/${bkp_name}"
    info "手动导出成功！备份已保存至: ${YELLOW}${target_dir}/${bkp_name}${RESET}"
    pause_to_menu
}

do_restore_manual() {
    local target_dir
    read -rp "$(echo -e "${GREEN}请输入备份所在的导入目录 [默认: ${DEFAULT_BACKUP_DIR}]: ${RESET}")" target_dir
    target_dir="${target_dir:-$DEFAULT_BACKUP_DIR}"

    if [[ ! -d "${target_dir}" ]]; then
        err "指定的目录不存在: ${target_dir}"
        pause_to_menu
        return
    fi
    local bkp_files=($(ls "${target_dir}"/*.conf 2>/dev/null | sort -r))
    if [[ ${#bkp_files[@]} -eq 0 ]]; then
        err "该文件夹内没有发现任何可用的 .conf 备份文件。"
        pause_to_menu
        return
    fi

    echo -e "\n${YELLOW}=== 发现历史备份文件列表 ===${RESET}"
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
        if [[ -f "${CONF_FILE}" ]]; then
            cp "${CONF_FILE}" "${DEFAULT_BACKUP_DIR}/auto_emergency_before_restore.conf" 2>/dev/null || true
        fi
        cp -f "${selected_file}" "${CONF_FILE}"
        if reload_rules; then
            info "历史配置导入并成功应用！"
            setup_ddns_cron
        else
            err "载入备份文件失败，正在回滚原始配置..."
            [[ -f "${DEFAULT_BACKUP_DIR}/auto_emergency_before_restore.conf" ]] && cp -f "${DEFAULT_BACKUP_DIR}/auto_emergency_before_restore.conf" "${CONF_FILE}"
            reload_rules
        fi
    else err "无效的序号输入"; fi
    pause_to_menu
}

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
    info "环境初始化圆满完成！"
    pause_to_menu
}

# 恢复经典的独立规则列出输出
do_list() {
    load_rules
    if [[ ${#RULES[@]} -eq 0 ]]; then 
        info "当前没有配置任何端口转发规则。"
        pause_to_menu
        return
    fi
    printf "\n\033[1m%-6s %-12s %-10s    %-35s %s\033[0m\n" "序号" "协议" "本机端口" "目标地址/域名" "备注"
    echo "────────────────────────────────────────────────────────────────────────────────────────"
    local idx=1 rule lport target dport note proto type label proto_label
    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport target dport note proto <<< "$rule"
        proto="${proto:-ALL}"
        type=$(detect_ip_type "$target")
        if [[ "$type" == "2" ]]; then label="域名"; else [[ "$type" == "6" ]] && label="IPv6" || label="IPv4"; fi
        
        if [[ "$proto" == "ALL" ]]; then proto_label="TCP+UDP"; else proto_label="$proto"; fi
        proto_label="${proto_label} (${label})"

        if [[ "$type" == "6" ]]; then
            printf "%-6s %-12s %-10s -> %-35s %s\n" "$idx" "$proto_label" "$lport" "[${target}]:${dport}" "${note:--}"
        else
            printf "%-6s %-12s %-10s -> %-35s %s\n" "$idx" "$proto_label" "$lport" "${target}:${dport}" "${note:--}"
        fi
        ((idx++))
    done
    echo ""
    pause_to_menu
}

do_add() {
    command -v nft &>/dev/null || { err "nftables 未安装"; pause_to_menu; return; }
    init_conf || return
    enable_ip_forward && load_rules

    local lport target dport note proto proto_choice type
    while true; do
        read -rp "请输入本机监听端口 (1-65535): " lport
        validate_port "$lport" && break
        err "端口输入无效"
    done
    for rule in "${RULES[@]}"; do
        IFS='|' read -r rp _ _ _ _ <<< "$rule"
        if [[ "$rp" == "$lport" ]]; then err "本机端口 ${lport} 规则已存在"; pause_to_menu; return; fi
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

    while true; do
        read -rp "$(echo -e "${GREEN}请选择协议类型 [1: TCP+UDP | 2: 仅 TCP | 3: 仅 UDP] (默认 1): ${RESET}")" proto_choice
        proto_choice="${proto_choice:-1}"
        case "$proto_choice" in
            1) proto="ALL"; break ;;
            2) proto="TCP"; break ;;
            3) proto="UDP"; break ;;
            *) err "选择错误，请输入 1, 2 或 3" ;;
        esac
    done

    read -rp "请输入本条转发备注: " note
    note=$(sanitize_note "$note")

    RULES+=("${lport}|${target}|${dport}|${note}|${proto}")
    if write_conf_file && reload_rules && setup_ddns_cron; then
        info "规则添加并加载成功！"
    else
        err "配置重载失败"
    fi
    pause_to_menu
}

do_delete() {
    load_rules
    if [[ ${#RULES[@]} -eq 0 ]]; then info "无规则可供删除。"; pause_to_menu; return; fi
    
    printf "\n\033[1m%-6s %-12s %-10s    %-35s %s\033[0m\n" "序号" "协议" "本机端口" "目标地址/域名" "备注"
    echo "────────────────────────────────────────────────────────────────────────────────────────"
    local idx=1 rule lport target dport note proto type label proto_label
    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport target dport note proto <<< "$rule"
        proto="${proto:-ALL}"
        type=$(detect_ip_type "$target")
        if [[ "$type" == "2" ]]; then label="域名"; else [[ "$type" == "6" ]] && label="IPv6" || label="IPv4"; fi
        if [[ "$proto" == "ALL" ]]; then proto_label="TCP+UDP"; else proto_label="$proto"; fi
        proto_label="${proto_label} (${label})"

        if [[ "$type" == "6" ]]; then
            printf "%-6s %-12s %-10s -> %-35s %s\n" "$idx" "$proto_label" "$lport" "[${target}]:${dport}" "${note:--}"
        else
            printf "%-6s %-12s %-10s -> %-35s %s\n" "$idx" "$proto_label" "$lport" "${target}:${dport}" "${note:--}"
        fi
        ((idx++))
    done
    echo ""

    read -rp "请输入要删除的规则序号 (0 取消): " choice
    if [[ -z "$choice" || "$choice" == "0" ]]; then return; fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#RULES[@]} )); then
        unset 'RULES[$((choice-1))]'
        RULES=("${RULES[@]}")
        write_conf_file && reload_rules && info "成功删除规则。"
    else 
        err "无效序号"
    fi
    pause_to_menu
}

do_clear_all() {
    load_rules
    if [[ ${#RULES[@]} -eq 0 ]]; then info "当前没有任何转发规则。"; pause_to_menu; return; fi
    read -rp "确认彻底清空所有规则？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return
    RULES=()
    write_conf_file && reload_rules
    crontab -l 2>/dev/null | grep -v "${CRON_DDNS_SCRIPT}" | crontab - 2>/dev/null || true
    rm -f "${CRON_DDNS_SCRIPT}" 2>/dev/null
    info "已全部清空。"
    pause_to_menu
}

do_diagnose() {
    echo -e "\n========================================"
    echo "            系统环境自检"
    echo "========================================"
    info "系统环境: $(is_alpine && echo 'Alpine Linux' || echo '标准 Linux (Systemd)')"
    info "nftables 服务状态: $(is_nftables_active && echo '运行中' || echo '未运行')"
    if crontab -l 2>/dev/null | grep -q "${CRON_DDNS_SCRIPT}"; then
        info "域名同步守护进程: ${GREEN}已挂载${RESET}"
    else
        warn "域名同步守护进程: ${RED}未挂载${RESET}"
    fi
    pause_to_menu
}

do_uninstall() {
    read -rp "确认要彻底卸载本工具并清空所有转发规则吗？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    info "正在清空所有 nftables 转发规则..."
    RULES=()
    write_conf_file && reload_rules 2>/dev/null || true

    info "正在清理定时任务及相关文件..."
    crontab -l 2>/dev/null | grep -v "${CRON_DDNS_SCRIPT}" | crontab - 2>/dev/null || true
    disable_ip_forward

    info "正在拆除 A/a 系统快捷启动链..."
    rm -f "${BIN_LINK_DIR}/A" "${BIN_LINK_DIR}/a" 2>/dev/null

    if [[ -f "${MAIN_CONF}" ]]; then
        if is_alpine; then
            sed -i '\/etc\/nftables.d\/\*\.conf/d' "${MAIN_CONF}" 2>/dev/null || true
        else
            sed -i '/include "\/etc\/nftables.d\/\*\.conf"/d' "${MAIN_CONF}" 2>/dev/null || true
        fi
    fi
    rm -rf "${CONF_DIR}" 2>/dev/null

    echo -e "${GREEN}✅ 纯净卸载成功！转发规则已彻底清除，快捷键已拔除。${RESET}"
    exit 0
}

auto_localize_and_link() {
    mkdir -p "${CONF_DIR}"
    mkdir -p "${BIN_LINK_DIR}"
    
    if [[ ! -f "${LOCAL_SCRIPT_PATH}" ]]; then
        curl -sL "https://raw.githubusercontent.com/iu683/uu/main/vv.sh" -o "${LOCAL_SCRIPT_PATH}"
        chmod +x "${LOCAL_SCRIPT_PATH}"
    fi

    ln -sf "${LOCAL_SCRIPT_PATH}" "${BIN_LINK_DIR}/A"
    ln -sf "${LOCAL_SCRIPT_PATH}" "${BIN_LINK_DIR}/a"

    echo -e "${GREEN}✅ 安装/同步完成，快捷键 [A] 或 [a] 已绑定。${RESET}"
}

main_menu() {
    check_root
    
    if [[ "${1:-}" == "--reload-backend" ]]; then
        load_rules
        [[ ${#RULES[@]} -gt 0 ]] && { write_conf_file; reload_rules; }
        exit 0
    fi

    if [[ "$0" == "bash" || "$0" == "sh" || ! -f "${LOCAL_SCRIPT_PATH}" ]]; then
        auto_localize_and_link
        if [[ "$0" == "bash" || "$0" == "sh" ]]; then
            exec "${LOCAL_SCRIPT_PATH}" "$@"
        fi
    fi

    local panel_status panel_version panel_rules_count
    while true; do
        is_nftables_active && panel_status="${GREEN}运行中${RESET}" || panel_status="${RED}未运行${RESET}"
        panel_version=$(get_nft_version)
        load_rules
        panel_rules_count="${#RULES[@]}"

        # 完全还原回最开始那套经典的精简欢迎大框结构
        echo -e "${GREEN}========================================${RESET}"
        echo -e "${GREEN}    nftables 转发面板 (完美终极版)     ${RESET}"
        echo -e "${GREEN}========================================${RESET}"
        echo -e "${GREEN} 状态 :${RESET} $panel_status"
        echo -e "${GREEN} 版本 :${RESET} ${YELLOW}${panel_version}${RESET}"
        echo -e "${GREEN} 规则 :${RESET} 已载入 ${YELLOW}${panel_rules_count}${RESET} 条转发"
        echo -e "${GREEN}========================================${RESET}"
        echo -e "${GREEN} 1. 安装 / 初始化环境 (支持域名/双栈)${RESET}"
        echo -e "${GREEN} 2. 查看当前转发规则${RESET}"
        echo -e "${GREEN} 3. 新增转发规则 (自动识别 IP / 域名 / 协议)${RESET}"
        echo -e "${GREEN} 4. 删除特定端口转发${RESET}"
        echo -e "${GREEN} 5. 一键清空所有转发规则${RESET}"
        echo -e "${GREEN} 6. 运行系统环境自检${RESET}"
        echo -e "${GREEN} 7. 自定义目录导出规则 (备份)${RESET}"
        echo -e "${GREEN} 8. 自定义目录导入规则 (恢复)${RESET}"
        echo -e "${GREEN} 9. 卸载该端口转发管理工具${RESET}"
        echo -e "${GREEN} 0. 退出面板${RESET}"
        echo -e "${GREEN}========================================${RESET}"
        
        read -rp "$(echo -e "${GREEN}请选择操作 [0-9]: ${RESET}")" menu_choice
        case "$menu_choice" in
            1) do_install ;;
            2) do_list ;;
            3) do_add ;;
            4) do_delete ;;
            5) do_clear_all ;;
            6) do_diagnose ;;
            7) do_backup_manual ;;
            8) do_restore_manual ;;
            9) do_uninstall ;;
            0) info "感谢使用。" && exit 0 ;;
            *) err "输入错误" && pause_to_menu ;;
        esac
        echo ""
    done
}

main_menu "$@"
