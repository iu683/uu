#!/usr/bin/env bash
#
# iptables 端口转发管理工具 (Alpine Linux 专属)
#

# ============== 常量定义 ==============
CONF_DIR="/etc/iptables.d"
CONF_FILE="${CONF_DIR}/port-forward.rules"
DEFAULT_BACKUP_DIR="${CONF_DIR}/backups"
SYSCTL_CONF="/etc/sysctl.d/99-ip-forward.conf"
LOG_FILE="/var/log/iptables-forward.log"
CRON_DDNS_SCRIPT="${CONF_DIR}/ddns_sync.sh"
LOCAL_SCRIPT_PATH="${CONF_DIR}/port_forward_main.sh"
BIN_LINK_DIR="/usr/local/bin"


GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

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

# 完美兼容 Alpine 的 v4/v6 双栈服务状态检测
is_iptables_active() {
    local v4_ok=0
    local v6_ok=0
    
    # 检测 IPv4 iptables 状态 (兼容 OpenRC 各种微调输出)
    if rc-service iptables status 2>/dev/null | grep -Ei "started|active" >/dev/null; then
        v4_ok=1
    fi
    
    # 检测 IPv6 ip6tables 状态
    if rc-service ip6tables status 2>/dev/null | grep -Ei "started|active" >/dev/null; then
        v6_ok=1
    fi

    # 只要有一个在跑就认为整体在运行，并反馈具体多栈状态
    if [[ $v4_ok -eq 1 && $v6_ok -eq 1 ]]; then
        echo "双栈运行中"
        return 0
    elif [[ $v4_ok -eq 1 ]]; then
        echo "仅IPv4运行"
        return 0
    elif [[ $v6_ok -eq 1 ]]; then
        echo "仅IPv6运行"
        return 0
    else
        return 1
    fi
}

get_iptables_version() {
    if command -v iptables &>/dev/null; then
        iptables --version 2>/dev/null | awk '{print $2}'
    else
        echo "未安装"
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
        resolved=$(getent ahosts "$domain" 2>/dev/null | grep -E '^[0-9]' | head -n1 | awk '{print $1}')
    fi
    if [[ -z "$resolved" ]] && command -v dig &>/dev/null; then
        resolved=$(dig +short "$domain" @8.8.8.8 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1)
    fi
    if [[ -z "$resolved" ]] && command -v nslookup &>/dev/null; then
        resolved=$(nslookup "$domain" 8.8.8.8 2>/dev/null | awk '/^Address:/ {print $2}' | grep -v "#" | head -n1)
    fi
    echo "${resolved//[[:space:]]/}"
}

enable_ip_forward() {
    mkdir -p /etc/sysctl.d
    cat > "${SYSCTL_CONF}" <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
    sysctl -p "${SYSCTL_CONF}" >/dev/null 2>&1 || true
    
    # 加载 Alpine 内核模块保底
    modprobe ip_tables iptable_nat ip6_tables ip6table_nat 2>/dev/null || true
}

disable_ip_forward() {
    rm -f "${SYSCTL_CONF}" 2>/dev/null
}

init_conf() {
    mkdir -p "${CONF_DIR}" "${DEFAULT_BACKUP_DIR}" 2>/dev/null || return 1
    touch "${LOG_FILE}" "${CONF_FILE}" 2>/dev/null || true
}

declare -a RULES=()

sanitize_note() {
    printf "%s" "${1//|/ }"
}

# 从自建的纯净规则文件中加载
load_rules() {
    RULES=()
    [[ -f "${CONF_FILE}" ]] || return
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && [[ ! "$line" =~ "RULE:" ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        
        if [[ "$line" =~ ^#\ RULE:\ (.*)$ ]]; then
            RULES+=("${BASH_REMATCH[1]}")
        fi
    done < "${CONF_FILE}"
}

# 核心：将本地 RULES 阵列转换为系统 iptables 实际规则并保存
write_and_apply_rules() {
    local tmp_file="${CONF_FILE}.tmp.$$"
    echo "# iptables 端口转发快照" > "${tmp_file}"
    local rule
    for rule in "${RULES[@]}"; do
        echo "# RULE: ${rule}" >> "${tmp_file}"
    done
    mv -f "${tmp_file}" "${CONF_FILE}" 2>/dev/null

    # 精准定点清理转发链（绝对不碰 INPUT，SSH永不锁死）
    iptables -t nat -F PREROUTING 2>/dev/null || true
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    ip6tables -t nat -F PREROUTING 2>/dev/null || true
    ip6tables -t nat -F POSTROUTING 2>/dev/null || true

    local lport target dport note proto type actual_ip
    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport target dport note proto <<< "$rule"
        proto="${proto:-ALL}"
        type=$(detect_ip_type "$target")
        actual_ip="$target"
        
        if [[ "$type" == "2" ]]; then 
            actual_ip=$(resolve_domain "$target")
            if [[ -z "$actual_ip" ]]; then
                # 域名解析闪断保底
                actual_ip=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -w "dports ${lport}" | awk '{print $NF}' | awk -F':' '{print $1}')
            fi
        fi
        [[ -z "$actual_ip" ]] && continue
        local ip_ver=$(detect_ip_type "$actual_ip")

        if [[ "$ip_ver" == "4" ]]; then
            if [[ "$proto" == "ALL" || "$proto" == "TCP" ]]; then
                iptables -t nat -A PREROUTING -p tcp --dport "${lport}" -j DNAT --to-destination "${actual_ip}:${dport}"
                iptables -t nat -A POSTROUTING -p tcp -d "${actual_ip}" --dport "${dport}" -j MASQUERADE
            fi
            if [[ "$proto" == "ALL" || "$proto" == "UDP" ]]; then
                iptables -t nat -A PREROUTING -p udp --dport "${lport}" -j DNAT --to-destination "${actual_ip}:${dport}"
                iptables -t nat -A POSTROUTING -p udp -d "${actual_ip}" --dport "${dport}" -j MASQUERADE
            fi
        elif [[ "$ip_ver" == "6" ]]; then
            if [[ "$proto" == "ALL" || "$proto" == "TCP" ]]; then
                ip6tables -t nat -A PREROUTING -p tcp --dport "${lport}" -j DNAT --to-destination "[${actual_ip}]:${dport}"
                ip6tables -t nat -A POSTROUTING -p tcp -d "${actual_ip}" --dport "${dport}" -j MASQUERADE
            fi
            if [[ "$proto" == "ALL" || "$proto" == "UDP" ]]; then
                ip6tables -t nat -A PREROUTING -p udp --dport "${lport}" -j DNAT --to-destination "[${actual_ip}]:${dport}"
                ip6tables -t nat -A POSTROUTING -p udp -d "${actual_ip}" --dport "${dport}" -j MASQUERADE
            fi
        fi
    done

    # 持久化保存到 Alpine 系统开机加载目录
    rc-service iptables save >/dev/null 2>&1 || true
    rc-service ip6tables save >/dev/null 2>&1 || true
}

setup_ddns_cron() {
    rc-update add dcron default >/dev/null 2>&1 || true
    rc-service dcron start >/dev/null 2>&1 || true

    cat > "${CRON_DDNS_SCRIPT}" <<EOF
#!/usr/bin/env bash
CONF_FILE="/etc/iptables.d/port-forward.rules"
[[ -f "\$CONF_FILE" ]] || exit 0
if grep -q "RULE:" "\$CONF_FILE"; then
    /etc/iptables.d/port_forward_main.sh --reload-backend
fi
EOF
    chmod +x "${CRON_DDNS_SCRIPT}" 2>/dev/null

    local tmp_cron="/tmp/current_cron_$$"
    crontab -l 2>/dev/null | grep -v "${CRON_DDNS_SCRIPT}" > "${tmp_cron}" || true
    echo "*/2 * * * * ${CRON_DDNS_SCRIPT} >/dev/null 2>&1" >> "${tmp_cron}"
    crontab "${tmp_cron}" 2>/dev/null || true
    rm -f "${tmp_cron}"
}

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
                local active_ip=""
                local ip_ver=$(detect_ip_type "$current_dns_ip")
                
                # 核心修复：加了 head -n1，多条重复规则只取第一个，彻底干掉换行符
                if [[ "$ip_ver" == "4" ]]; then
                    active_ip=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -w "dport ${lport}" | grep -oE 'to-destination [0-9.]+' | awk '{print $2}' | head -n1)
                elif [[ "$ip_ver" == "6" ]]; then
                    active_ip=$(ip6tables -t nat -S PREROUTING 2>/dev/null | grep -w "dport ${lport}" | grep -oE 'to-destination \[[0-9a-fA-F:]+\]' | tr -d '[]' | awk '{print $2}' | head -n1)
                fi

                # 剔除可能存在的首尾空格/换行干净比对
                active_ip=$(echo "${active_ip}" | tr -d '[:space:]')
                current_dns_ip=$(echo "${current_dns_ip}" | tr -d '[:space:]')

                if [[ -z "$active_ip" || "$current_dns_ip" != "$active_ip" ]]; then
                    need_reload=1
                    echo "$(date '+%Y-%m-%d %H:%M:%S') [DDNS] 检测到域名 ${target} IP 真正发生变动 [旧: ${active_ip:-无} -> 新: ${current_dns_ip}]，触发局部热重载..." >> "${LOG_FILE}"
                fi
            fi
        fi
    done

    if [[ $need_reload -eq 1 ]]; then
        write_and_apply_rules
    fi
    exit 0
}
do_backup_manual() {
    if [[ ! -f "${CONF_FILE}" ]] || [[ ! -s "${CONF_FILE}" ]]; then
        err "当前没有任何生效的规则，无需导出。"
        pause_to_menu
        return
    fi
    local target_dir
    read -rp "$(echo -e "${GREEN}请输入备份导出目录 [默认: ${DEFAULT_BACKUP_DIR}]: ${RESET}")" target_dir
    target_dir="${target_dir:-$DEFAULT_BACKUP_DIR}"
    mkdir -p "${target_dir}" 2>/dev/null

    local bkp_name="iptables_bak_$(date '+%Y%m%d_%H%M%S').rules"
    cp "${CONF_FILE}" "${target_dir}/${bkp_name}"
    info "手动导出成功！备份至: ${target_dir}/${bkp_name}"
    pause_to_menu
}

do_restore_manual() {
    local target_input selected_file=""
    read -rp "$(echo -e "${GREEN}请输入备份文件夹或完整路径 [默认: ${DEFAULT_BACKUP_DIR}]: ${RESET}")" target_input
    target_input="${target_input:-$DEFAULT_BACKUP_DIR}"

    if [[ -f "$target_input" ]]; then
        selected_file="$target_input"
    else
        local bkp_files=($(ls "${target_input}"/*.rules 2>/dev/null | sort -r))
        if [[ ${#bkp_files[@]} -eq 0 ]]; then
            err "未发现备份文件。"
            pause_to_menu
            return
        fi
        echo -e "\n${YELLOW}=== 历史备份 ===${RESET}"
        local idx=1 file
        for file in "${bkp_files[@]}"; do
            printf "[%2s] %s\n" "$idx" "$(basename "$file")"
            ((idx++))
        done
        read -rp "请选择序号 (0 取消): " choice
        if [[ -z "$choice" || "$choice" == "0" ]]; then return; fi
        selected_file="${bkp_files[$((choice-1))]}"
    fi

    if [[ -n "$selected_file" && -f "$selected_file" ]]; then
        cp -f "${selected_file}" "${CONF_FILE}"
        load_rules
        write_and_apply_rules
        info "配置已导入并成功应用！"
    fi
    pause_to_menu
}

do_install() {
    info "准备安全安装 Alpine iptables 双栈环境..."
    
    # 1. 安装基础依赖
    apk add iptables ip6tables bash curl bind-tools dcron >/dev/null 2>&1
    
    # 2. 开启内核转发与初始化配置
    enable_ip_forward && init_conf
    
    # 3. 【核心加固】防止 Alpine 启动默认服务时锁死 SSH 或报错
    # 提前创建并写入极其纯净、放行的基础规则文件（Alpine 默认路径）
    mkdir -p /etc/iptables
    
    cat << 'EOF' > /etc/iptables/rules.iv4
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
COMMIT
EOF

    # 镜像复制一份给 IPv6
    cp /etc/iptables/rules.iv4 /etc/iptables/rules.iv6

    # 4. 注册并安全启动服务
    rc-update add iptables default >/dev/null 2>&1 || true
    rc-update add ip6tables default >/dev/null 2>&1 || true
    
    # 此时启动绝对安全，INPUT 链全放行，且 nat 链已被初始化创建
    rc-service iptables start >/dev/null 2>&1 || true
    rc-service ip6tables start >/dev/null 2>&1 || true
    
    # 5. 【策略优化】立即执行一次规则写入，确保不用等 cron 触发就直接生效
    if type write_and_apply_rules >/dev/null 2>&1; then
        info "正在注入初始端口转发规则..."
        write_and_apply_rules
    fi
    
    # 6. 配置定时任务（DDNS 域名探针）
    setup_ddns_cron
    # 确保 Alpine 的 cron 服务也是启动状态
    rc-update add dcron default >/dev/null 2>&1 || true
    rc-service dcron start >/dev/null 2>&1 || true
    
    info "Alpine iptables 双栈环境初始化完成！INPUT 链绝对纯净安全。"
    pause_to_menu
}

# 3. 手机端纵向块状输出
_print_rules_list() {
    local idx=1 rule lport target dport note proto type label proto_label
    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport target dport note proto <<< "$rule"
        proto="${proto:-ALL}"
        type=$(detect_ip_type "$target")
        
        if [[ "$type" == "2" ]]; then 
            label="域名"
        elif [[ "$type" == "6" ]]; then 
            label="IPv6" 
        else 
            label="IPv4"
        fi
        
        if [[ "$proto" == "ALL" ]]; then 
            proto_label="TCP+UDP" 
        else 
            proto_label="$proto"
        fi

        local target_display
        if [[ "$type" == "6" ]]; then
            target_display="[${target}]:${dport}"
        else
            target_display="${target}:${dport}"
        fi

        echo -e "${YELLOW}◈ 规则序号: ${RESET}${YELLOW}[${idx}]${RESET}"
        echo -e "  ├─ ${YELLOW}转发协议: ${RESET}${CYAN}${proto_label} (${label})${RESET}"
        echo -e "  ├─ ${YELLOW}本机端口: ${RESET}${GREEN}${lport}${RESET}"
        echo -e "  ├─ ${YELLOW}目标地址: ${RESET}${BLUE}${target_display}${RESET}"
        echo -e "  └─ ${YELLOW}备注信息: ${RESET}${note:--}"
        echo -e "${YELLOW}----------------------------------------${RESET}"
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
    write_and_apply_rules
    setup_ddns_cron
    info "规则添加并加载成功！"
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
    old_proto="${old_proto:-ALL}"

    echo -e "\n${YELLOW}开始修改第 $choice 条规则 (直接回车保持原值):${RESET}"
    local lport target dport note proto proto_choice type

    # 1. 修改本机端口
    while true; do
        read -rp "本机监听端口 [$old_lport]: " lport
        lport="${lport:-$old_lport}"
        validate_port "$lport" && break
        err "端口输入无效"
    done

    # 2. 修改目标 IP 或 域名
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

    # 3. 修改目标端口
    while true; do
        read -rp "目标端口 [$old_dport]: " dport
        dport="${dport:-$old_dport}"
        validate_port "$dport" && break
        err "目标端口不合法"
    done

    # 4. 修改协议类型 (已补齐)
    local proto_label
    [[ "$old_proto" == "ALL" ]] && proto_label="TCP+UDP" || proto_label="$old_proto"
    while true; do
        read -rp "$(echo -e "${GREEN}请选择协议类型 [1: TCP+UDP | 2: 仅 TCP | 3: 仅 UDP] (当前: ${proto_label}, 直接回车保持不变): ${RESET}")" proto_choice
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

    # 5. 修改备注
    read -rp "本条转发备注 [$old_note]: " note
    note="${note:-$old_note}"
    note=$(sanitize_note "$note")

    # 写入更新（使用新修改的 $proto 替换原有的 $old_proto）
    RULES[$target_idx]="${lport}|${target}|${dport}|${note}|${proto}"
    write_and_apply_rules
    info "规则修改并应用成功！"
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
        write_and_apply_rules
        info "成功删除规则。"
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
    write_and_apply_rules
    crontab -l 2>/dev/null | grep -v "${CRON_DDNS_SCRIPT}" | crontab - 2>/dev/null || true
    rm -f "${CRON_DDNS_SCRIPT}" 2>/dev/null
    info "已全部清空。"
    pause_to_menu
}

do_diagnose() {
    echo -e "\n========================================"
    echo "     Alpine Linux iptables 系统环境自检"
    echo "========================================"
    info "系统类型: Alpine Linux"
    
    local status_msg
    status_msg=$(is_iptables_active)
    if [[ $? -eq 0 ]]; then
        info "iptables 服务状态: ${status_msg}"
    else
        warn "iptables 服务状态: 未运行"
    fi

    if crontab -l 2>/dev/null | grep -q "${CRON_DDNS_SCRIPT}"; then
        info "域名同步守护进程: 正常激活 (每2分钟)"
    else
        warn "域名同步守护进程: 未配置进程"
    fi
    pause_to_menu
}

do_view_log() {
    if [[ ! -f "${LOG_FILE}" ]]; then
        info "当前暂无 DDNS 日志记录产生。"
        pause_to_menu
        return
    fi
    echo -e "\n${GREEN}正在查看实时日志，按【Ctrl + C】可以随时退出查看...${RESET}"
    tail -n 30 -f "${LOG_FILE}"
}

do_uninstall() {
    read -rp "确认要彻底卸载本工具并清空所有转发规则吗？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    RULES=()
    write_and_apply_rules 2>/dev/null || true
    crontab -l 2>/dev/null | grep -v "${CRON_DDNS_SCRIPT}" | crontab - 2>/dev/null || true
    disable_ip_forward
    rm -f "${BIN_LINK_DIR}/A" "${BIN_LINK_DIR}/a" 2>/dev/null
    rm -rf "${CONF_DIR}" 2>/dev/null
    rm -rf "${LOG_FILE}" 2>/dev/null

    echo -e "${GREEN}✅ Alpine 纯净卸载成功！iptables 转发规则已清除。${RESET}"
    exit 0
}

auto_localize_and_link() {


    # 如果本地脚本已存在，且快捷键 A 和 a 的软链接也都存在，说明已经安装过了，直接退出函数
    if [[ -f "${LOCAL_SCRIPT_PATH}" && -L "${BIN_LINK_DIR}/A" && -L "${BIN_LINK_DIR}/a" ]]; then
        return 0
    fi

    mkdir -p "${CONF_DIR}"
    mkdir -p "${BIN_LINK_DIR}"
    
    if [[ ! -f "${LOCAL_SCRIPT_PATH}" ]]; then
        local download_success=false
        local base_url="https://raw.githubusercontent.com/sistarry/toolbox/main/Alpine/APiptables.sh"
        
        
        # 遍历代理列表
        for proxy in "${GITHUB_PROXY[@]}"; do
            local url="${proxy}${base_url}"
            
            # wget 参数说明：
            # -q: 安静模式，不输出下载进度
            # --timeout=5: 设置连接和读取超时为 5 秒
            # -O: 指定输出路径
            if wget -q --timeout=5 "$url" -O "${LOCAL_SCRIPT_PATH}"; then
                # 检查文件是否下载成功且大小大于 0（防止部分代理返回空文件）
                if [[ -s "${LOCAL_SCRIPT_PATH}" ]]; then
                    download_success=true
                    break
                fi
            fi
            # 如果下载失败，清理可能生成的空文件或错误残留文件
            rm -f "${LOCAL_SCRIPT_PATH}"
            echo -e "${RED}❌ 当前节点连接失败，尝试下一个...${RESET}"
        done

        # 如果所有代理都失败了，终止后续操作
        if [[ "$download_success" = false ]]; then
            echo -e "${RED}❌ 所有网络节点均无法访问，安装失败。请检查网络。${RESET}"
            return 1
        fi

        chmod +x "${LOCAL_SCRIPT_PATH}"
    fi

    ln -sf "${LOCAL_SCRIPT_PATH}" "${BIN_LINK_DIR}/A"
    ln -sf "${LOCAL_SCRIPT_PATH}" "${BIN_LINK_DIR}/a"

    echo -e "${GREEN}✅ 安装完成，快捷键 [A] 或 [a] 已绑定。${RESET}"
}

main_menu() {
    check_root
    if [[ "${1:-}" == "--reload-backend" ]]; then
        do_backend_ddns_sync
        exit 0
    fi

    auto_localize_and_link

    local panel_status panel_version panel_rules_count status_msg
    while true; do

        status_msg=$(is_iptables_active)
        if [[ $? -eq 0 ]]; then
            panel_status="${GREEN}${status_msg}${RESET}"
        else
            panel_status="${RED}未运行${RESET}"
        fi

        panel_version=$(get_iptables_version)
        load_rules
        panel_rules_count="${#RULES[@]}"


        # 内核识别模块，彻底修掉菜单显示“内核未知”的问题
        if [ "$panel_status" != "${RED}未运行${RESET}" ]; then
            if ls -l /sbin/iptables 2>/dev/null | grep -q "nft"; then
                backend_type="${YELLOW}iptables-nft (兼容模式)${RESET}"
            else
                backend_type="${YELLOW}iptables (原生内核)${RESET}"
            fi
        else
            if [ -e /proc/net/ip_tables_names ]; then
                backend_type="${YELLOW}iptables (就绪但未启动)${RESET}"
            else
                backend_type="${YELLOW}内核模块未加载${RESET}"
            fi
        fi

        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}  ◈ iptables 转发面板${RESET} ${YELLOW}(快捷键A/a)${RESET} ${GREEN}◈${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN} 状态 :${RESET} $panel_status"
        echo -e "${GREEN} 内核 :${RESET} $backend_type"
        echo -e "${GREEN} 规则 : 已载入${RESET} ${YELLOW}${panel_rules_count}${RESET} ${GREEN}条转发${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN} 1. 安装 依赖环境${RESET}"
        echo -e "${GREEN} 2. 查看 当前转发规则${RESET}"
        echo -e "${GREEN} 3. 新增 转发规则${RESET}"
        echo -e "${GREEN} 4. 修改 转发规则${RESET}"
        echo -e "${GREEN} 5. 删除 转发规则${RESET}"
        echo -e "${GREEN} 6. 清空 所有转发规则${RESET}"
        echo -e "${GREEN} 7. 系统 环境自检${RESET}"
        echo -e "${GREEN} 8. 导出 规则(备份)${RESET}"
        echo -e "${GREEN} 9. 导入 规则(恢复)${RESET}"
        echo -e "${GREEN}10. 查看 DDNS运行日志${RESET}"
        echo -e "${GREEN}11. 卸载 面板${RESET}"
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
            10) do_view_log ;;
            11) do_uninstall ;;
            0) exit 0 ;;
            *) err "输入错误" && pause_to_menu ;;
        esac
        echo ""
    done
}

main_menu "$@"
