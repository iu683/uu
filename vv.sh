#!/usr/bin/env bash
#
# nftables 端口转发管理工具 (DDNS 修复日志菜单完美版)
#

# ============== 常量定义 ==============
CONF_DIR="/etc/nftables.d"
CONF_FILE="${CONF_DIR}/port-forward.conf"
DEFAULT_BACKUP_DIR="${CONF_DIR}/backups"
MAIN_CONF="/etc/nftables.conf"
SYSCTL_CONF="/etc/sysctl.d/99-nft-forward.conf"
LOG_FILE="/var/log/nft-forward.log"
CRON_DDNS_SCRIPT="${CONF_DIR}/ddns_sync.sh"
LOCAL_SCRIPT_PATH="${CONF_DIR}/port_forward_main.sh"
BIN_LINK_DIR="/usr/local/bin"

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
    if command -v /usr/sbin/nft &>/dev/null; then
        /usr/sbin/nft --version 2>/dev/null | awk '{print $2}'
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

# 【核心终极修复】：tail -n +3 彻底滤除 nslookup 自身的 Server/Address 干扰行，只抓真实目标 IP，且 tr 彻底清除换行尾巴
resolve_domain() {
    local domain="$1"
    local resolved=""
    if command -v nslookup &>/dev/null; then
        resolved=$(nslookup "$domain" 8.8.8.8 2>/dev/null | tail -n +3 | sed -n 's/^Address:[[:space:]]*\([0-9.]*\).*$/\1/p' | head -n1 | tr -d '\r\n[:space:]')
    fi
    if [[ -z "$resolved" ]] && command -v dig &>/dev/null; then
        resolved=$(dig +short "$domain" @8.8.8.8 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1 | tr -d '\r\n[:space:]')
    fi
    if [[ -z "$resolved" ]]; then
        resolved=$(ping -c 1 -W 2 "$domain" 2>/dev/null | head -n1 | awk -F'[()]' '{print $2}' | tr -d '\r\n[:space:]')
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

# 【核心修复】：收紧更严密精确的 IPv4 提取规则，防止字符串切割发生长短偏离
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
        
        if [[ "$line" =~ (tcp|udp)[[:space:]]+dport[[:space:]]+([0-9]+)[[:space:]]+dnat[[:space:]]+to[[:space:]]+(([0-9]{1,3}\.){3}[0-9]{1,3}):([0-9]+) ]]; then
            local matched_proto="${BASH_REMATCH[1]}"
            local lp="${BASH_REMATCH[2]}"
            local current_target="${BASH_REMATCH[3]}"
            local dp="${BASH_REMATCH[5]}"
            
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

        elif [[ "$line" =~ (tcp|udp)[[:space:]]+dport[[:space:]]+([0-9]+)[[:space:]]+dnat[[:space:]]+ip6[[:space:]]+to[[:space:]]+\[(.*)\]:([0-9]+) ]] || [[ "$line" =~ (tcp|udp)[[:space:]]+dport[[:space:]]+([0-9]+)[[:space:]]+dnat[[:space:]]+ip6[[:space:]]+to[[:space:]]+([0-9a-fA-F:]+):([0-9]+) ]]; then
            local lp="${BASH_REMATCH[2]}"
            local extracted_ip="${BASH_REMATCH[3]}"
            local dp="${BASH_REMATCH[4]}"
            
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
        
        [[ -z "$actual_ip" ]] && continue

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
        [[ -z "$actual_ip" ]] && continue

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
        [[ -z "$actual_ip" ]] && continue

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
        [[ -z "$actual_ip" ]] && continue

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

# 【核心修复】：后台执行绝对路径规范化
reload_rules() {
    /usr/sbin/nft -f "${CONF_FILE}"
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

    crontab -l 2>/dev/null | grep -v "${CRON_DDNS_SCRIPT}" | crontab - 2>/dev/null || true
    (crontab -l 2>/dev/null; echo "*/2 * * * * ${CRON_DDNS_SCRIPT} >/dev/null 2>&1") | crontab - 2>/dev/null || true
}

# 【核心修复】：改用精准的固定字符串检索 (-F)，防止任何因格式排版变动引发的误触发重载循环
do_backend_ddns_sync() {
    [[ -f "${CONF_FILE}" ]] || exit 0
    load_rules
    if [[ ${#RULES[@]} -eq 0 ]]; then exit 0; fi

    local need_reload=0
    local rule lport target dport note proto type current_dns_ip
    
    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport target dport note proto <<< "$rule"
        type=$(detect_ip_type "$target")
        
        if [[ "$type" == "2" ]]; then
            current_dns_ip=$(resolve_domain "$target")
            if [[ -n "$current_dns_ip" ]]; then
                if ! grep -F "${current_dns_ip}" "${CONF_FILE}" >/dev/null 2>&1; then
                    need_reload=1
                    echo "$(date '+%Y-%m-%d %H:%M:%S') [DDNS] 检测到域名 ${target} IP 已变动为 ${current_dns_ip}，触发热重载..." >> "${LOG_FILE}"
                    break
                fi
            fi
        fi
    done

    if [[ $need_reload -eq 1 ]]; then
        write_conf_file
        reload_rules
    fi
    exit 0
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
    info "手动导出成功！备份已保存至: ${target_dir}/${bkp_name}"
    pause_to_menu
}

do_restore_manual() {
    local target_input selected_file=""
    read -rp "$(echo -e "${GREEN}请输入备份所在的导入目录或完整文件路径 [默认: ${DEFAULT_BACKUP_DIR}]: ${RESET}")" target_input
    target_input="${target_input:-$DEFAULT_BACKUP_DIR}"

    if [[ -f "$target_input" && "$target_input" == *.conf ]]; then
        selected_file="$target_input"
    else
        if [[ ! -d "${target_input}" ]]; then
            err "指定的目录或文件不存在: ${target_input}"
            pause_to_menu
            return
        fi
        local bkp_files=($(ls "${target_input}"/*.conf 2>/dev/null | sort -r))
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
            selected_file="${bkp_files[$((choice-1))]}"
        else
            err "无效的序号输入"
            pause_to_menu
            return
        fi
    fi

    if [[ -n "$selected_file" && -f "$selected_file" ]]; then
        if [[ -f "${CONF_FILE}" ]]; then
            cp "${CONF_FILE}" "${DEFAULT_BACKUP_DIR}/auto_emergency_before_restore.conf" 2>/dev/null || true
        fi
        cp -f "${selected_file}" "${CONF_FILE}"
        if reload_rules; then
            info "历史配置 [$(basename "$selected_file")] 导入并成功应用！"
            setup_ddns_cron
        else
            err "载入备份文件失败，正在回滚原始配置..."
            [[ -f "${DEFAULT_BACKUP_DIR}/auto_emergency_before_restore.conf" ]] && cp -f "${DEFAULT_BACKUP_DIR}/auto_emergency_before_restore.conf" "${CONF_FILE}"
            reload_rules
        fi
    else
        err "未能正确读取备份文件。"
    fi
    pause_to_menu
}

do_install() {
    info "准备安装依赖..."
    local pm=$(detect_pkg_manager)
    case "$pm" in
        apk) apk add nftables bash curl iproute2 bind-tools ;; 
        *) $pm update -y && $pm install -y nftables curl dnsutils ;; 
    esac
    enable_ip_forward && init_conf && restart_and_enable_nft && setup_ddns_cron
    info "环境初始化完成！"
    pause_to_menu
}

_print_rules_list() {
    printf "\n\033[1m%-6s %-12s %-10s     %-35s %s\033[0m\n" "序号"  "协议"  "本机端口"  "目标地址/域名"  "备注"
    echo -e "${GREEN}=====================================${RESET}"
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
}

do_list() {
    load_rules
    if [[ ${#RULES[@]} -eq 0 ]]; then 
        info "当前没有配置任何端口转发规则。"
        pause_to_menu
        return
    fi
    _print_rules_list
    echo ""
    pause_to_menu
}

do_add() {
    command -v /usr/sbin/nft &>/dev/null || { err "nftables 未安装"; pause_to_menu; return; }
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

do_edit() {
    load_rules
    if [[ ${#RULES[@]} -eq 0 ]]; then info "无规则可供修改。"; pause_to_menu; return; fi
    
    _print_rules_list
    echo ""

    read -rp "请输入要修改的规则序号 (0 取消): " choice
    if [[ -z "$choice" || "$choice" == "0" ]]; then return; fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#RULES[@]} )); then
        err "无效序号"
        pause_to_menu
        return
    fi

    local target_idx=$((choice-1))
    local old_lport old_target old_dport old_note old_proto
    IFS='|' read -r old_lport old_target old_dport old_note old_proto <<< "${RULES[$target_idx]}"

    echo -e "\n${YELLOW}开始修改第 $choice 条规则 (直接回车保持原值):${RESET}"
    local lport target dport note proto proto_choice type

    while true; do
        read -rp "本机监听端口 [$old_lport]: " lport
        lport="${lport:-$old_lport}"
        validate_port "$lport" && break
        err "端口输入无效"
    done

    local idx=0 rp
    for rule in "${RULES[@]}"; do
        if (( idx != target_idx )); then
            IFS='|' read -r rp _ _ _ _ <<< "$rule"
            if [[ "$rp" == "$lport" ]]; then 
                err "本机端口 ${lport} 与其他规则冲突！"
                pause_to_menu
                return
            fi
        fi
        ((idx++))
    done

    while true; do
        read -rp "目标 IP 或 域名 [$old_target]: " target
        target="${target:-$old_target}"
        type=$(detect_ip_type "$target")
        if [[ "$type" == "1" ]]; then err "格式不正确"; elif [[ "$type" == "2" ]]; then
            local rip=$(resolve_domain "$target")
            [[ -z "$rip" ]] && warn "该域名目前解析不出 IP，系统稍后会自动重试。" || info "成功解析当前 IP 为: ${rip}"
            break
        else break; fi
    done

    while true; do
        read -rp "目标端口 [$old_dport]: " dport
        dport="${dport:-$old_dport}"
        validate_port "$dport" && break
        err "目标端口不合法"
    done

    local current_proto_desc="TCP+UDP"
    [[ "$old_proto" == "TCP" ]] && current_proto_desc="仅 TCP"
    [[ "$old_proto" == "UDP" ]] && current_proto_desc="仅 UDP"
    
    while true; do
        read -rp "$(echo -e "${GREEN}请选择协议类型 [1: TCP+UDP | 2: 仅 TCP | 3: 仅 UDP] (当前: $current_proto_desc, 回车不改): ${RESET}")" proto_choice
        if [[ -z "$proto_choice" ]]; then
            proto="$old_proto"
            break
        fi
        case "$proto_choice" in
            1) proto="ALL"; break ;;
            2) proto="TCP"; break ;;
            3) proto="UDP"; break ;;
            *) err "选择错误，请输入 1, 2 或 3" ;;
        esac
    done

    read -rp "本条转发备注 [$old_note]: " note
    if [[ -z "$note" ]]; then
        note="$old_note"
    else
        note=$(sanitize_note "$note")
    fi

    RULES[$target_idx]="${lport}|${target}|${dport}|${note}|${proto}"
    if write_conf_file && reload_rules && setup_ddns_cron; then
        info "规则修改并应用成功！"
    else
        err "配置重载失败，已作出的修改可能未生效"
    fi
    pause_to_menu
}

do_delete() {
    load_rules
    if [[ ${#RULES[@]} -eq 0 ]]; then info "无规则可供删除。"; pause_to_menu; return; fi
    
    _print_rules_list
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
        info "域名同步守护进程: 高频自启 (每2分钟)"
    else
        warn "域名同步守护进程: 未挂进程"
    fi
    pause_to_menu
}

do_view_log() {
    if [[ ! -f "${LOG_FILE}" ]]; then
        info "当前暂无 DDNS 日志记录产生。"
        pause_to_menu
        return
    fi
    echo -e "\n${GREEN}正在查看 DDNS 实时日志，按【Ctrl + C】可以随时退出查看...${RESET}"
    echo -e "${YELLOW}------------------------------------------------------------${RESET}"
    tail -n 30 -f "${LOG_FILE}"
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
        do_backend_ddns_sync
        exit 0
    fi

    auto_localize_and_link

    local panel_status panel_version panel_rules_count
    while true; do
        is_nftables_active && panel_status="${GREEN}运行中${RESET}" || panel_status="${RED}未运行${RESET}"
        panel_version=$(get_nft_version)
        load_rules
        panel_rules_count="${#RULES[@]}"

        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}  ◈ nftables 转发面板${RESET}${YELLOW}(快捷键A/a)${RESET}${GREEN} ◈${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN} 状态 :${RESET} $panel_status"
        echo -e "${GREEN} 版本 :${RESET} ${YELLOW}${panel_version}${RESET}"
        echo -e "${GREEN} 规则 : 已载入${RESET} ${YELLOW}${panel_rules_count}${RESET} ${GREEN}条转发${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN} 1. 安装/修复依赖环境${RESET}"
        echo -e "${GREEN} 2. 查看 当前转发规则${RESET}"
        echo -e "${GREEN} 3. 新增 转发规则${RESET}"
        echo -e "${GREEN} 4. 修改 转发规则${RESET}"
        echo -e "${GREEN} 5. 删除 转发规则${RESET}"
        echo -e "${GREEN} 6. 清空 所有转发规则${RESET}"
        echo -e "${GREEN} 7. 系统环境自检${RESET}"
        echo -e "${GREEN} 8. 导出 规则(备份)${RESET}"
        echo -e "${GREEN} 9. 导入 规则(恢复)${RESET}"
        echo -e "${GREEN}10. 彻底卸载面板系统${RESET}"
        echo -e "${GREEN}11. 查看 DDNS 运行日志${RESET}"
        echo -e "${GREEN} 0. 退出${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        
        read -rp "$(echo -e "${GREEN}请选择操作: ${RESET}")" menu_choice
        case "$menu_choice" in
            1) do_install ;;
            2) do_list ;;
            3) do_add ;;
            4) do_edit ;;
            5) do_delete ;;
            6) do_clear_all ;;
            7) do_diagnose ;;
            8) do_backup_manual ;;
            9) do_restore_manual ;;
            10) do_uninstall ;;
            11) do_view_log ;;
            0) exit 0 ;;
            *) err "输入错误" && pause_to_menu ;;
        esac
        echo ""
    done
}

main_menu "$@"
EOF
chmod +x /etc/nftables.d/port_forward_main.sh
