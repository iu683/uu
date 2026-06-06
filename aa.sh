#!/bin/bash

#=============================================================================
# 颜色定义
gl_hong='\033[31m'      # 红色
gl_lv='\033[32m'        # 绿色
gl_huang='\033[33m'     # 黄色
gl_bai='\033[0m'        # 重置
gl_kjlan='\033[96m'     # 亮青色
gl_zi='\033[35m'        # 紫色
gl_hui='\033[90m'       # 灰色

# 英文别名
readonly COLOR_RED="$gl_hong"
readonly COLOR_GREEN="$gl_lv"
readonly COLOR_YELLOW="$gl_huang"
readonly COLOR_RESET="$gl_bai"
readonly COLOR_CYAN="$gl_kjlan"
readonly COLOR_PURPLE="$gl_zi"
readonly COLOR_GRAY="$gl_hui"

# 显示宽度计算（中文占2列，ASCII占1列）
get_display_width() {
    local str="$1"
    local byte_len=$(printf '%s' "$str" | LC_ALL=C wc -c | tr -d ' ')
    local char_len=${#str}
    local extra=$((byte_len - char_len))
    local wide=$((extra / 2))
    echo $((char_len + wide))
}

# 格式化字符串到固定显示宽度（截断+填充，确保宽度精确）
format_fixed_width() {
    local str="$1"
    local target_width=$2
    local current_width=$(get_display_width "$str")

    # 如果太长，截断
    if [ "$current_width" -gt "$target_width" ]; then
        local result=""
        local i=0
        local len=${#str}
        while [ $i -lt $len ]; do
            local char="${str:$i:1}"
            local test_str="${result}${char}"
            local test_width=$(get_display_width "$test_str")
            if [ "$test_width" -gt $((target_width - 2)) ]; then
                str="${result}.."
                break
            fi
            result="$test_str"
            i=$((i + 1))
        done
        current_width=$(get_display_width "$str")
    fi

    # 填充到目标宽度
    local padding=$((target_width - current_width))
    if [ $padding -gt 0 ]; then
        printf "%s%*s" "$str" "$padding" ""
    else
        printf "%s" "$str"
    fi
}

# GitHub 代理设置
gh_proxy="https://"

# 配置文件路径（使用独立文件，不破坏系统配置）
SYSCTL_CONF="/etc/sysctl.d/99-bbr-xanmod.conf"

# IP 查询服务 URL（按优先级排序）
readonly IP_CHECK_V4_URLS=(
    "https://api.ipify.org"
    "https://ip.sb"
    "https://checkip.amazonaws.com"
    "https://ipinfo.io/ip"
)
readonly IP_CHECK_V6_URLS=(
    "https://api64.ipify.org"
    "https://v6.ipinfo.io/ip"
    "https://ip.sb"
)

# IP 信息查询
readonly IP_INFO_URL="https://ipinfo.io"


check_bbr_conf_status() {
    # 如果文件根本不存在，直接返回不通过 (1)
    if [ ! -f "$SYSCTL_CONF" ]; then
        return 1
    fi
    
    # 模糊验证：只要文件中包含这三段核心文本中的任意内容，即视为有效
    if grep -q "BBR v3 Direct/Endpoint Configuration" "$SYSCTL_CONF" && \
       grep -q "Generated on" "$SYSCTL_CONF" && \
       grep -q "Bandwidth:" "$SYSCTL_CONF"; then
        return 0  # 验证通过
    else
        return 1  # 验证失败
    fi
}

#=============================================================================
# 日志系统
#=============================================================================

readonly LOG_FILE="/var/log/bbr-xanmod.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
NETTCP_TEMP_DIRS=""


# 统一日志函数
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # 写入日志文件（静默失败）
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true

    # 根据级别输出到终端
    case "$level" in
        ERROR)
            echo -e "${gl_hong}[ERROR] $message${gl_bai}" >&2
            ;;
        WARN)
            echo -e "${gl_huang}[WARN] $message${gl_bai}"
            ;;
        INFO)
            [ "$LOG_LEVEL" != "ERROR" ] && echo -e "${gl_lv}[INFO] $message${gl_bai}"
            ;;
        DEBUG)
            [ "$LOG_LEVEL" = "DEBUG" ] && echo -e "${gl_hui}[DEBUG] $message${gl_bai}"
            ;;
    esac
}

# 便捷日志函数
log_error() { log "ERROR" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_info()  { log "INFO" "$@"; }
log_debug() { log "DEBUG" "$@"; }

#=============================================================================
# 错误处理
#=============================================================================

# 清理临时文件
cleanup_temp_files() {
    local temp_dir
    for temp_dir in $NETTCP_TEMP_DIRS; do
        case "$temp_dir" in
            /tmp/bbr-xanmod.*|/private/tmp/bbr-xanmod.*)
                [ -d "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null || true
                ;;
        esac
    done
    rm -f /tmp/caddy.tar.gz 2>/dev/null || true
}

# 全局错误处理器（可选启用）
error_handler() {
    local exit_code=$1
    local line_no=$2
    local command="$3"

    log_error "脚本执行失败"
    log_error "  退出码: $exit_code"
    log_error "  行号: $line_no"
    log_error "  命令: $command"

    cleanup_temp_files
}

# 启用严格模式（用于调试）
enable_strict_mode() {
    set -euo pipefail
    trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR
}

# 退出时清理
trap cleanup_temp_files EXIT

#=============================================================================
# 工具函数
#=============================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${gl_hong}错误: ${gl_bai}此脚本需要 root 权限运行！"
        echo "请使用: sudo bash $0"
        exit 1
    fi
}

break_end() {
    [ "$AUTO_MODE" = "1" ] && return
    echo -e "${gl_lv}操作完成${gl_bai}"
    echo -e "${gl_lv}按回车返回菜单...${gl_bai}"
    read -n 1 -s -r -p ""
}

clean_sysctl_conf() {
    # 备份主配置文件
    if [ -f /etc/sysctl.conf ] && ! [ -f /etc/sysctl.conf.bak.original ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.original
    fi
    
    # 注释所有冲突参数
    sed -i '/^net\.core\.rmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.core\.wmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.ipv4\.tcp_rmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.ipv4\.tcp_wmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.core\.default_qdisc/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.ipv4\.tcp_congestion_control/s/^/# /' /etc/sysctl.conf 2>/dev/null
}

install_package() {
    local packages=("$@")
    local missing_packages=()
    local os_release="/etc/os-release"
    local os_id=""
    local os_like=""
    local pkg_manager=""
    local update_cmd=()
    local install_cmd=()

    for package in "${packages[@]}"; do
        if ! command -v "$package" &>/dev/null; then
            missing_packages+=("$package")
        fi
    done

    if [ "${#missing_packages[@]}" -eq 0 ]; then
        return 0
    fi

    if [ -r "$os_release" ]; then
        # shellcheck disable=SC1091
        . "$os_release"
        os_id="${ID,,}"
        os_like="${ID_LIKE,,}"
    fi

    local detection="${os_id} ${os_like}"

    if [[ "$detection" =~ (debian|ubuntu) ]]; then
        pkg_manager="apt"
        update_cmd=(apt-get update)
        install_cmd=(apt-get install -y)
    elif [[ "$detection" =~ (rhel|centos|fedora|rocky|alma|redhat) ]]; then
        if command -v dnf &>/dev/null; then
            pkg_manager="dnf"
            update_cmd=(dnf makecache)
            install_cmd=(dnf install -y)
        elif command -v yum &>/dev/null; then
            pkg_manager="yum"
            update_cmd=(yum makecache)
            install_cmd=(yum install -y)
        else
            echo "错误: 未找到可用的 RHEL 系包管理器 (dnf 或 yum)" >&2
            return 1
        fi
    else
        echo "错误: 未支持的 Linux 发行版，无法自动安装依赖。请手动安装: ${missing_packages[*]}" >&2
        return 1
    fi

    if [ ${#update_cmd[@]} -gt 0 ]; then
        echo -e "${gl_huang}正在更新软件仓库...${gl_bai}"
        if ! "${update_cmd[@]}"; then
            echo "错误: 使用 ${pkg_manager} 更新软件仓库失败。" >&2
            return 1
        fi
    fi

    for package in "${missing_packages[@]}"; do
        echo -e "${gl_huang}正在安装 $package...${gl_bai}"
        if ! "${install_cmd[@]}" "$package"; then
            echo "错误: ${pkg_manager} 安装 $package 失败，请检查上方输出信息。" >&2
            return 1
        fi
    done
}

safe_download_script() {
    local url=$1
    local output_file=$2
    local part_file="${output_file}.part"
    local rc=1

    rm -f "$part_file"

    if command -v curl &>/dev/null; then
        curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 "$url" -o "$part_file"
        rc=$?
    elif command -v wget &>/dev/null; then
        wget -q --timeout=30 --tries=3 -O "$part_file" "$url"
        rc=$?
    else
        rm -f "$part_file"
        return 1
    fi

    if [ $rc -ne 0 ] || [ ! -s "$part_file" ]; then
        rm -f "$part_file"
        return 1
    fi

    if ! mv "$part_file" "$output_file"; then
        rm -f "$part_file"
        return 1
    fi

    return 0
}

verify_downloaded_script() {
    local file=$1

    if [ ! -s "$file" ]; then
        return 1
    fi

    if LC_ALL=C head -c 512 "$file" | grep -qiE '<!DOCTYPE|<html|404: Not Found|AccessDenied|Access Denied'; then
        return 1
    fi

    # shebang 必须在首行，同时处理 UTF-8 BOM (ef bb bf) 开头的情况
    local shebang
    shebang=$(LC_ALL=C head -n 1 "$file" | sed 's/^\xef\xbb\xbf//') || return 1
    echo "$shebang" | grep -Eq '(^#![[:space:]]*/([^[:space:]]*/)?(ba)?sh([[:space:]]|$))|(^#![[:space:]]*/usr/bin/env([[:space:]]+-S)?[[:space:]]+(ba)?sh([[:space:]]|$))'
}

run_remote_script() {
    if [ $# -lt 1 ]; then
        echo -e "${gl_hong}❌ 缺少脚本 URL${gl_bai}"
        return 1
    fi

    local url="$1"
    local interpreter="bash"
    if [ $# -ge 2 ]; then
        interpreter="$2"
        shift 2
    else
        shift 1
    fi

    local tmp_dir tmp_file
    tmp_dir=$(mktemp -d /tmp/bbr-xanmod.XXXXXX) || {
        echo -e "${gl_hong}❌ 无法创建临时目录${gl_bai}"
        return 1
    }
    NETTCP_TEMP_DIRS="${NETTCP_TEMP_DIRS}${NETTCP_TEMP_DIRS:+ }${tmp_dir}"
    tmp_file="${tmp_dir}/script.sh"

    if ! safe_download_script "$url" "$tmp_file"; then
        echo -e "${gl_hong}❌ 下载脚本失败: ${url}${gl_bai}"
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! verify_downloaded_script "$tmp_file"; then
        echo -e "${gl_hong}❌ 脚本校验失败，已取消执行${gl_bai}"
        rm -rf "$tmp_dir"
        return 1
    fi

    local rc
    if [ "${1:-}" = "-s" ]; then
        shift
        "$interpreter" -s "$@" < "$tmp_file"
    else
        "$interpreter" "$tmp_file" "$@"
    fi
    rc=$?
    rm -rf "$tmp_dir"
    return $rc
}

check_disk_space() {
    local required_gb=$1
    local required_space_mb=$((required_gb * 1024))
    local available_space_mb=$(df -m / | awk 'NR==2 {print $4}')

    if [ "$available_space_mb" -lt "$required_space_mb" ]; then
        echo -e "${gl_huang}警告: ${gl_bai}磁盘空间不足！"
        echo "当前可用: $((available_space_mb/1024))G | 最低需求: ${required_gb}G"
        read -e -p "是否继续？(Y/N): " continue_choice
        case "$continue_choice" in
            [Yy]) return 0 ;;
            *) return 1 ;;
        esac
    fi
}

check_swap() {
    local swap_total=$(free -m | awk 'NR==3{print $2}')

    if [ "$swap_total" -eq 0 ]; then
        echo -e "${gl_huang}检测到无虚拟内存，正在创建 1G SWAP...${gl_bai}"
        if fallocate -l $((1025 * 1024 * 1024)) /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1025 2>/dev/null; then
            chmod 600 /swapfile
            mkswap /swapfile > /dev/null 2>&1
            if swapon /swapfile 2>/dev/null; then
                # 防止重复写入 fstab
                if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
                    echo '/swapfile none swap sw 0 0' >> /etc/fstab
                fi
                echo -e "${gl_lv}虚拟内存创建成功${gl_bai}"
            else
                echo -e "${gl_huang}⚠️  SWAP 激活失败，但不影响安装${gl_bai}"
            fi
        else
            echo -e "${gl_huang}⚠️  SWAP 文件创建失败，但不影响安装${gl_bai}"
        fi
    fi
}

add_swap() {
    local new_swap=$1  # 获取传入的参数（单位：MB）

    echo -e "${gl_kjlan}=== 调整虚拟内存（仅管理 /swapfile） ===${gl_bai}"

    # 检测是否存在活跃的 /dev/* swap 分区
    local dev_swap_list
    dev_swap_list=$(awk 'NR>1 && $1 ~ /^\/dev\// {printf "  • %s (大小: %d MB, 已用: %d MB)\n", $1, int(($3+512)/1024), int(($4+512)/1024)}' /proc/swaps)

    if [ -n "$dev_swap_list" ]; then
        echo -e "${gl_huang}检测到以下 /dev/ 虚拟内存处于激活状态：${gl_bai}"
        echo "$dev_swap_list"
        echo ""
        echo -e "${gl_huang}提示:${gl_bai} 本脚本不会修改 /dev/ 分区，请使用 ${gl_zi}swapoff <设备>${gl_bai} 等命令手动处理。"
        echo ""
    fi

    # 确保 /swapfile 不再被使用
    swapoff /swapfile 2>/dev/null
    
    # 删除旧的 /swapfile
    rm -f /swapfile
    
    echo "正在创建 ${new_swap}MB 虚拟内存..."
    
    # 创建新的 swap 分区
    fallocate -l $(( (new_swap + 1) * 1024 * 1024 )) /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((new_swap + 1))
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null 2>&1
    swapon /swapfile
    
    # 更新 /etc/fstab
    sed -i '/\/swapfile/d' /etc/fstab
    echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
    
    # Alpine Linux 特殊处理
    if [ -f /etc/alpine-release ]; then
        echo "nohup swapon /swapfile" > /etc/local.d/swap.start
        chmod +x /etc/local.d/swap.start
        rc-update add local 2>/dev/null
    fi
    
    echo -e "${gl_lv}虚拟内存大小已调整为 ${new_swap}MB${gl_bai}"
}

calculate_optimal_swap() {
    # 获取物理内存（MB）
    local mem_total=$(free -m | awk 'NR==2{print $2}')
    local recommended_swap
    local reason
    
    echo -e "${gl_kjlan}=== 智能计算虚拟内存大小 ===${gl_bai}"
    echo ""
    echo -e "检测到物理内存: ${gl_huang}${mem_total}MB${gl_bai}"
    echo ""
    echo "计算过程："
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 根据内存大小计算推荐 SWAP
    if [ "$mem_total" -lt 512 ]; then
        # < 512MB: SWAP = 1GB（固定）
        recommended_swap=1024
        reason="内存极小（< 512MB），固定推荐 1GB"
        echo "→ 内存 < 512MB"
        echo "→ 推荐固定 1GB SWAP"
        
    elif [ "$mem_total" -lt 1024 ]; then
        # 512MB ~ 1GB: SWAP = 内存 × 2
        recommended_swap=$((mem_total * 2))
        reason="内存较小（512MB-1GB），推荐 2 倍内存"
        echo "→ 内存在 512MB - 1GB 之间"
        echo "→ 计算公式: SWAP = 内存 × 2"
        echo "→ ${mem_total}MB × 2 = ${recommended_swap}MB"
        
    elif [ "$mem_total" -lt 2048 ]; then
        # 1GB ~ 2GB: SWAP = 内存 × 1.5
        recommended_swap=$((mem_total * 3 / 2))
        reason="内存适中（1-2GB），推荐 1.5 倍内存"
        echo "→ 内存在 1GB - 2GB 之间"
        echo "→ 计算公式: SWAP = 内存 × 1.5"
        echo "→ ${mem_total}MB × 1.5 = ${recommended_swap}MB"
        
    elif [ "$mem_total" -lt 4096 ]; then
        # 2GB ~ 4GB: SWAP = 内存 × 1
        recommended_swap=$mem_total
        reason="内存充足（2-4GB），推荐与内存同大小"
        echo "→ 内存在 2GB - 4GB 之间"
        echo "→ 计算公式: SWAP = 内存 × 1"
        echo "→ ${mem_total}MB × 1 = ${recommended_swap}MB"
        
    elif [ "$mem_total" -lt 8192 ]; then
        # 4GB ~ 8GB: SWAP = 4GB（固定）
        recommended_swap=4096
        reason="内存较多（4-8GB），固定推荐 4GB"
        echo "→ 内存在 4GB - 8GB 之间"
        echo "→ 固定推荐 4GB SWAP"
        
    else
        # >= 8GB: SWAP = 4GB（固定）
        recommended_swap=4096
        reason="内存充裕（≥ 8GB），固定推荐 4GB"
        echo "→ 内存 ≥ 8GB"
        echo "→ 固定推荐 4GB SWAP"
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "${gl_lv}计算结果：${gl_bai}"
    echo -e "  物理内存:   ${gl_huang}${mem_total}MB${gl_bai}"
    echo -e "  推荐 SWAP:  ${gl_huang}${recommended_swap}MB${gl_bai}"
    echo -e "  总可用内存: ${gl_huang}$((mem_total + recommended_swap))MB${gl_bai}"
    echo ""
    echo -e "${gl_zi}推荐理由: ${reason}${gl_bai}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # 确认是否应用
    read -e -p "$(echo -e "${gl_huang}是否应用此配置？(Y/N): ${gl_bai}")" confirm
    
    case "$confirm" in
        [Yy])
            add_swap "$recommended_swap"
            return 0
            ;;
        *)
            echo "已取消"
            sleep 2
            return 1
            ;;
    esac
}


auto_cleanup_legacy_mtu() {
    [ -f /usr/local/etc/mtu-optimize.conf ] || return 0

    # 恢复默认路由 MTU
    local default_route
    default_route=$(ip -4 route show default 2>/dev/null | head -1)
    if [ -n "$default_route" ]; then
        local clean_route
        clean_route=$(echo "$default_route" | sed 's/ mtu lock [0-9]*//;s/ mtu [0-9]*//')
        ip route replace $clean_route 2>/dev/null
    fi

    # 恢复链路 MTU
    local saved_iface saved_original_mtu
    saved_iface=$(grep '^DEFAULT_IFACE=' /usr/local/etc/mtu-optimize.conf 2>/dev/null | cut -d= -f2)
    saved_original_mtu=$(grep '^ORIGINAL_MTU=' /usr/local/etc/mtu-optimize.conf 2>/dev/null | cut -d= -f2)
    if [ -n "$saved_iface" ] && [ -n "$saved_original_mtu" ]; then
        ip link set dev "$saved_iface" mtu "$saved_original_mtu" 2>/dev/null
    fi

    # 清理旧版 iptables set-mss 规则
    if command -v iptables &>/dev/null; then
        local comment_tag="bbr-xanmod-mss"
        local del_mss
        while read -r del_mss; do
            [ -n "$del_mss" ] || continue
            iptables -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$del_mss" -m comment --comment "$comment_tag" 2>/dev/null || true
        done < <(iptables -t mangle -S OUTPUT 2>/dev/null | grep "$comment_tag" | sed -n 's/.*--set-mss \([0-9]\+\).*/\1/p')
        while read -r del_mss; do
            [ -n "$del_mss" ] || continue
            iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$del_mss" -m comment --comment "$comment_tag" 2>/dev/null || true
        done < <(iptables -t mangle -S POSTROUTING 2>/dev/null | grep "$comment_tag" | sed -n 's/.*--set-mss \([0-9]\+\).*/\1/p')
    fi

    # 清理配置文件和持久化服务
    rm -f /usr/local/etc/mtu-optimize.conf
    if [ -f /usr/local/bin/bbr-optimize-apply.sh ] && grep -q "MTU 优化恢复 (mtu-optimize)" /usr/local/bin/bbr-optimize-apply.sh 2>/dev/null; then
        sed -i '/# MTU 优化恢复 (mtu-optimize)/,/^[[:space:]]*fi[[:space:]]*$/d' /usr/local/bin/bbr-optimize-apply.sh 2>/dev/null || true
    fi
    if [ -f /etc/systemd/system/mtu-optimize-persist.service ]; then
        systemctl disable mtu-optimize-persist.service 2>/dev/null
        rm -f /etc/systemd/system/mtu-optimize-persist.service
        rm -f /usr/local/bin/mtu-optimize-apply.sh
        systemctl daemon-reload 2>/dev/null
    fi

    echo -e "${gl_huang}⚠️ 已自动清理${gl_bai}"
    sleep 2
}


server_reboot() {
    read -e -p "$(echo -e "${gl_huang}提示: ${gl_bai}现在重启服务器使配置生效吗？(Y/N): ")" rboot
    case "$rboot" in
        [Yy])
            echo "正在重启..."
            reboot
            ;;
        *)
            echo "已取消，请稍后手动执行: reboot"
            ;;
    esac
}

#=============================================================================
# 带宽检测和缓冲区计算函数
#=============================================================================

# 带宽检测函数
detect_bandwidth() {
    # 所有交互式输出重定向到stderr，避免被命令替换捕获
    echo "" >&2
    echo -e "${gl_kjlan}=== 服务器带宽检测 ===${gl_bai}" >&2
    echo "" >&2
    echo "请选择带宽配置方式：" >&2
    echo "1. 自动检测（推荐，自动选择最近服务器）" >&2
    echo "2. 手动指定测速服务器（指定服务器ID）" >&2
    echo "3. 手动选择预设档位（9个常用带宽档位）" >&2
    echo "" >&2
    
    read -e -p "请输入选择 [1]: " bw_choice
    bw_choice=${bw_choice:-1}

    # 定义 Speedtest 核心统一参数（同时接受协议、隐私、免责）
    local st_args="--accept-license --accept-gdpr"

    case "$bw_choice" in
        1)
            # 自动检测带宽 - 选择最近服务器
            echo "" >&2
            echo -e "${gl_huang}正在运行 speedtest 测速...${gl_bai}" >&2
            echo -e "${gl_zi}提示: 自动选择距离最近的服务器${gl_bai}" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 检查speedtest是否安装
            if ! command -v speedtest &>/dev/null; then
                echo -e "${gl_huang}speedtest 未安装，正在安装...${gl_bai}" >&2
                local cpu_arch=$(uname -m)
                local download_url
                case "$cpu_arch" in
                    x86_64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
                        ;;
                    aarch64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
                        ;;
                    *)
                        echo -e "${gl_hong}错误: 不支持的架构 ${cpu_arch}${gl_bai}" >&2
                        echo "将使用通用带宽值 500 Mbps" >&2
                        echo "500"
                        return 1
                        ;;
                                esac
                
                cd /tmp
                wget -q "$download_url" -O speedtest.tgz && \
                tar -xzf speedtest.tgz && \
                mv speedtest /usr/local/bin/ && \
                rm -f speedtest.tgz
                
                if [ $? -ne 0 ]; then
                    echo -e "${gl_hong}安装失败，将使用通用值${gl_bai}" >&2
                    echo "500"
                    return 1
                fi
            fi
            
            # 智能测速：获取附近服务器列表，按距离依次尝试
            echo -e "${gl_zi}正在搜索附近测速服务器...${gl_bai}" >&2
            
            # 【修复】获取服务器列表时也必须加上隐私参数，否则也会返回空导致触发 "auto"
            local servers_list=$(speedtest $st_args --servers 2>/dev/null | sed -nE 's/^[[:space:]]*([0-9]+).*/\1/p' | head -n 10)
            
            if [ -z "$servers_list" ]; then
                echo -e "${gl_huang}无法获取服务器列表，使用自动选择...${gl_bai}" >&2
                servers_list="auto"
            else
                local server_count=$(echo "$servers_list" | wc -l)
                echo -e "${gl_lv}✅ 找到 ${server_count} 个附近服务器${gl_bai}" >&2
            fi
            echo "" >&2
            
            local speedtest_output=""
            local upload_speed=""
            local attempt=0
            local max_attempts=5  # 最多尝试5个服务器
            
            # 逐个尝试服务器
            for server_id in $servers_list; do
                attempt=$((attempt + 1))
                
                if [ $attempt -gt $max_attempts ]; then
                    echo -e "${gl_huang}已尝试 ${max_attempts} 个服务器，停止尝试${gl_bai}" >&2
                    break
                fi
                
                if [ "$server_id" = "auto" ]; then
                    echo -e "${gl_zi}[尝试 ${attempt}] 自动选择最近服务器...${gl_bai}" >&2
                    speedtest_output=$(speedtest $st_args 2>&1)
                else
                    echo -e "${gl_zi}[尝试 ${attempt}] 测试服务器 #${server_id}...${gl_bai}" >&2
                    speedtest_output=$(speedtest $st_args --server-id="$server_id" 2>&1)
                fi
                
                echo "$speedtest_output" >&2
                echo "" >&2
                
                # 提取上传速度
                upload_speed=""
                if echo "$speedtest_output" | grep -q "Upload:"; then
                    upload_speed=$(echo "$speedtest_output" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)
                fi
                if [ -z "$upload_speed" ]; then
                    upload_speed=$(echo "$speedtest_output" | grep -i "Upload:" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}')
                fi
                
                # 检查是否成功
                if [ -n "$upload_speed" ] && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                    local success_server=$(echo "$speedtest_output" | grep "Server:" | head -n1 | sed 's/.*Server: //')
                    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                    echo -e "${gl_lv}✅ 测速成功！${gl_bai}" >&2
                    echo -e "${gl_zi}使用服务器: ${success_server}${gl_bai}" >&2
                    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                    echo "" >&2
                    break
                else
                    local failed_server=$(echo "$speedtest_output" | grep "Server:" | head -n1 | sed 's/.*Server: //' | sed 's/[[:space:]]*$//')
                    if [ -n "$failed_server" ]; then
                        echo -e "${gl_huang}⚠️  失败: ${failed_server}${gl_bai}" >&2
                    else
                        echo -e "${gl_huang}⚠️  此服务器失败${gl_bai}" >&2
                    fi
                    echo -e "${gl_zi}继续尝试下一个服务器...${gl_bai}" >&2
                    echo "" >&2
                fi
            done
            
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 所有尝试都失败了
            if [ -z "$upload_speed" ] || echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                echo -e "${gl_huang}⚠️  无法自动检测带宽${gl_bai}" >&2
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                echo "" >&2
                echo -e "${gl_zi}原因: 测速服务器可能暂时不可用${gl_bai}" >&2
                echo "" >&2
                echo -e "${gl_kjlan}默认配置方案：${gl_bai}" >&2
                echo -e "  带宽:       ${gl_huang}1000 Mbps (1 Gbps)${gl_bai}" >&2
                echo -e "  缓冲区:     ${gl_huang}根据地区自动计算${gl_bai}" >&2
                echo -e "  适用场景:   ${gl_zi}标准 1Gbps 服务器（覆盖大多数场景）${gl_bai}" >&2
                echo "" >&2
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                echo "" >&2
                
                # 询问用户确认
                read -e -p "是否使用默认值 1000 Mbps？(Y/N) [Y]: " use_default
                use_default=${use_default:-Y}
                
                case "$use_default" in
                    [Yy])
                        echo "" >&2
                        echo -e "${gl_lv}✅ 使用默认配置: 1000 Mbps${gl_bai}" >&2
                        echo "1000"
                        return 0
                        ;;
                    [Nn])
                        echo "" >&2
                        echo -e "${gl_zi}请手动输入带宽值${gl_bai}" >&2
                        local manual_bandwidth=""
                        while true; do
                            read -e -p "请输入上传带宽（单位：Mbps，如 500、1000、2000）: " manual_bandwidth
                            if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && [ "$manual_bandwidth" -gt 0 ]; then
                                echo "" >&2
                                echo -e "${gl_lv}✅ 使用自定义值: ${manual_bandwidth} Mbps${gl_bai}" >&2
                                echo "$manual_bandwidth"
                                return 0
                            else
                                echo -e "${gl_hong}❌ 请输入有效的数字${gl_bai}" >&2
                            fi
                        done
                        ;;
                    *)
                        echo "" >&2
                        echo -e "${gl_huang}输入无效，使用默认值 1000 Mbps${gl_bai}" >&2
                        echo "1000"
                        return 0
                        ;;
                esac
            fi
            
            # 转为整数并验证
            local upload_mbps=${upload_speed%.*}
            if ! [[ "$upload_mbps" =~ ^[0-9]+$ ]] || [ "$upload_mbps" -le 0 ] 2>/dev/null; then
                echo -e "${gl_huang}⚠️ 检测到的带宽值异常 (${upload_speed})，使用默认值 1000 Mbps${gl_bai}" >&2
                upload_mbps=1000
            fi

            echo -e "${gl_lv}✅ 检测到上传带宽: ${upload_mbps} Mbps${gl_bai}" >&2
            echo "" >&2

            # 返回带宽值
            echo "$upload_mbps"
            return 0
            ;;
        2)
            # 手动指定测速服务器ID
            echo "" >&2
            echo -e "${gl_kjlan}=== 手动指定测速服务器 ===${gl_bai}" >&2
            echo "" >&2
            
            # 检查speedtest是否安装
            if ! command -v speedtest &>/dev/null; then
                echo -e "${gl_huang}speedtest 未安装，正在安装...${gl_bai}" >&2
                local cpu_arch=$(uname -m)
                local download_url
                case "$cpu_arch" in
                    x86_64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
                        ;;
                    aarch64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
                        ;;
                    *)
                        echo -e "${gl_hong}错误: 不支持的架构 ${cpu_arch}${gl_bai}" >&2
                        echo "将使用通用值 1000 Mbps" >&2
                        echo "1000"
                        return 1
                        ;;
                esac
                
                cd /tmp
                wget -q "$download_url" -O speedtest.tgz && \
                tar -xzf speedtest.tgz && \
                mv speedtest /usr/local/bin/ && \
                rm -f speedtest.tgz
                
                if [ $? -ne 0 ]; then
                    echo -e "${gl_hong}安装失败，将使用默认值 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 1
                fi
                echo -e "${gl_lv}✅ speedtest 安装成功${gl_bai}" >&2
                echo "" >&2
            fi
            
            # 显示如何查看服务器列表
            echo -e "${gl_zi}📋 如何查看可用的测速服务器：${gl_bai}" >&2
            echo "" >&2
            echo -e "  方法1：查看所有服务器列表" >&2
            echo -e "  ${gl_huang}speedtest --servers${gl_bai}" >&2
            echo "" >&2
            echo -e "  方法2：只显示附近服务器（推荐）" >&2
            echo -e "  ${gl_huang}speedtest --servers | head -n 20${gl_bai}" >&2
            echo "" >&2
            echo -e "${gl_zi}💡 服务器列表格式说明：${gl_bai}" >&2
            echo -e "  每行开头的数字就是服务器ID" >&2
            echo -e "  例如: ${gl_huang}12345${gl_bai}) 服务商名称 (位置, 距离)" >&2
            echo "" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 询问是否现在查看服务器列表
            read -e -p "是否现在查看附近的测速服务器列表？(Y/N) [Y]: " show_list
            show_list=${show_list:-Y}
            
            if [[ "$show_list" =~ ^[Yy]$ ]]; then
                echo "" >&2
                echo -e "${gl_kjlan}附近的测速服务器列表：${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                # 【修复】此处也带上统一的隐私参数
                speedtest $st_args --servers 2>/dev/null | head -n 20 >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "" >&2
            fi
            
            # 输入服务器ID
            local server_id=""
            while true; do
                read -e -p "$(echo -e "${gl_huang}请输入测速服务器ID（纯数字）: ${gl_bai}")" server_id
                
                if [[ "$server_id" =~ ^[0-9]+$ ]]; then
                    break
                else
                    echo -e "${gl_hong}❌ 无效输入，请输入纯数字的服务器ID${gl_bai}" >&2
                fi
            done
            
            # 使用指定服务器测速
            echo "" >&2
            echo -e "${gl_huang}正在使用服务器 #${server_id} 测速...${gl_bai}" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 【修复】带上隐私参数进行指定测速
            local speedtest_output=$(speedtest $st_args --server-id="$server_id" 2>&1)
            echo "$speedtest_output" >&2
            echo "" >&2
            
            # 提取上传速度
            local upload_speed=""
            if echo "$speedtest_output" | grep -q "Upload:"; then
                upload_speed=$(echo "$speedtest_output" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)
            fi
            if [ -z "$upload_speed" ]; then
                upload_speed=$(echo "$speedtest_output" | grep -i "Upload:" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}')
            fi
            
            # 检查测速是否成功
            if [ -n "$upload_speed" ] && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                local upload_mbps=${upload_speed%.*}
                if ! [[ "$upload_mbps" =~ ^[0-9]+$ ]] || [ "$upload_mbps" -le 0 ] 2>/dev/null; then
                    echo -e "${gl_huang}⚠️ 检测到的带宽值异常 (${upload_speed})，使用默认值 1000 Mbps${gl_bai}" >&2
                    upload_mbps=1000
                fi
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo -e "${gl_lv}✅ 测速成功！${gl_bai}" >&2
                echo -e "${gl_lv}检测到上传带宽: ${upload_mbps} Mbps${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "" >&2
                echo "$upload_mbps"
                return 0
            else
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo -e "${gl_hong}❌ 测速失败${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "" >&2
                echo -e "${gl_zi}可能原因：${gl_bai}" >&2
                echo "  - 服务器ID不存在或已下线" >&2
                echo "  - 网络连接问题" >&2
                echo "  - 该服务器暂时不可用" >&2
                echo "" >&2
                
                read -e -p "是否使用默认值 1000 Mbps？(Y/N) [Y]: " use_default
                use_default=${use_default:-Y}
                
                if [[ "$use_default" =~ ^[Yy]$ ]]; then
                    echo "" >&2
                    echo -e "${gl_lv}✅ 使用默认配置: 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 0
                else
                    echo "" >&2
                    echo -e "${gl_zi}请手动输入带宽值${gl_bai}" >&2
                    local manual_bandwidth=""
                    while true; do
                        read -e -p "请输入上传带宽（单位：Mbps，如 500、1000、2000）: " manual_bandwidth
                        if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && [ "$manual_bandwidth" -gt 0 ]; then
                            echo "" >&2
                            echo -e "${gl_lv}✅ 使用自定义值: ${manual_bandwidth} Mbps${gl_bai}" >&2
                            echo "$manual_bandwidth"
                            return 0
                        else
                            echo -e "${gl_hong}❌ 请输入有效的数字${gl_bai}" >&2
                        fi
                    done
                fi
            fi
            ;;
        3)
            # 手动选择预设档位
            echo "" >&2
            echo -e "${gl_kjlan}=== 手动选择带宽档位 ===${gl_bai}" >&2
            echo "" >&2
            echo "请选择带宽档位：" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            echo -e "${gl_huang}【小带宽 VPS】${gl_bai}" >&2
            echo "1. 100 Mbps   (NAT/极小带宽)" >&2
            echo "2. 200 Mbps   (小型VPS)" >&2
            echo "3. 300 Mbps   (入门服务器)" >&2
            echo "" >&2
            echo -e "${gl_huang}【中等带宽】${gl_bai}" >&2
            echo "4. 500 Mbps   (标准小带宽)" >&2
            echo "5. 700 Mbps   (准千兆)" >&2
            echo "6. 1 Gbps ⭐  (标准VPS/最常见)" >&2
            echo "" >&2
            echo -e "${gl_huang}【高带宽服务器】${gl_bai}" >&2
            echo "7. 1.5 Gbps   (中高端VPS)" >&2
            echo "8. 2 Gbps      (高性能VPS)" >&2
            echo "9. 2.5 Gbps   (准万兆)" >&2
            echo "" >&2
            echo -e "${gl_zi}提示: 缓冲区大小将根据后续选择的地区自动计算${gl_bai}" >&2
            echo "" >&2
            echo -e "${gl_zi}【其他选项】${gl_bai}" >&2
            echo "10. 自定义输入（手动指定任意带宽值）" >&2
            echo "0. 返回上级菜单" >&2
            echo "" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 读取用户选择
            local preset_choice=""
            read -e -p "请输入选择 [6]: " preset_choice
            preset_choice=${preset_choice:-6}  # 默认选择6 (1 Gbps)
            
            case "$preset_choice" in
                1)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 100 Mbps${gl_bai}" >&2
                    echo "100"
                    return 0
                    ;;
                2)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 200 Mbps${gl_bai}" >&2
                    echo "200"
                    return 0
                    ;;
                3)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 300 Mbps${gl_bai}" >&2
                    echo "300"
                    return 0
                    ;;
                4)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 500 Mbps${gl_bai}" >&2
                    echo "500"
                    return 0
                    ;;
                5)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 700 Mbps${gl_bai}" >&2
                    echo "700"
                    return 0
                    ;;
                6)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 0
                    ;;
                7)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 1500 Mbps${gl_bai}" >&2
                    echo "1500"
                    return 0
                    ;;
                8)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 2000 Mbps${gl_bai}" >&2
                    echo "2000"
                    return 0
                    ;;
                9)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 2500 Mbps${gl_bai}" >&2
                    echo "2500"
                    return 0
                    ;;
                10)
                    # 自定义输入
                    echo "" >&2
                    echo -e "${gl_zi}=== 自定义输入 ===${gl_bai}" >&2
                    echo "" >&2
                    local manual_bandwidth=""
                    while true; do
                        read -e -p "请输入带宽值（单位：Mbps，如 750、1200）: " manual_bandwidth
                        if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && [ "$manual_bandwidth" -gt 0 ]; then
                            echo "" >&2
                            echo -e "${gl_lv}✅ 使用自定义值: ${manual_bandwidth} Mbps${gl_bai}" >&2
                            echo "$manual_bandwidth"
                            return 0
                        else
                            echo -e "${gl_hong}❌ 请输入有效的正整数${gl_bai}" >&2
                        fi
                    done
                    ;;
                0)
                    # 返回上级菜单
                    echo "" >&2
                    echo -e "${gl_huang}已取消选择，返回上级菜单${gl_bai}" >&2
                    echo "1000"  # 返回默认值，避免空值
                    return 1
                    ;;
                *)
                    echo "" >&2
                    echo -e "${gl_hong}无效选择，使用默认值 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 1
                    ;;
            esac
            ;;
        *)
            echo -e "${gl_huang}无效选择，使用默认值 1000 Mbps${gl_bai}" >&2
            echo "1000"
            return 1
            ;;
    esac
}

# 缓冲区大小计算函数
calculate_buffer_size() {
    local bandwidth=$1
    local region=${2:-asia}  # asia（亚太）或 overseas（美欧）
    local buffer_mb
    local bandwidth_level

    # 输入验证：确保 bandwidth 是正整数
    if ! [[ "$bandwidth" =~ ^[0-9]+$ ]] || [ "$bandwidth" -le 0 ] 2>/dev/null; then
        local fallback_mb=16
        [ "$region" = "overseas" ] && fallback_mb=64
        echo -e "${gl_huang}⚠️ 带宽值无效 (${bandwidth})，使用默认值 ${fallback_mb}MB${gl_bai}" >&2
        echo "$fallback_mb"
        return 0
    fi

    if [ "$region" = "overseas" ]; then
        # ===== 美国/欧洲档位（RTT ~200ms，buffer ≈ BDP × 2.5，上限 64MB）=====
        if [ "$bandwidth" -eq 100 ]; then
            buffer_mb=8
            bandwidth_level="预设档位（100 Mbps·远距离）"
        elif [ "$bandwidth" -eq 200 ]; then
            buffer_mb=16
            bandwidth_level="预设档位（200 Mbps·远距离）"
        elif [ "$bandwidth" -eq 300 ]; then
            buffer_mb=20
            bandwidth_level="预设档位（300 Mbps·远距离）"
        elif [ "$bandwidth" -eq 500 ]; then
            buffer_mb=32
            bandwidth_level="预设档位（500 Mbps·远距离）"
        elif [ "$bandwidth" -eq 700 ]; then
            buffer_mb=48
            bandwidth_level="预设档位（700 Mbps·远距离）"
        elif [ "$bandwidth" -eq 1000 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（1 Gbps·远距离）"
        elif [ "$bandwidth" -eq 1500 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（1.5 Gbps·远距离）"
        elif [ "$bandwidth" -eq 2000 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（2 Gbps·远距离）"
        elif [ "$bandwidth" -eq 2500 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（2.5 Gbps·远距离）"
        elif [ "$bandwidth" -lt 500 ]; then
            buffer_mb=16
            bandwidth_level="小带宽（< 500 Mbps·远距离）"
        elif [ "$bandwidth" -lt 1000 ]; then
            buffer_mb=48
            bandwidth_level="中等带宽（500-1000 Mbps·远距离）"
        elif [ "$bandwidth" -lt 2000 ]; then
            buffer_mb=64
            bandwidth_level="标准带宽（1-2 Gbps·远距离）"
        else
            buffer_mb=64
            bandwidth_level="高带宽（> 2 Gbps·远距离）"
        fi
    else
        # ===== 亚太地区档位（RTT ~50ms，原有逻辑不变）=====
        if [ "$bandwidth" -eq 100 ]; then
            buffer_mb=6
            bandwidth_level="预设档位（100 Mbps）"
        elif [ "$bandwidth" -eq 200 ]; then
            buffer_mb=8
            bandwidth_level="预设档位（200 Mbps）"
        elif [ "$bandwidth" -eq 300 ]; then
            buffer_mb=10
            bandwidth_level="预设档位（300 Mbps）"
        elif [ "$bandwidth" -eq 500 ]; then
            buffer_mb=12
            bandwidth_level="预设档位（500 Mbps）"
        elif [ "$bandwidth" -eq 700 ]; then
            buffer_mb=14
            bandwidth_level="预设档位（700 Mbps）"
        elif [ "$bandwidth" -eq 1000 ]; then
            buffer_mb=16
            bandwidth_level="预设档位（1 Gbps）"
        elif [ "$bandwidth" -eq 1500 ]; then
            buffer_mb=20
            bandwidth_level="预设档位（1.5 Gbps）"
        elif [ "$bandwidth" -eq 2000 ]; then
            buffer_mb=24
            bandwidth_level="预设档位（2 Gbps）"
        elif [ "$bandwidth" -eq 2500 ]; then
            buffer_mb=28
            bandwidth_level="预设档位（2.5 Gbps）"
        elif [ "$bandwidth" -lt 500 ]; then
            buffer_mb=8
            bandwidth_level="小带宽（< 500 Mbps）"
        elif [ "$bandwidth" -lt 1000 ]; then
            buffer_mb=12
            bandwidth_level="中等带宽（500-1000 Mbps）"
        elif [ "$bandwidth" -lt 2000 ]; then
            buffer_mb=16
            bandwidth_level="标准带宽（1-2 Gbps）"
        elif [ "$bandwidth" -lt 5000 ]; then
            buffer_mb=24
            bandwidth_level="高带宽（2-5 Gbps）"
        elif [ "$bandwidth" -lt 10000 ]; then
            buffer_mb=28
            bandwidth_level="超高带宽（5-10 Gbps）"
        else
            buffer_mb=32
            bandwidth_level="极高带宽（> 10 Gbps）"
        fi
    fi

    # 显示计算结果（输出到stderr）
    local region_label="亚太地区"
    [ "$region" = "overseas" ] && region_label="美国/欧洲"
    echo "" >&2
    echo -e "${gl_kjlan}根据带宽和地区计算最优缓冲区:${gl_bai}" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo -e "  检测带宽: ${gl_huang}${bandwidth} Mbps${gl_bai}" >&2
    echo -e "  服务地区: ${gl_huang}${region_label}${gl_bai}" >&2
    echo -e "  带宽等级: ${bandwidth_level}" >&2
    echo -e "  推荐缓冲区: ${gl_lv}${buffer_mb} MB${gl_bai}" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "" >&2
    
    # 询问确认
    if [ "$AUTO_MODE" = "1" ]; then
        confirm=Y
    else
        read -e -p "$(echo -e "${gl_huang}是否使用推荐值 ${buffer_mb}MB？(Y/N) [Y]: ${gl_bai}")" confirm
        confirm=${confirm:-Y}
    fi

    case "$confirm" in
        [Yy])
            # 返回缓冲区大小（MB）
            echo "$buffer_mb"
            return 0
            ;;
        *)
            local default_mb=16
            [ "$region" = "overseas" ] && default_mb=32
            echo "" >&2
            echo -e "${gl_huang}已取消，将使用通用值 ${default_mb}MB${gl_bai}" >&2
            echo "$default_mb"
            return 1
            ;;
    esac
}

#=============================================================================
# SWAP智能检测和建议函数（集成到选项2/3）
#=============================================================================
check_and_suggest_swap() {
    local mem_total=$(free -m | awk 'NR==2{print $2}')
    local swap_total=$(free -m | awk 'NR==3{print $2}')
    local recommended_swap
    local need_swap=0
    
    # 判断是否需要SWAP
    if [ "$mem_total" -lt 2048 ]; then
        # 小于2GB内存，强烈建议配置SWAP
        need_swap=1
    elif [ "$mem_total" -lt 4096 ] && [ "$swap_total" -eq 0 ]; then
        # 2-4GB内存且没有SWAP，建议配置
        need_swap=1
    fi
    
    # 如果不需要SWAP，直接返回
    if [ "$need_swap" -eq 0 ]; then
        return 0
    fi
    
    # 计算推荐的SWAP大小
    if [ "$mem_total" -lt 512 ]; then
        recommended_swap=1024
    elif [ "$mem_total" -lt 1024 ]; then
        recommended_swap=$((mem_total * 2))
    elif [ "$mem_total" -lt 2048 ]; then
        recommended_swap=$((mem_total * 3 / 2))
    elif [ "$mem_total" -lt 4096 ]; then
        recommended_swap=$mem_total
    else
        recommended_swap=4096
    fi
    
    # 显示建议信息
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_huang}检测到虚拟内存（SWAP）需要优化${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "  物理内存:       ${gl_huang}${mem_total}MB${gl_bai}"
    echo -e "  当前 SWAP:      ${gl_huang}${swap_total}MB${gl_bai}"
    echo -e "  推荐 SWAP:      ${gl_lv}${recommended_swap}MB${gl_bai}"
    echo ""
    
    if [ "$mem_total" -lt 1024 ]; then
        echo -e "${gl_zi}原因: 小内存机器（<1GB）强烈建议配置SWAP，避免内存不足导致程序崩溃${gl_bai}"
    elif [ "$mem_total" -lt 2048 ]; then
        echo -e "${gl_zi}原因: 1-2GB内存建议配置SWAP，提供缓冲空间${gl_bai}"
    elif [ "$mem_total" -lt 4096 ]; then
        echo -e "${gl_zi}原因: 2-4GB内存建议配置少量SWAP作为保险${gl_bai}"
    fi
    
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    # 询问用户
    if [ "$AUTO_MODE" = "1" ]; then
        confirm=Y
    else
        read -e -p "$(echo -e "${gl_huang}是否现在配置虚拟内存？(Y/N): ${gl_bai}")" confirm
    fi

    case "$confirm" in
        [Yy])
            echo ""
            echo -e "${gl_lv}开始配置虚拟内存...${gl_bai}"
            echo ""
            add_swap "$recommended_swap"
            echo ""
            echo -e "${gl_lv}✅ 虚拟内存配置完成！${gl_bai}"
            echo ""
            echo -e "${gl_zi}继续执行 BBR 优化配置...${gl_bai}"
            sleep 2
            return 0
            ;;
        [Nn])
            echo ""
            echo -e "${gl_huang}已跳过虚拟内存配置${gl_bai}"
            echo -e "${gl_zi}继续执行 BBR 优化配置...${gl_bai}"
            echo ""
            sleep 2
            return 1
            ;;
        *)
            echo ""
            echo -e "${gl_huang}输入无效，已跳过虚拟内存配置${gl_bai}"
            echo -e "${gl_zi}继续执行 BBR 优化配置...${gl_bai}"
            echo ""
            sleep 2
            return 1
            ;;
    esac
}

#=============================================================================
# 配置冲突检测与清理（避免被其他 sysctl 覆盖）
#=============================================================================
check_and_clean_conflicts() {
    echo -e "${gl_kjlan}=== 检查 sysctl 配置冲突 ===${gl_bai}"
    local conflicts=()
    # 搜索 /etc/sysctl.d/ 下可能覆盖 tcp_rmem/tcp_wmem 的高序号文件
    for conf in /etc/sysctl.d/[0-9]*-*.conf; do
        [ -f "$conf" ] || continue
        [ "$conf" = "$SYSCTL_CONF" ] && continue
        if grep -qE "(^|\s)net\.ipv4\.tcp_(rmem|wmem)" "$conf" 2>/dev/null; then
            base=$(basename "$conf")
            num=$(echo "$base" | sed -n 's/^\([0-9]\+\).*/\1/p')
            # 99 及以上优先生效，可能覆盖本脚本
            if [ -n "$num" ] && [ "$num" -ge 99 ]; then
                conflicts+=("$conf")
            fi
        fi
    done

    # 主配置文件直接设置也会覆盖
    local has_sysctl_conflict=0
    if [ -f /etc/sysctl.conf ] && grep -qE "(^|\s)net\.ipv4\.tcp_(rmem|wmem)" /etc/sysctl.conf 2>/dev/null; then
        has_sysctl_conflict=1
    fi

    if [ ${#conflicts[@]} -eq 0 ] && [ $has_sysctl_conflict -eq 0 ]; then
        echo -e "${gl_lv}✓ 未发现可能的覆盖配置${gl_bai}"
        return 0
    fi

    echo -e "${gl_huang}发现可能的覆盖配置：${gl_bai}"
    for f in "${conflicts[@]}"; do
        echo "  - $f"; grep -E "net\.ipv4\.tcp_(rmem|wmem)" "$f" | sed 's/^/      /'
    done
    [ $has_sysctl_conflict -eq 1 ] && echo "  - /etc/sysctl.conf (含 tcp_rmem/tcp_wmem)"

    if [ "$AUTO_MODE" = "1" ]; then
        ans=Y
    else
        read -e -p "是否自动禁用/注释这些覆盖配置？(Y/N): " ans
    fi
    case "$ans" in
        [Yy])
            # 注释 /etc/sysctl.conf 中相关行
            if [ $has_sysctl_conflict -eq 1 ]; then
                # 先创建一次备份，再用 sed -i 逐行注释（避免多次 .bak 覆盖）
                cp /etc/sysctl.conf /etc/sysctl.conf.bak.conflict 2>/dev/null
                sed -i '/^net\.ipv4\.tcp_wmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
                sed -i '/^net\.ipv4\.tcp_rmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
                sed -i '/^net\.core\.rmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
                sed -i '/^net\.core\.wmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
                echo -e "${gl_lv}✓ 已注释 /etc/sysctl.conf 中的相关配置（备份: .bak.conflict）${gl_bai}"
            fi
            # 将高优先级冲突文件重命名禁用
            for f in "${conflicts[@]}"; do
                if [ ! -f "$f" ]; then
                    echo -e "${gl_lv}✓ 已跳过: $(basename "$f")（已处理）${gl_bai}"
                    continue
                fi
                if mv "$f" "${f}.disabled.$(date +%Y%m%d_%H%M%S)" 2>/dev/null; then
                    echo -e "${gl_lv}✓ 已禁用: $(basename "$f")${gl_bai}"
                else
                    echo -e "${gl_hong}✗ 无法禁用: $(basename "$f")，请手动处理${gl_bai}"
                fi
            done
            ;;
        *)
            echo -e "${gl_huang}已跳过自动清理，可能导致新配置未完全生效${gl_bai}"
            ;;
    esac
}

#=============================================================================
# 立即生效与防分片函数（无需重启）
#=============================================================================

# 获取需应用 qdisc 的网卡（排除常见虚拟接口）
eligible_ifaces() {
    for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        dev=$(basename "$d")
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
        esac
        echo "$dev"
    done
}

# tc fq 立即生效（无需重启）
apply_tc_fq_now() {
    if ! command -v tc >/dev/null 2>&1; then
        echo -e "${gl_huang}警告: 未检测到 tc（iproute2），跳过 fq 应用${gl_bai}"
        return 0
    fi
    local applied=0
    for dev in $(eligible_ifaces); do
        tc qdisc replace dev "$dev" root fq 2>/dev/null && applied=$((applied+1))
    done
    [ $applied -gt 0 ] && echo -e "${gl_lv}已对 $applied 个网卡应用 fq（即时生效）${gl_bai}" || echo -e "${gl_huang}未发现可应用 fq 的网卡${gl_bai}"
}

# MSS clamp（防分片）自动启用
apply_mss_clamp() {
    local action=$1  # enable|disable
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${gl_huang}警告: 未检测到 iptables，跳过 MSS clamp${gl_bai}"
        return 0
    fi
    if [ "$action" = "enable" ]; then
        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
          || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    else
        iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
    fi
}

#=============================================================================
# BBR 配置函数（智能检测版）
#=============================================================================

# 直连/落地优化配置
bbr_configure_direct() {
    echo -e "${gl_lv}=== BBR网络优化 ===${gl_bai}"
    echo ""
    
    # 步骤 0：SWAP智能检测和建议
    echo -e "${gl_zi}[步骤 1/6] 检测虚拟内存（SWAP）配置...${gl_bai}"
    check_and_suggest_swap
    
    # 步骤 0.5：带宽检测和缓冲区计算
    echo ""
    echo -e "${gl_zi}[步骤 2/6] 检测服务器带宽并计算最优缓冲区...${gl_bai}"

    local detected_bandwidth=$(detect_bandwidth)

    # 地区选择（影响缓冲区大小：高延迟地区需要更大缓冲区）
    local region="asia"
    local region_choice=""
    echo ""
    echo -e "${gl_kjlan}请选择服务器主要服务的地区：${gl_bai}"
    echo ""
    echo "1. 亚太地区（港/日/新/韩等）⭐ 推荐"
    echo "   延迟较低（RTT < 100ms），使用标准缓冲区"
    echo ""
    echo "2. 美国/欧洲（跨太平洋/大西洋）"
    echo "   延迟较高（RTT 150-300ms），使用大缓冲区"
    echo ""
    read -e -p "请输入选择 [1]: " region_choice
    region_choice=${region_choice:-1}
    case "$region_choice" in
        2) region="overseas" ;;
        *) region="asia" ;;
    esac

    local buffer_mb=$(calculate_buffer_size "$detected_bandwidth" "$region")
    local buffer_bytes=$((buffer_mb * 1024 * 1024))
    
    echo -e "${gl_lv}✅ 将使用 ${buffer_mb}MB 缓冲区配置${gl_bai}"
    sleep 2
    
    echo ""
    echo -e "${gl_zi}[步骤 3/6] 清理配置冲突...${gl_bai}"
    echo "正在检查配置冲突..."
    
    # 备份主配置文件（如果还没备份）
    if [ -f /etc/sysctl.conf ] && ! [ -f /etc/sysctl.conf.bak.original ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.original
        echo "已备份: /etc/sysctl.conf -> /etc/sysctl.conf.bak.original"
    fi
    
    # 注释掉 /etc/sysctl.conf 中的 TCP 缓冲区配置（避免覆盖）
    if [ -f /etc/sysctl.conf ]; then
        clean_sysctl_conf
        echo "已清理 /etc/sysctl.conf 中的冲突配置"
    fi
    
    # 删除可能存在的软链接
    if [ -L /etc/sysctl.d/99-sysctl.conf ]; then
        rm -f /etc/sysctl.d/99-sysctl.conf
        echo "已删除配置软链接"
    fi
    
    # 检查并清理可能覆盖的新旧配置冲突
    check_and_clean_conflicts

    # 步骤 3：创建独立配置文件（使用动态缓冲区）
    echo ""
    echo -e "${gl_zi}[步骤 4/6] 创建配置文件...${gl_bai}"
    echo "正在创建新配置..."
    
    # 获取物理内存用于虚拟内存参数调整
    local mem_total=$(free -m | awk 'NR==2{print $2}')
    local vm_swappiness=5
    local vm_dirty_ratio=15
    local vm_min_free_kbytes=65536
    
    # 根据内存大小微调虚拟内存参数
    if [ "$mem_total" -lt 2048 ]; then
        vm_swappiness=20
        vm_dirty_ratio=20
        vm_min_free_kbytes=32768
    fi
    
    cat > "$SYSCTL_CONF" << EOF
# BBR v3 Direct/Endpoint Configuration (Intelligent Detection Edition)
# Generated on $(date)
# Bandwidth: ${detected_bandwidth} Mbps | Region: ${region} | Buffer: ${buffer_mb} MB

# 队列调度算法
net.core.default_qdisc=fq

# 拥塞控制算法
net.ipv4.tcp_congestion_control=bbr

# TCP 缓冲区优化（智能检测：${buffer_mb}MB）
net.core.rmem_max=${buffer_bytes}
net.core.wmem_max=${buffer_bytes}
net.ipv4.tcp_rmem=4096 87380 ${buffer_bytes}
net.ipv4.tcp_wmem=4096 65536 ${buffer_bytes}

# ===== 直连/落地优化参数 =====

# TIME_WAIT 重用（启用，提高并发）
net.ipv4.tcp_tw_reuse=1

# 端口范围（最大化）
net.ipv4.ip_local_port_range=1024 65535

# 连接队列（高性能）
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192

# 网络队列（高带宽优化）
net.core.netdev_max_backlog=5000

# 高级TCP优化
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1

# ===== Reality 网络优化参数 =====

# 发送低水位（上传速度优化关键）
net.ipv4.tcp_notsent_lowat=16384

# 连接回收优化
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_max_tw_buckets=5000

# TCP Fast Open（节省1个RTT，加速连接建立）
net.ipv4.tcp_fastopen=3

# TCP保活优化（更快检测死连接）
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

# UDP缓冲区（QUIC/Hysteria 支持）
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# TCP安全增强
net.ipv4.tcp_syncookies=1

# 虚拟内存优化（根据物理内存调整）
vm.swappiness=${vm_swappiness}
vm.dirty_ratio=${vm_dirty_ratio}
vm.dirty_background_ratio=5
vm.overcommit_memory=1
vm.min_free_kbytes=${vm_min_free_kbytes}
vm.vfs_cache_pressure=50

# CPU调度优化
kernel.sched_autogroup_enabled=0
kernel.numa_balancing=0
EOF

    # 检查配置文件是否创建成功
    if [ ! -f "$SYSCTL_CONF" ] || [ ! -s "$SYSCTL_CONF" ]; then
        echo -e "${gl_hong}❌ 配置文件创建失败！请检查磁盘空间和权限${gl_bai}"
        return 1
    fi

    # 步骤 4：应用配置
    echo ""
    echo -e "${gl_zi}[步骤 5/6] 应用所有优化参数...${gl_bai}"
    echo "正在应用配置..."
    local sysctl_output
    sysctl_output=$(sysctl -p "$SYSCTL_CONF" 2>&1)
    local sysctl_rc=$?
    if [ $sysctl_rc -ne 0 ]; then
        echo -e "${gl_huang}⚠️ sysctl 部分参数应用失败（可能有不支持的参数）:${gl_bai}"
        echo "$sysctl_output" | grep -i "error\|invalid\|unknown\|cannot" | head -5
        echo -e "${gl_zi}已支持的参数仍然生效，不影响整体优化${gl_bai}"
    else
        echo -e "${gl_lv}✓ 所有 sysctl 参数已成功应用${gl_bai}"
    fi

    # 立即应用 fq，并启用 MSS clamp（无需重启）
    echo "正在应用队列与防分片（无需重启）..."
    apply_tc_fq_now >/dev/null 2>&1
    apply_mss_clamp enable >/dev/null 2>&1

    # 持久化 tc fq 和 iptables MSS clamp（重启后自动恢复）
    echo "正在配置重启持久化..."
    # 创建 systemd 服务实现 tc fq + MSS clamp 开机恢复
    cat > /etc/systemd/system/bbr-optimize-persist.service << 'PERSISTEOF'
[Unit]
Description=BBR Optimize - Restore tc fq and MSS clamp after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/bbr-optimize-apply.sh

[Install]
WantedBy=multi-user.target
PERSISTEOF

    cat > /usr/local/bin/bbr-optimize-apply.sh << 'APPLYEOF'
#!/bin/bash
# BBR Optimize 重启恢复脚本 - 自动生成，勿手动编辑
# 应用 tc fq 到所有物理网卡
for d in /sys/class/net/*; do
    [ -e "$d" ] || continue
    dev=$(basename "$d")
    case "$dev" in
        lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
    esac
    tc qdisc replace dev "$dev" root fq 2>/dev/null
done
# 应用 iptables MSS clamp
if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
      || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
fi
# 禁用透明大页
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
fi
# 优化 TCP 初始拥塞窗口（加速连接起步）
DEF_ROUTE=$(ip route show default 2>/dev/null | head -1)
if [ -n "$DEF_ROUTE" ]; then
    CLEAN_ROUTE=$(echo "$DEF_ROUTE" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
    ip route change $CLEAN_ROUTE initcwnd 32 initrwnd 32 2>/dev/null
fi
# RPS/RFS 多核网络优化（遍历所有物理网卡）
CPU_COUNT=$(nproc 2>/dev/null || echo 1)
if [ "$CPU_COUNT" -gt 1 ]; then
    RPS_MASK=$(printf '%x' $((2**CPU_COUNT - 1)))
    FLOW_ENTRIES=$((4096 * CPU_COUNT))
    echo "$FLOW_ENTRIES" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
    for D in /sys/class/net/*; do
        [ -e "$D" ] || continue
        DEV=$(basename "$D")
        case "$DEV" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
        esac
        [ -d "/sys/class/net/$DEV/queues" ] || continue
        for RXQ in /sys/class/net/$DEV/queues/rx-*/rps_cpus; do
            [ -f "$RXQ" ] && echo "$RPS_MASK" > "$RXQ" 2>/dev/null
        done
        for RXQ_DIR in /sys/class/net/$DEV/queues/rx-*/; do
            [ -f "${RXQ_DIR}rps_flow_cnt" ] && echo "$((FLOW_ENTRIES / CPU_COUNT))" > "${RXQ_DIR}rps_flow_cnt" 2>/dev/null
        done
    done
fi
APPLYEOF
    chmod +x /usr/local/bin/bbr-optimize-apply.sh
    systemctl daemon-reload 2>/dev/null
    systemctl enable bbr-optimize-persist.service 2>/dev/null
    echo -e "${gl_lv}✓ tc fq / MSS clamp / 透明大页 重启持久化已配置${gl_bai}"

    # 配置文件描述符限制
    echo "正在优化文件描述符限制..."
    if ! grep -q "^\* soft nofile 524288" /etc/security/limits.conf 2>/dev/null && \
       ! grep -q "BBR - 文件描述符优化" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << 'LIMITSEOF'
# BBR - 文件描述符优化
* soft nofile 524288
* hard nofile 524288
LIMITSEOF
    fi
    ulimit -n 524288 2>/dev/null

    # 禁用透明大页面（当前运行时）
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    fi

    # 优化 TCP 初始拥塞窗口（加速连接起步，节省1-2个RTT）
    echo "正在优化 TCP 初始拥塞窗口..."
    local def_route
    def_route=$(ip route show default 2>/dev/null | head -1)
    if [ -n "$def_route" ]; then
        # 清除已有的 initcwnd/initrwnd 再重新设置，避免重复
        local clean_route
        clean_route=$(echo "$def_route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
        if ip route change $clean_route initcwnd 32 initrwnd 32 2>/dev/null; then
            echo -e "${gl_lv}✓ initcwnd=32 initrwnd=32 已应用（加速 TCP 连接起步）${gl_bai}"
        else
            echo -e "${gl_huang}⚠️ initcwnd 设置失败（不影响其他优化）${gl_bai}"
        fi
    else
        echo -e "${gl_huang}⚠️ 未检测到默认路由，跳过 initcwnd 优化${gl_bai}"
    fi

    # RPS/RFS 多核网络优化（将网卡收包分散到所有 CPU 核心）
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 1)
    if [ "$cpu_count" -gt 1 ]; then
        echo "正在配置 RPS/RFS 多核网络优化..."
        # 计算 CPU 掩码（所有核心参与）：2核=3, 4核=f, 8核=ff
        local rps_mask
        rps_mask=$(printf '%x' $((2**cpu_count - 1)))
        local flow_entries=$((4096 * cpu_count))
        echo "$flow_entries" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
        # 遍历所有物理网卡（排除虚拟/隧道接口）
        local rps_ok=0
        local rps_devs=""
        local dev
        for d in /sys/class/net/*; do
            [ -e "$d" ] || continue
            dev=$(basename "$d")
            case "$dev" in
                lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
            esac
            [ -d "/sys/class/net/$dev/queues" ] || continue
            # 设置 RPS：将收包分散到所有核心
            for rxq in /sys/class/net/$dev/queues/rx-*/rps_cpus; do
                if [ -f "$rxq" ]; then
                    echo "$rps_mask" > "$rxq" 2>/dev/null
                    # 写入后读回验证（有些环境 echo 返回0但内核没接受）
                    local verify_val
                    verify_val=$(cat "$rxq" 2>/dev/null | tr -d ',' | sed 's/^0*//')
                    [ -z "$verify_val" ] && verify_val="0"
                    [ "$verify_val" = "$rps_mask" ] && rps_ok=1
                fi
            done
            # 设置 RFS：同一连接的包尽量在同一核处理（减少 cache miss）
            for rxq_dir in /sys/class/net/$dev/queues/rx-*/; do
                if [ -f "${rxq_dir}rps_flow_cnt" ]; then
                    echo "$((flow_entries / cpu_count))" > "${rxq_dir}rps_flow_cnt" 2>/dev/null
                fi
            done
            rps_devs="${rps_devs} ${dev}"
        done
        if [ $rps_ok -eq 1 ]; then
            echo -e "${gl_lv}✓ RPS/RFS 已启用（${cpu_count} 核，掩码: 0x${rps_mask}，网卡:${rps_devs}）${gl_bai}"
        else
            echo -e "${gl_huang}⚠️ RPS 设置未生效（当前虚拟化环境可能不支持，不影响其他优化）${gl_bai}"
        fi
    else
        echo -e "${gl_zi}ℹ 单核 CPU，跳过 RPS/RFS（单核无需分担）${gl_bai}"
    fi

    # 步骤 5：验证配置是否真正生效
    echo ""
    echo -e "${gl_zi}[步骤 6/6] 验证配置...${gl_bai}"
    
    local actual_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local actual_wmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
    local actual_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    
    echo ""
    echo -e "${gl_kjlan}=== 配置验证 ===${gl_bai}"
    
    # 验证队列算法
    if [ "$actual_qdisc" = "fq" ]; then
        echo -e "队列算法: ${gl_lv}$actual_qdisc ✓${gl_bai}"
    else
        echo -e "队列算法: ${gl_huang}$actual_qdisc (期望: fq) ⚠${gl_bai}"
    fi
    
    # 验证拥塞控制
    if [ "$actual_cc" = "bbr" ]; then
        echo -e "拥塞控制: ${gl_lv}$actual_cc ✓${gl_bai}"
    else
        echo -e "拥塞控制: ${gl_huang}$actual_cc (期望: bbr) ⚠${gl_bai}"
    fi
    
    # 验证缓冲区（动态）
    local actual_wmem_mb=$((actual_wmem / 1048576))
    local actual_rmem_mb=$((actual_rmem / 1048576))
    
    if [ "$actual_wmem" = "$buffer_bytes" ]; then
        echo -e "发送缓冲区: ${gl_lv}${buffer_mb}MB ✓${gl_bai}"
    else
        echo -e "发送缓冲区: ${gl_huang}${actual_wmem_mb}MB (期望: ${buffer_mb}MB) ⚠${gl_bai}"
    fi
    
    if [ "$actual_rmem" = "$buffer_bytes" ]; then
        echo -e "接收缓冲区: ${gl_lv}${buffer_mb}MB ✓${gl_bai}"
    else
        echo -e "接收缓冲区: ${gl_huang}${actual_rmem_mb}MB (期望: ${buffer_mb}MB) ⚠${gl_bai}"
    fi

    # 验证 initcwnd
    local actual_initcwnd
    actual_initcwnd=$(ip route show default 2>/dev/null | head -1 | grep -oP 'initcwnd \K[0-9]+')
    if [ "$actual_initcwnd" = "32" ]; then
        echo -e "初始窗口:   ${gl_lv}initcwnd=$actual_initcwnd ✓${gl_bai}"
    elif [ -n "$actual_initcwnd" ]; then
        echo -e "初始窗口:   ${gl_huang}initcwnd=$actual_initcwnd (期望: 32) ⚠${gl_bai}"
    else
        echo -e "初始窗口:   ${gl_huang}未设置 (期望: initcwnd=32) ⚠${gl_bai}"
    fi

    # 验证 RPS
    if [ "$cpu_count" -gt 1 ]; then
        local expected_mask
        expected_mask=$(printf '%x' $((2**cpu_count - 1)))
        local rps_verify_devs=""
        local rps_all_ok=1
        for d in /sys/class/net/*; do
            [ -e "$d" ] || continue
            local vdev=$(basename "$d")
            case "$vdev" in
                lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
            esac
            [ -f "/sys/class/net/$vdev/queues/rx-0/rps_cpus" ] || continue
            local rps_val
            # rps_cpus 可能返回 "3" 或 "00000003" 或 "00000000,00000003"
            rps_val=$(cat /sys/class/net/$vdev/queues/rx-0/rps_cpus 2>/dev/null | tr -d ',' | sed 's/^0*//')
            [ -z "$rps_val" ] && rps_val="0"
            if [ "$rps_val" = "$expected_mask" ]; then
                rps_verify_devs="${rps_verify_devs} ${vdev}✓"
            else
                rps_verify_devs="${rps_verify_devs} ${vdev}✗"
                rps_all_ok=0
            fi
        done
        if [ -n "$rps_verify_devs" ]; then
            if [ $rps_all_ok -eq 1 ]; then
                echo -e "RPS/RFS:    ${gl_lv}${cpu_count}核分担 (0x${expected_mask})${rps_verify_devs} ✓${gl_bai}"
            else
                echo -e "RPS/RFS:    ${gl_huang}部分网卡未生效:${rps_verify_devs} ⚠${gl_bai}"
            fi
        else
            echo -e "RPS/RFS:    ${gl_huang}未检测到物理网卡 ⚠${gl_bai}"
        fi
    else
        echo -e "RPS/RFS:    ${gl_zi}单核跳过${gl_bai}"
    fi

    echo ""

    # 最终判断
    if [ "$actual_qdisc" = "fq" ] && [ "$actual_cc" = "bbr" ] && \
       [ "$actual_wmem" = "$buffer_bytes" ] && [ "$actual_rmem" = "$buffer_bytes" ]; then
        echo -e "${gl_lv}✅ BBR网络优化完成并已生效！${gl_bai}"
    else
        echo -e "${gl_huang}⚠️ 配置已保存但部分参数未生效${gl_bai}"
        echo -e "${gl_huang}建议执行以下操作：${gl_bai}"
        echo "1. 检查是否有其他配置文件冲突"
        echo "2. 重启服务器使配置完全生效: reboot"
    fi
}

#=============================================================================
# 状态检查函数
#=============================================================================

check_bbr_status() {
    echo -e "${gl_kjlan}=== 当前系统状态 ===${gl_bai}"
    local kernel_release
    kernel_release=$(uname -r)
    echo "内核版本: $kernel_release"
    
    local congestion="未知"
    local qdisc="未知"
    local bbr_version=""
    local bbr_active=0
    
    if command -v sysctl &>/dev/null; then
        congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
        echo "拥塞控制算法: $congestion"
        echo "队列调度算法: $qdisc"
        
        if command -v modinfo &>/dev/null; then
            bbr_version=$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/ {print $2}')
            if [ -n "$bbr_version" ]; then
                if [ "$bbr_version" = "3" ]; then
                    echo -e "BBR 版本: ${gl_lv}v${bbr_version} ✓${gl_bai}"
                else
                    echo -e "BBR 版本: ${gl_huang}v${bbr_version} (不是 v3)${gl_bai}"
                fi
            fi
        fi
    fi
    
    if [ "$congestion" = "bbr" ] && [ "$bbr_version" = "3" ]; then
        bbr_active=1
    fi
    
    local xanmod_pkg_installed=0
    local dpkg_available=0
    if command -v dpkg &>/dev/null; then
        dpkg_available=1
        if dpkg -l 2>/dev/null | grep -qE '^ii\s+linux-.*xanmod'; then
            xanmod_pkg_installed=1
        fi
    fi
    
    local xanmod_running=0
    if echo "$kernel_release" | grep -qi 'xanmod'; then
        xanmod_running=1
    fi
    
    local status=1
    
    if [ $xanmod_pkg_installed -eq 1 ]; then
        echo -e "XanMod 内核: ${gl_lv}已安装 ✓${gl_bai}"
        status=0
    elif [ $xanmod_running -eq 1 ]; then
        echo -e "XanMod 内核: ${gl_huang}内核包已卸载，但当前运行版本仍为 ${kernel_release}，请重启系统使卸载完全生效${gl_bai}"
    else
        echo -e "XanMod 内核: ${gl_huang}未安装${gl_bai}"
    fi
    
    if [ $status -ne 0 ] && [ $bbr_active -eq 1 ]; then
        echo -e "${gl_kjlan}提示: 当前仍在运行 BBR v3 模块，重启后将恢复系统默认配置${gl_bai}"
    fi
    
    if [ $status -ne 0 ] && [ $dpkg_available -eq 0 ]; then
        # 非 Debian 系统：仅当内核名确实含 xanmod 时才认为已安装
        # BBR v3 活跃不等于 XanMod（用户可能自编译内核），避免误触发 update 流程
        if [ $xanmod_running -eq 1 ]; then
            status=0
        fi
    fi
    
    return $status
}

#=============================================================================
# XanMod 内核安装（官方源）
#=============================================================================

xanmod_get_repo_suite() {
    local suite=""

    if [ -r /etc/os-release ]; then
        suite=$( ( . /etc/os-release; printf '%s' "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}" ) )
    fi

    if [ -z "$suite" ] && command -v lsb_release &>/dev/null; then
        suite=$(lsb_release -sc 2>/dev/null)
    fi

    if [ -z "$suite" ]; then
        echo -e "${gl_hong}错误: 无法识别系统发行版 codename，不能添加 XanMod 软件源${gl_bai}" >&2
        return 1
    fi

    case "$suite" in
        bookworm|trixie|forky|sid|noble|plucky|questing|resolute|faye|gigi|wilma|xia|zara|zena)
            ;;
        *)
            echo -e "${gl_huang}警告: 当前发行版 codename 为 ${suite}，可能不在 XanMod 官方支持列表中${gl_bai}" >&2
            ;;
    esac

    echo "$suite"
}

xanmod_write_repo() {
    local gpg_key_file=$1
    local repo_file=$2
    local suite

    suite=$(xanmod_get_repo_suite) || return 1
    echo "deb [signed-by=${gpg_key_file}] https://deb.xanmod.org ${suite} main" | \
        tee "$repo_file" > /dev/null
    echo -e "${gl_lv}✅ XanMod 软件源: ${suite}${gl_bai}"
}

xanmod_select_kernel_package() {
    local version=$1
    local candidates=()

    case "$version" in
        1)
            candidates=("linux-xanmod-lts-x64v1")
            ;;
        2)
            candidates=("linux-xanmod-x64v2" "linux-xanmod-lts-x64v2")
            ;;
        3)
            candidates=("linux-xanmod-x64v3" "linux-xanmod-lts-x64v3")
            ;;
        4)
            # XanMod 官方 mainline 当前不提供 x64v4；v4 CPU 使用 x64v3 更稳妥。
            candidates=("linux-xanmod-x64v3" "linux-xanmod-lts-x64v3")
            ;;
        *)
            candidates=("linux-xanmod-x64v3" "linux-xanmod-lts-x64v3")
            ;;
    esac

    local pkg
    for pkg in "${candidates[@]}"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            echo "$pkg"
            return 0
        fi
    done

    return 1
}

install_xanmod_kernel() {
    clear
    echo -e "${gl_kjlan}=== 安装 XanMod 内核与 BBR v3 ===${gl_bai}"
    echo "视频教程: https://www.bilibili.com/video/BV14K421x7BS"
    echo "------------------------------------------------"
    echo "支持系统: Debian/Ubuntu (x86_64 & ARM64)"
    echo -e "${gl_huang}警告: 将升级 Linux 内核，请提前备份重要数据！${gl_bai}"
    echo "------------------------------------------------"
    read -e -p "确定继续安装吗？(Y/N): " choice

    case "$choice" in
        [Yy])
            ;;
        *)
            echo "已取消安装"
            return 1
            ;;
    esac
    
    # 检测 CPU 架构
    local cpu_arch=$(uname -m)
    
    # ARM 架构特殊处理
    if [ "$cpu_arch" = "aarch64" ]; then
        echo -e "${gl_kjlan}检测到 ARM64 架构，使用专用安装脚本${gl_bai}"

        install_package curl coreutils || return 1

        local tmp_dir
        tmp_dir=$(mktemp -d 2>/dev/null)
        if [ -z "$tmp_dir" ]; then
            echo -e "${gl_hong}错误: 无法创建临时目录用于下载 ARM64 脚本${gl_bai}"
            return 1
        fi

        local script_url="https://jhb.ovh/jb/bbrv3arm.sh"
        local sha256_url="${script_url}.sha256"
        local sha512_url="${script_url}.sha512"
        local script_path="${tmp_dir}/bbrv3arm.sh"
        local sha256_path="${tmp_dir}/bbrv3arm.sh.sha256"
        local sha512_path="${tmp_dir}/bbrv3arm.sh.sha512"

        echo "日志: 正在下载 ARM64 安装脚本到临时目录 ${tmp_dir}"

        if ! curl -fsSL "$script_url" -o "$script_path"; then
            echo -e "${gl_hong}错误: ARM64 安装脚本下载失败${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        if ! curl -fsSL "$sha256_url" -o "$sha256_path"; then
            echo -e "${gl_hong}错误: 未能获取发布方提供的 SHA256 校验文件${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        if ! curl -fsSL "$sha512_url" -o "$sha512_path"; then
            echo -e "${gl_hong}错误: 未能获取发布方提供的 SHA512 校验文件${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        local expected_sha256 expected_sha512 actual_sha256 actual_sha512
        expected_sha256=$(awk 'NR==1 {print $1}' "$sha256_path")
        expected_sha512=$(awk 'NR==1 {print $1}' "$sha512_path")

        if [ -z "$expected_sha256" ] || [ -z "$expected_sha512" ]; then
            echo -e "${gl_hong}错误: 校验文件内容无效${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        actual_sha256=$(sha256sum "$script_path" | awk '{print $1}')
        actual_sha512=$(sha512sum "$script_path" | awk '{print $1}')

        if [ "$expected_sha256" != "$actual_sha256" ]; then
            echo -e "${gl_hong}错误: SHA256 校验失败，已中止${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        if [ "$expected_sha512" != "$actual_sha512" ]; then
            echo -e "${gl_hong}错误: SHA512 校验失败，已中止${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        echo -e "${gl_lv}SHA256 与 SHA512 校验通过${gl_bai}"
        echo -e "${gl_huang}安全提示:${gl_bai} ARM64 脚本已下载至 ${script_path}"
        echo "如需，您可在继续前使用 cat/less 等命令手动审查脚本内容。"
        read -s -r -p "审查完成后按 Enter 继续执行（Ctrl+C 取消）..." _
        echo ""

        if bash "$script_path"; then
            rm -rf "$tmp_dir"
            echo -e "${gl_lv}ARM BBR v3 安装完成${gl_bai}"
            return 0
        else
            echo -e "${gl_hong}安装失败${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi
    
    # 显式检查 x86_64 架构
    if [ "$cpu_arch" != "x86_64" ]; then
        echo -e "${gl_hong}错误: 不支持的 CPU 架构: ${cpu_arch}${gl_bai}"
        echo "本脚本仅支持 x86_64 和 aarch64 架构"
        return 1
    fi

    # x86_64 架构安装流程
    # 检查系统支持
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ]; then
            echo -e "${gl_hong}错误: 仅支持 Debian 和 Ubuntu 系统${gl_bai}"
            return 1
        fi
    else
        echo -e "${gl_hong}错误: 无法确定操作系统类型${gl_bai}"
        return 1
    fi

    # 环境准备
    check_disk_space 3 || return 1
    check_swap
    install_package wget gnupg || { echo -e "${gl_hong}错误: 无法安装必要依赖 wget/gnupg${gl_bai}"; return 1; }

    # 添加 XanMod GPG 密钥（分步执行，避免管道 $? 只检查最后一条命令）
    echo "正在添加 XanMod 仓库密钥..."
    local gpg_key_file="/usr/share/keyrings/xanmod-archive-keyring.gpg"
    local key_tmp=$(mktemp)
    local gpg_ok=false

    # 尝试1: 从镜像源下载
    if wget -qO "$key_tmp" "${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/archive.key" 2>/dev/null && \
       [ -s "$key_tmp" ]; then
        if gpg --dearmor -o "$gpg_key_file" --yes < "$key_tmp" 2>/dev/null; then
            gpg_ok=true
        fi
    fi

    # 尝试2: 从 XanMod 官方源下载
    if [ "$gpg_ok" = false ]; then
        echo -e "${gl_huang}镜像源失败，尝试 XanMod 官方源...${gl_bai}"
        if wget -qO "$key_tmp" "https://dl.xanmod.org/archive.key" 2>/dev/null && \
           [ -s "$key_tmp" ]; then
            if gpg --dearmor -o "$gpg_key_file" --yes < "$key_tmp" 2>/dev/null; then
                gpg_ok=true
            fi
        fi
    fi

    rm -f "$key_tmp"

    if [ "$gpg_ok" = false ]; then
        echo -e "${gl_hong}错误: GPG 密钥导入失败，无法继续安装${gl_bai}"
        echo "请检查网络连接后重试"
        return 1
    fi
    echo -e "${gl_lv}✅ GPG 密钥导入成功${gl_bai}"

    local xanmod_repo_file="/etc/apt/sources.list.d/xanmod-release.list"

    # 添加 XanMod 仓库（使用系统 codename；旧 releases suite 已为空）
    xanmod_write_repo "$gpg_key_file" "$xanmod_repo_file" || return 1

    # 检测 CPU 架构版本（使用安全临时目录）
    echo "正在检测 CPU 支持的最优内核版本..."
    local detect_dir=$(mktemp -d)
    local detect_script="${detect_dir}/check_x86-64_psabi.sh"
    local version=""

    if wget -qO "$detect_script" "${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/check_x86-64_psabi.sh" 2>/dev/null && \
       [ -s "$detect_script" ]; then
        chmod +x "$detect_script"
        version=$("$detect_script" 2>/dev/null | sed -nE 's/.*x86-64-v([1-4]).*/\1/p' | head -1)
    fi
    rm -rf "$detect_dir"

    # 在线检测失败时，使用本地 /proc/cpuinfo 检测 CPU 支持的最高等级
    if ! [[ "$version" =~ ^[1-4]$ ]]; then
        echo -e "${gl_huang}在线检测脚本不可用，使用本地 CPU 特征检测...${gl_bai}"
        local cpu_flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null)
        if echo "$cpu_flags" | grep -qw 'avx512f'; then
            version="4"
        elif echo "$cpu_flags" | grep -qw 'avx2'; then
            version="3"
        elif echo "$cpu_flags" | grep -qw 'sse4_2'; then
            version="2"
        else
            version="1"
        fi
        echo -e "${gl_lv}本地检测结果: CPU 支持 x86-64-v${version}${gl_bai}"
    fi

    # 安装 XanMod 内核
    echo "正在更新软件包列表..."
    if ! apt-get update; then
        echo -e "${gl_huang}⚠️  apt-get update 部分失败，尝试继续安装...${gl_bai}"
    fi

    local xanmod_package
    xanmod_package=$(xanmod_select_kernel_package "$version")
    if [ -z "$xanmod_package" ]; then
        echo -e "${gl_hong}错误: 未找到适合 x86-64-v${version} 的 XanMod 内核包${gl_bai}"
        echo -e "${gl_huang}可用包参考:${gl_bai}"
        apt-cache search '^linux-xanmod' 2>/dev/null | awk '{print "  - " $1}' | head -20
        rm -f "$xanmod_repo_file"
        return 1
    fi

    echo -e "${gl_lv}将安装: ${xanmod_package}${gl_bai}"
    if [ "$version" = "4" ] && echo "$xanmod_package" | grep -q 'x64v3'; then
        echo -e "${gl_huang}说明: XanMod 官方 mainline 当前不提供 x64v4，x86-64-v4 CPU 使用 x64v3 包${gl_bai}"
    elif [ "$version" = "1" ] && echo "$xanmod_package" | grep -q 'lts'; then
        echo -e "${gl_huang}说明: XanMod 官方 mainline 当前不提供 x64v1，x86-64-v1 CPU 使用 LTS 包${gl_bai}"
    fi

    apt-get install -y "$xanmod_package"

    if [ $? -ne 0 ]; then
        echo -e "${gl_hong}内核安装失败！${gl_bai}"
        rm -f "$xanmod_repo_file"
        return 1
    fi

    # 验证内核是否真正安装成功
    if ! dpkg -l 2>/dev/null | awk -v pkg="$xanmod_package" '$1 == "ii" && $2 == pkg { found=1 } END { exit !found }'; then
        echo -e "${gl_hong}内核包安装验证失败！${gl_bai}"
        rm -f "$xanmod_repo_file"
        return 1
    fi

    echo -e "${gl_lv}XanMod 内核安装成功！${gl_bai}"
    echo -e "${gl_huang}提示: 请先重启系统加载新内核，然后再配置 BBR${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━ CPU 架构信息 ━━━━━━━━━━${gl_bai}"
    echo -e "  CPU 架构等级: ${gl_lv}x86-64-v${version}${gl_bai}"
    echo -e "  安装内核包: ${gl_lv}${xanmod_package}${gl_bai}"
    echo -e "  ${gl_huang}说明: 本机 CPU 最高支持 v${version}，已安装官方仓库中最匹配的内核包${gl_bai}"
    echo -e "  ${gl_huang}官方 mainline 当前提供 x64v2/x64v3；x64v1 使用 LTS，x64v4 使用 x64v3${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}后续更新: 再次运行选项1即可检查并安装最新内核${gl_bai}"

    rm -f "$xanmod_repo_file"
    echo -e "${gl_lv}已自动清理 XanMod 软件源（如需更新可再次运行选项1）${gl_bai}"

    return 0
}


#=============================================================================
# IP地址获取函数
#=============================================================================

ip_address() {
    local public_ip=""
    local candidate=""
    local external_api_success=false
    local last_curl_status=0
    local external_api_notice=""

    if candidate=$(curl -4 -fsS --max-time 2 https://ipinfo.io/ip 2>/dev/null); then
        candidate=$(echo "$candidate" | tr -d '\r\n')
        if [ -n "$candidate" ]; then
            public_ip="$candidate"
            external_api_success=true
        fi
    else
        last_curl_status=$?
    fi

    if [ "$external_api_success" = false ]; then
        if candidate=$(curl -4 -fsS --max-time 2 https://api.ip.sb/ip 2>/dev/null); then
            candidate=$(echo "$candidate" | tr -d '\r\n')
            if [ -n "$candidate" ]; then
                public_ip="$candidate"
                external_api_success=true
            fi
        else
            last_curl_status=$?
        fi
    fi

    if [ "$external_api_success" = false ]; then
        if candidate=$(curl -4 -fsS --max-time 2 https://ifconfig.me/ip 2>/dev/null); then
            candidate=$(echo "$candidate" | tr -d '\r\n')
            if [ -n "$candidate" ]; then
                public_ip="$candidate"
                external_api_success=true
            fi
        else
            last_curl_status=$?
        fi
    fi

    if [ "$external_api_success" = false ]; then
        public_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    fi

    if [ -z "$public_ip" ]; then
        public_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    if [ -z "$public_ip" ]; then
        public_ip="外部接口不可达"
    fi

    if [ "$external_api_success" = false ]; then
        external_api_notice="外部接口不可达"
        if [ "$last_curl_status" -ne 0 ]; then
            external_api_notice+=" (curl 返回码 $last_curl_status)"
        fi
    fi

    local local_ipv4=""
    local_ipv4=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    if [ -z "$local_ipv4" ]; then
        local_ipv4=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$local_ipv4" ]; then
        local_ipv4="外部接口不可达"
    fi

    if ! isp_info=$(curl -fsS --max-time 2 http://ipinfo.io/org 2>/dev/null); then
        isp_info=""
    else
        isp_info=$(echo "$isp_info" | tr -d '\r\n')
    fi

    if [ -z "$isp_info" ] && [ -n "$external_api_notice" ]; then
        isp_info="$external_api_notice"
    fi

    if echo "$isp_info" | grep -Eiq 'mobile|unicom|telecom'; then
        ipv4_address="$local_ipv4"
    else
        ipv4_address="$public_ip"
    fi

    if [ -z "$ipv4_address" ]; then
        ipv4_address="$local_ipv4"
    fi

    if ! ipv6_address=$(curl -fsS --max-time 2 https://v6.ipinfo.io/ip 2>/dev/null); then
        ipv6_address=""
    else
        ipv6_address=$(echo "$ipv6_address" | tr -d '\r\n')
    fi

    if [ -n "$external_api_notice" ] && [ -z "$isp_info" ]; then
        isp_info="$external_api_notice"
    fi

    if [ -z "$isp_info" ]; then
        isp_info="未获取到运营商信息"
    fi
}
#=============================================================================
# 网络流量统计函数
#=============================================================================

output_status() {
    output=$(awk 'BEGIN { rx_total = 0; tx_total = 0 }
        $1 ~ /^(eth|ens|enp|eno)[0-9]+/ {
            rx_total += $2
            tx_total += $10
        }
        END {
            rx_units = "Bytes";
            tx_units = "Bytes";
            if (rx_total > 1024) { rx_total /= 1024; rx_units = "K"; }
            if (rx_total > 1024) { rx_total /= 1024; rx_units = "M"; }
            if (rx_total > 1024) { rx_total /= 1024; rx_units = "G"; }

            if (tx_total > 1024) { tx_total /= 1024; tx_units = "K"; }
            if (tx_total > 1024) { tx_total /= 1024; tx_units = "M"; }
            if (tx_total > 1024) { tx_total /= 1024; tx_units = "G"; }

            printf("%.2f%s %.2f%s\n", rx_total, rx_units, tx_total, tx_units);
        }' /proc/net/dev)

    rx=$(echo "$output" | awk '{print $1}')
    tx=$(echo "$output" | awk '{print $2}')
}


run_speedtest() {
    while true; do
        clear
        echo -e "${gl_kjlan}=== 服务器带宽测试 ===${gl_bai}"
        echo ""
        
        # 检测 CPU 架构
        local cpu_arch=$(uname -m)
        echo "检测到系统架构: ${gl_huang}${cpu_arch}${gl_bai}"
        echo ""
        
        # 检查并安装 speedtest
        if ! command -v speedtest &>/dev/null; then
            echo "Speedtest 未安装，正在下载安装..."
            echo "------------------------------------------------"
            echo ""
            
            local download_url
            local tarball_name
            
            case "$cpu_arch" in
                x86_64)
                    download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
                    tarball_name="ookla-speedtest-1.2.0-linux-x86_64.tgz"
                    echo "使用 AMD64 架构版本..."
                    ;;
                aarch64)
                    download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
                    tarball_name="speedtest.tgz"
                    echo "使用 ARM64 架构版本..."
                    ;;
                *)
                    echo -e "${gl_hong}错误: 不支持的架构 ${cpu_arch}${gl_bai}"
                    echo "目前仅支持 x86_64 和 aarch64 架构"
                    echo ""
                    break_end
                    return 1
                    ;;
            esac
            
            cd /tmp || {
                echo -e "${gl_hong}错误: 无法切换到 /tmp 目录${gl_bai}"
                break_end
                return 1
            }
            
            echo "正在下载..."
            if [ "$cpu_arch" = "aarch64" ]; then
                curl -Lo "$tarball_name" "$download_url"
            else
                wget -q "$download_url"
            fi
            
            if [ $? -ne 0 ]; then
                echo -e "${gl_hong}下载失败！${gl_bai}"
                break_end
                return 1
            fi
            
            echo "正在解压..."
            tar -xzf "$tarball_name"
            
            if [ $? -ne 0 ]; then
                echo -e "${gl_hong}解压失败！${gl_bai}"
                rm -f "$tarball_name"
                break_end
                return 1
            fi
            
            mv speedtest /usr/local/bin/
            rm -f "$tarball_name"
            
            echo -e "${gl_lv}✅ Speedtest 安装成功！${gl_bai}"
            echo ""
        else
            echo -e "${gl_lv}✅ Speedtest 已安装${gl_bai}"
        fi
        
        echo ""
        echo -e "${gl_kjlan}请选择测速模式：${gl_bai}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "1. 自动测速"
        echo "2. 手动选择服务器 ⭐ 推荐"
        echo ""
        echo "0. 返回主菜单"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        read -e -p "请输入选择 [1]: " speed_choice
        speed_choice=${speed_choice:-1}
        
        case "$speed_choice" in
            1)
                # 自动测速（使用智能重试逻辑）
                echo ""
                echo -e "${gl_zi}正在搜索附近测速服务器...${gl_bai}"
                
                # 获取附近服务器列表
                local servers_list=$(speedtest --accept-license --servers 2>/dev/null | sed -nE 's/^[[:space:]]*([0-9]+).*/\1/p' | head -n 10)
                
                if [ -z "$servers_list" ]; then
                    echo -e "${gl_huang}无法获取服务器列表，使用自动选择...${gl_bai}"
                    servers_list="auto"
                else
                    local server_count=$(echo "$servers_list" | wc -l)
                    echo -e "${gl_lv}✅ 找到 ${server_count} 个附近服务器${gl_bai}"
                fi
                echo ""
                
                local speedtest_output=""
                local test_success=false
                local attempt=0
                local max_attempts=5
                
                for server_id in $servers_list; do
                    attempt=$((attempt + 1))
                    
                    if [ $attempt -gt $max_attempts ]; then
                        echo -e "${gl_huang}已尝试 ${max_attempts} 个服务器，停止尝试${gl_bai}"
                        break
                    fi
                    
                    if [ "$server_id" = "auto" ]; then
                        echo -e "${gl_zi}[尝试 ${attempt}] 自动选择最近服务器...${gl_bai}"
                        echo "------------------------------------------------"
                        speedtest --accept-license
                        test_success=true
                        break
                    else
                        echo -e "${gl_zi}[尝试 ${attempt}] 测试服务器 #${server_id}...${gl_bai}"
                        echo "------------------------------------------------"
                        speedtest_output=$(speedtest --accept-license --server-id="$server_id" 2>&1)
                        echo "$speedtest_output"
                        echo ""
                        
                        # 检查是否成功
                        if echo "$speedtest_output" | grep -q "Download:" && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                            echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                            echo -e "${gl_lv}✅ 测速成功！${gl_bai}"
                            echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                            test_success=true
                            break
                        else
                            echo -e "${gl_huang}⚠️ 此服务器测速失败，尝试下一个...${gl_bai}"
                            echo ""
                        fi
                    fi
                done
                
                if [ "$test_success" = false ]; then
                    echo ""
                    echo -e "${gl_hong}❌ 所有服务器测速均失败${gl_bai}"
                    echo -e "${gl_zi}建议使用「手动选择服务器」模式${gl_bai}"
                fi
                
                echo ""
                break_end
                ;;
            2)
                # 手动选择服务器
                echo ""
                echo -e "${gl_zi}正在获取附近服务器列表...${gl_bai}"
                echo ""
                
                local server_list_output=$(speedtest --accept-license --servers 2>/dev/null | head -n 15)
                
                if [ -z "$server_list_output" ]; then
                    echo -e "${gl_hong}❌ 无法获取服务器列表${gl_bai}"
                    echo ""
                    break_end
                    continue
                fi
                
                echo -e "${gl_kjlan}附近的测速服务器列表：${gl_bai}"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "$server_list_output"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo -e "${gl_zi}💡 提示：ID 列的数字就是服务器ID${gl_bai}"
                echo ""
                
                local server_id=""
                while true; do
                    read -e -p "$(echo -e "${gl_huang}请输入服务器ID（纯数字，输入0返回）: ${gl_bai}")" server_id
                    
                    if [ "$server_id" = "0" ]; then
                        break
                    elif [[ "$server_id" =~ ^[0-9]+$ ]]; then
                        echo ""
                        echo -e "${gl_huang}正在使用服务器 #${server_id} 测速...${gl_bai}"
                        echo "------------------------------------------------"
                        echo ""
                        
                        speedtest --accept-license --server-id="$server_id"
                        
                        echo ""
                        echo "------------------------------------------------"
                        break_end
                        break
                    else
                        echo -e "${gl_hong}❌ 无效输入，请输入纯数字的服务器ID${gl_bai}"
                    fi
                done
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${gl_hong}无效选择${gl_bai}"
                sleep 1
                ;;
        esac
    done
}


# 主菜单
#=============================================================================

show_main_menu() {
    clear

    local kernel_release current_cc kernel_line bbr_line config_line
    local conf_file="/etc/sysctl.d/99-bbr-xanmod.conf"

    kernel_release=$(uname -r 2>/dev/null || echo "未知")
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")

    # 1. 验证 XanMod 内核安装状态
    # (假设你保留了原有的 check_bbr_status 函数来判断是否安装了 XanMod)
    check_bbr_status >/dev/null 2>&1
    local is_installed=$?

    if echo "$kernel_release" | grep -qi 'xanmod'; then
        kernel_line="运行中"
    elif [ $is_installed -eq 0 ]; then
        kernel_line="已安装"
    else
        kernel_line="未安装"
    fi

    # 2. 核心修改：动态验证是否为 BBR v3
    if [ "$current_cc" = "bbr" ]; then
        # 通过检查 BBR v3 独有的内核参数 extra_acked_gain 来判断
        if sysctl -a 2>/dev/null | grep -q "net.ipv4.tcp_bbr_extra_acked_gain"; then
            bbr_line="已启用(BBR v3)"
        else
            bbr_line="已启用(BBR v1/v2)"
        fi
    else
        bbr_line="未启用"
    fi

    # 3. 判定 99-bbr-xanmod.conf 配置文件内容 (调用之前的独立验证函数)
    check_bbr_conf_status
    if [ $? -eq 0 ]; then
        config_line="已启用"
    else
        config_line="未配置"
    fi


    echo -e "${COLOR_GREEN}================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN}     BBR V3/ XanMod 网络调优     ${COLOR_RESET}"
    echo -e "${COLOR_GREEN}================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN}XanMod :${COLOR_RESET} ${COLOR_YELLOW}${kernel_line}${COLOR_RESET}"
    echo -e "${COLOR_GREEN}BBR    :${COLOR_RESET} ${COLOR_YELLOW}${bbr_line}${COLOR_RESET}"
    echo -e "${COLOR_GREEN}配置   :${COLOR_RESET} ${COLOR_YELLOW}${config_line}${COLOR_RESET}"
    echo -e "${COLOR_GREEN}================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN} 1. 安装/更新XanMod${COLOR_RESET}"
    echo -e "${COLOR_GREEN} 2. 开启网络优化${COLOR_RESET}"
    echo -e "${COLOR_GREEN} 3. 卸载网络优化${COLOR_RESET}"
    echo -e "${COLOR_GREEN} 0. 退出${COLOR_RESET}"
    echo -e "${COLOR_GREEN}================================${COLOR_RESET}"
    read -e -p "$(echo -e "${COLOR_GREEN}请输入选择: ")" choice
    echo -e "${COLOR_RESET}\c"

    case "$choice" in
        1)
            if [ $is_installed -eq 0 ]; then
                update_xanmod_kernel
            else
                install_xanmod_kernel && server_reboot
            fi
            ;;
        2)
            bbr_configure_direct
            break_end
            ;;
        3)
            uninstall_all
            ;;
        0)
            exit 0
            ;;
        *)
            echo "无效选择"
            sleep 2
            ;;
    esac
}

update_xanmod_kernel() {
    clear
    echo -e "${gl_kjlan}=== 更新 XanMod 内核 ===${gl_bai}"
    echo "------------------------------------------------"
    
    # 获取当前内核版本
    local current_kernel=$(uname -r)
    echo -e "当前内核版本: ${gl_huang}${current_kernel}${gl_bai}"
    echo ""
    
    # 检测 CPU 架构
    local cpu_arch=$(uname -m)
    
    # ARM 架构提示
    if [ "$cpu_arch" = "aarch64" ]; then
        echo -e "${gl_huang}ARM64 架构暂不支持自动更新${gl_bai}"
        echo "建议卸载后重新安装以获取最新版本"
        break_end
        return 1
    fi
    
    # x86_64 架构更新流程
    echo "正在检查可用更新..."
    
    local xanmod_repo_file="/etc/apt/sources.list.d/xanmod-release.list"

    # 添加/修正 XanMod 仓库（旧 releases suite 已为空）
    if [ ! -f "$xanmod_repo_file" ] || grep -qE 'deb\.xanmod\.org[[:space:]]+releases[[:space:]]+' "$xanmod_repo_file" 2>/dev/null; then
        echo "正在添加 XanMod 仓库..."

        # 添加密钥（分步执行，避免管道 $? 问题）
        local gpg_key_file="/usr/share/keyrings/xanmod-archive-keyring.gpg"
        local key_tmp=$(mktemp)
        local gpg_ok=false

        if wget -qO "$key_tmp" "${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/archive.key" 2>/dev/null && \
           [ -s "$key_tmp" ]; then
            if gpg --dearmor -o "$gpg_key_file" --yes < "$key_tmp" 2>/dev/null; then
                gpg_ok=true
            fi
        fi

        if [ "$gpg_ok" = false ]; then
            if wget -qO "$key_tmp" "https://dl.xanmod.org/archive.key" 2>/dev/null && \
               [ -s "$key_tmp" ]; then
                if gpg --dearmor -o "$gpg_key_file" --yes < "$key_tmp" 2>/dev/null; then
                    gpg_ok=true
                fi
            fi
        fi

        rm -f "$key_tmp"

        if [ "$gpg_ok" = false ]; then
            echo -e "${gl_hong}错误: GPG 密钥导入失败${gl_bai}"
            break_end
            return 1
        fi

        # 添加仓库（使用系统 codename；旧 releases suite 已为空）
        xanmod_write_repo "$gpg_key_file" "$xanmod_repo_file" || { break_end; return 1; }
    fi

    # 更新软件包列表
    echo "正在更新软件包列表..."
    if ! apt-get update > /dev/null 2>&1; then
        echo -e "${gl_huang}⚠️  apt-get update 部分失败，尝试继续...${gl_bai}"
    fi

    # 检查已安装的 XanMod 内核包（使用 ^ii 过滤，排除已卸载残留）
    local installed_packages=$(dpkg -l | grep -E '^ii\s+linux-.*xanmod' | awk '{print $2}')
    
    if [ -z "$installed_packages" ]; then
        echo -e "${gl_hong}错误: 未检测到已安装的 XanMod 内核${gl_bai}"
        break_end
        return 1
    fi
    
    echo -e "已安装的内核包:"
    echo "$installed_packages" | while read pkg; do
        echo "  - $pkg"
    done
    echo ""
    
    # 检查是否有可用更新
    local upgradable=$(apt list --upgradable 2>/dev/null | grep xanmod)
    
    if [ -z "$upgradable" ]; then
        local cpu_level
        cpu_level=$(echo "$installed_packages" | sed -nE 's/.*x64v([1-4]).*/\1/p' | head -1)
        [ -z "$cpu_level" ] && cpu_level="3"

        # 获取已安装的最新 XanMod 内核版本（从 linux-image 包名提取版本号并取最大值）
        local latest_installed
        latest_installed=$(echo "$installed_packages" \
            | sed -nE 's/^linux-image-([0-9]+\.[0-9]+\.[0-9]+-x64v[1-4]-xanmod[0-9]+)$/\1/p' \
            | sort -V | tail -1)

        local running_latest=0
        if [ -n "$latest_installed" ] && [ "$current_kernel" = "$latest_installed" ]; then
            running_latest=1
        fi

        if [ $running_latest -eq 1 ]; then
            echo -e "${gl_lv}✅ 当前运行内核已是最新版本！${gl_bai}"
        else
            echo -e "${gl_lv}✅ XanMod 内核包已是最新，但当前运行内核尚未切换！${gl_bai}"
            echo -e "  正在运行: ${gl_hong}${current_kernel}${gl_bai}"
            if [ -n "$latest_installed" ]; then
                echo -e "  最新已装: ${gl_lv}${latest_installed}${gl_bai}"
            else
                echo -e "  ${gl_huang}提示: 未能解析最新已装内核版本，请重启后再检查${gl_bai}"
            fi
            echo -e "  ${gl_huang}请重启系统 (reboot) 以切换到最新内核${gl_bai}"
        fi
        echo ""

        echo -e "${gl_kjlan}━━━━━━━━━━ CPU 架构信息 ━━━━━━━━━━${gl_bai}"
        echo -e "  CPU 架构等级: ${gl_lv}x86-64-v${cpu_level}${gl_bai}"
        echo -e "  当前运行内核: ${gl_lv}${current_kernel}${gl_bai}"
        if [ -n "$latest_installed" ] && [ $running_latest -ne 1 ]; then
            echo -e "  最新已装内核: ${gl_lv}${latest_installed}${gl_bai}"
        fi
        if [ $running_latest -eq 1 ]; then
            echo -e "  ${gl_huang}说明: 本机 CPU 最高支持 v${cpu_level}，当前已运行该等级最新内核${gl_bai}"
        else
            echo -e "  ${gl_huang}说明: 本机 CPU 最高支持 v${cpu_level}，最新内核已安装，重启后生效${gl_bai}"
        fi
        echo -e "  ${gl_huang}不同等级(v1-v4)的内核更新进度可能不同，以 XanMod 官方仓库为准${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"

        rm -f "$xanmod_repo_file"
        echo -e "${gl_lv}已自动清理 XanMod 软件源（如需更新可再次运行选项1）${gl_bai}"
        break_end
        return 0
    fi
    
    echo -e "${gl_huang}发现可用更新:${gl_bai}"
    echo "$upgradable"
    echo ""
    
    read -e -p "确定更新 XanMod 内核吗？(Y/N): " confirm
    
    case "$confirm" in
        [Yy])
            echo ""
            echo "正在更新内核..."
            apt install --only-upgrade -y $(echo "$installed_packages" | tr '\n' ' ')
            
            if [ $? -eq 0 ]; then
                echo ""
                echo -e "${gl_lv}✅ XanMod 内核更新成功！${gl_bai}"
                echo -e "${gl_huang}⚠️  请重启系统以加载新内核${gl_bai}"
                echo ""
                local cpu_level
                cpu_level=$(echo "$installed_packages" | sed -nE 's/.*x64v([1-4]).*/\1/p' | head -1)
                [ -z "$cpu_level" ] && cpu_level="3"
                local latest_installed
                latest_installed=$(dpkg -l 2>/dev/null | awk '/^ii\s+linux-image-[0-9].*xanmod/ {print $2}' | sed 's/^linux-image-//' | sort -V | tail -1)
                echo -e "${gl_kjlan}━━━━━━━━━━ CPU 架构信息 ━━━━━━━━━━${gl_bai}"
                echo -e "  CPU 架构等级: ${gl_lv}x86-64-v${cpu_level}${gl_bai}"
                if [ -n "$latest_installed" ]; then
                    echo -e "  最新已装内核: ${gl_lv}${latest_installed}${gl_bai}"
                else
                    echo -e "  已更新内核包: ${gl_lv}$(echo "$installed_packages" | head -1)${gl_bai}"
                fi
                echo -e "  ${gl_huang}说明: 本机 CPU 最高支持 v${cpu_level}，已更新至该等级的最新内核${gl_bai}"
                echo -e "  ${gl_huang}不同等级(v1-v4)的内核更新进度可能不同，以 XanMod 官方仓库为准${gl_bai}"
                echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                echo ""
                echo -e "${gl_kjlan}后续更新: 再次运行选项1即可检查并安装最新内核${gl_bai}"

                rm -f "$xanmod_repo_file"
                echo -e "${gl_lv}已自动清理 XanMod 软件源（如需更新可再次运行选项1）${gl_bai}"
                return 0
            else
                echo ""
                echo -e "${gl_hong}❌ 内核更新失败${gl_bai}"
                break_end
                return 1
            fi
            ;;
        *)
            echo "已取消更新"
            break_end
            return 1
            ;;
    esac
}

uninstall_xanmod() {
    echo -e "${gl_huang}警告: 即将卸载 XanMod 内核${gl_bai}"
    echo ""

    # 安全检查：确认系统中有回退内核可用
    local non_xanmod_kernels=$(dpkg -l 2>/dev/null | grep '^ii' | grep 'linux-image-' | grep -v 'xanmod' | grep -v 'dbg' | wc -l)
    if [ "$non_xanmod_kernels" -eq 0 ]; then
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_hong}❌ 安全检查未通过：未检测到非 XanMod 的回退内核！${gl_bai}"
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "卸载 XanMod 内核后系统将没有可启动的内核，重启会导致 VPS 无法开机。"
        echo ""
        echo -e "${gl_lv}建议：先安装默认内核再卸载 XanMod${gl_bai}"
        echo "  apt install -y linux-image-amd64   # Debian"
        echo "  apt install -y linux-image-generic  # Ubuntu"
        echo ""
        break_end
        return 1
    fi
    echo -e "${gl_lv}✅ 检测到 ${non_xanmod_kernels} 个回退内核，可以安全卸载${gl_bai}"
    echo ""

    read -e -p "确定继续吗？(Y/N): " confirm

    case "$confirm" in
        [Yy])
            # 使用能匹配元包和内核包的模式
            echo "正在卸载 XanMod 相关包..."
            if apt purge -y 'linux-*xanmod*' 2>&1; then
                # 验证卸载结果
                if dpkg -l 2>/dev/null | grep -qE '^ii\s+linux-.*xanmod'; then
                    echo -e "${gl_hong}⚠️  部分 XanMod 包未能卸载，请手动检查：${gl_bai}"
                    dpkg -l | grep -E '^ii\s+linux-.*xanmod' | awk '{print "  - " $2}'
                else
                    echo -e "${gl_lv}✅ XanMod 内核包已全部卸载${gl_bai}"
                fi
                update-grub 2>/dev/null
            else
                echo -e "${gl_hong}❌ 卸载命令执行失败，请手动检查${gl_bai}"
                break_end
                return 1
            fi

            # 清理软件源和 GPG 密钥
            rm -f /etc/apt/sources.list.d/xanmod-release.list
            rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg
            echo -e "${gl_lv}✅ XanMod 软件源已清理${gl_bai}"

            rm -f "$SYSCTL_CONF"
            echo -e "${gl_lv}XanMod 内核已卸载${gl_bai}"
            server_reboot
            ;;
        *)
            echo "已取消"
            ;;
    esac
}



# 完全卸载脚本所有内容
uninstall_all() {
    echo -e "${gl_lv}开始卸载...${gl_bai}"
    echo ""
    
    local uninstall_count=0
    local xanmod_removed=0
    
    # 1. 卸载 XanMod 内核
    echo -e "${gl_huang}检查并卸载 XanMod 内核...${gl_bai}"
    if dpkg -l | grep -qE '^ii\s+linux-.*xanmod'; then
        # 安全检查：确认有回退内核
        local non_xanmod_kernels=$(dpkg -l 2>/dev/null | grep '^ii' | grep 'linux-image-' | grep -v 'xanmod' | grep -v 'dbg' | wc -l)
        if [ "$non_xanmod_kernels" -eq 0 ]; then
            echo -e "  ${gl_hong}❌ 未检测到回退内核，跳过卸载以防系统无法启动${gl_bai}"
            echo -e "  ${gl_huang}请先安装默认内核: apt install -y linux-image-amd64${gl_bai}"
        else
            echo "  正在卸载 XanMod 内核..."
            if apt purge -y 'linux-*xanmod*' > /dev/null 2>&1; then
                update-grub > /dev/null 2>&1
            else
                echo -e "  ${gl_hong}❌ XanMod 内核卸载命令执行失败，请手动检查${gl_bai}"
            fi
            if dpkg -l | grep -qE '^ii\s+linux-.*xanmod'; then
                echo -e "  ${gl_hong}❌ 仍检测到 XanMod 内核，请手动检查${gl_bai}"
            else
                echo -e "  ${gl_lv}✅ XanMod 内核已卸载${gl_bai}"
                uninstall_count=$((uninstall_count + 1))
                xanmod_removed=1
            fi
        fi
    else
        echo -e "  ${gl_huang}未检测到 XanMod 内核，跳过${gl_bai}"
    fi
    echo ""
    
    # 3. 清理 sysctl 配置文件
    echo -e "${gl_huang}清理 sysctl 配置文件...${gl_bai}"
    local sysctl_files=(
        "$SYSCTL_CONF"
        "/etc/sysctl.d/99-bbr-xanmod.conf"
        "/etc/sysctl.d/99-sysctl.conf"
        "/etc/sysctl.d/999-net-bbr-fq.conf"
    )
    
    local sysctl_cleaned=0
    for file in "${sysctl_files[@]}"; do
        if [ -f "$file" ]; then
            rm -f "$file"
            sysctl_cleaned=$((sysctl_cleaned + 1))
        fi
    done
    
    if [ $sysctl_cleaned -gt 0 ]; then
        echo -e "  ${gl_lv}✅ 已清理 $sysctl_cleaned 个配置文件${gl_bai}"
        uninstall_count=$((uninstall_count + 1))
    else
        echo -e "  ${gl_huang}未找到需要清理的配置文件${gl_bai}"
    fi
    echo ""
    
    # 4. 清理 XanMod 软件源
    echo -e "${gl_huang}清理 XanMod 软件源...${gl_bai}"
    local repo_files=(
        "/etc/apt/sources.list.d/xanmod-release.list"
        "/usr/share/keyrings/xanmod-archive-keyring.gpg"
    )
    
    local repo_cleaned=0
    for file in "${repo_files[@]}"; do
        if [ -f "$file" ]; then
            rm -f "$file"
            repo_cleaned=$((repo_cleaned + 1))
        fi
    done
    
    if [ $repo_cleaned -gt 0 ]; then
        echo -e "  ${gl_lv}✅ 已清理 XanMod 软件源${gl_bai}"
        uninstall_count=$((uninstall_count + 1))
    else
        echo -e "  ${gl_huang}未找到 XanMod 软件源${gl_bai}"
    fi
    echo ""
    
    # 5. 清理持久化服务和优化配置
    echo -e "${gl_huang}清理持久化服务和优化配置...${gl_bai}"
    local persist_cleaned=0

    if [ -f /usr/local/etc/mtu-optimize.conf ]; then
        . /usr/local/etc/mtu-optimize.conf 2>/dev/null
        # 恢复默认路由 MTU
        local def_rt
        def_rt=$(ip -4 route show default 2>/dev/null | head -1)
        if [ -n "$def_rt" ]; then
            local cl_rt
            cl_rt=$(echo "$def_rt" | sed 's/ mtu lock [0-9]*//;s/ mtu [0-9]*//')
            ip route replace $cl_rt 2>/dev/null || true
        fi
        # 恢复链路 MTU
        if [ -n "${DEFAULT_IFACE:-}" ] && [ -n "${ORIGINAL_MTU:-}" ]; then
            ip link set dev "$DEFAULT_IFACE" mtu "$ORIGINAL_MTU" 2>/dev/null || true
        fi
        rm -f /usr/local/etc/mtu-optimize.conf
        persist_cleaned=$((persist_cleaned + 1))
        echo -e "  ${gl_lv}✓ MTU优化已恢复${gl_bai}"
    fi
    if [ -f /etc/systemd/system/mtu-optimize-persist.service ]; then
        systemctl disable mtu-optimize-persist.service 2>/dev/null || true
        rm -f /etc/systemd/system/mtu-optimize-persist.service
        rm -f /usr/local/bin/mtu-optimize-apply.sh
        persist_cleaned=$((persist_cleaned + 1))
    fi

    # 功能3: BBR优化持久化
    if [ -f /etc/systemd/system/bbr-optimize-persist.service ]; then
        systemctl disable bbr-optimize-persist.service 2>/dev/null || true
        rm -f /etc/systemd/system/bbr-optimize-persist.service
        rm -f /usr/local/bin/bbr-optimize-apply.sh
        persist_cleaned=$((persist_cleaned + 1))
        echo -e "  ${gl_lv}✓ BBR持久化服务已移除${gl_bai}"
    fi

    # 清理旧版 iptables set-mss 规则
    if command -v iptables &>/dev/null; then
        local tag="bbr-xanmod-mss" del_v
        while read -r del_v; do
            [ -n "$del_v" ] || continue
            iptables -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$del_v" -m comment --comment "$tag" 2>/dev/null || true
        done < <(iptables -t mangle -S OUTPUT 2>/dev/null | grep "$tag" | sed -n 's/.*--set-mss \([0-9]\+\).*/\1/p')
        while read -r del_v; do
            [ -n "$del_v" ] || continue
            iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$del_v" -m comment --comment "$tag" 2>/dev/null || true
        done < <(iptables -t mangle -S POSTROUTING 2>/dev/null | grep "$tag" | sed -n 's/.*--set-mss \([0-9]\+\).*/\1/p')
    fi

    if [ $persist_cleaned -gt 0 ]; then
        systemctl daemon-reload 2>/dev/null || true
        echo -e "  ${gl_lv}✅ 已清理持久化服务${gl_bai}"
        uninstall_count=$((uninstall_count + 1))
    else
        echo -e "  ${gl_huang}未找到持久化服务${gl_bai}"
    fi
    echo ""

    
    local temp_cleaned=0
    for pattern in "${temp_files[@]}"; do
        if ls $pattern > /dev/null 2>&1; then
            rm -rf $pattern 2>/dev/null
            temp_cleaned=$((temp_cleaned + 1))
        fi
    done
    
    if [ $temp_cleaned -gt 0 ]; then
        echo -e "  ${gl_lv}✅ 已清理临时文件${gl_bai}"
    else
        echo -e "  ${gl_huang}未找到临时文件${gl_bai}"
    fi
    echo ""
    
    # 7. 应用 sysctl 更改
    echo -e "${gl_huang}应用系统配置更改...${gl_bai}"
    sysctl --system > /dev/null 2>&1
    echo -e "  ${gl_lv}✅ 系统配置已重置${gl_bai}"
    echo -e "  ${gl_lv}✅ 重启系统后生效${gl_bai}"
    echo ""
    reboot
}



main() {
    

    # 加载用户配置（如果存在）
    [ -f "/etc/bbr-xanmod.conf" ] && source "/etc/bbr-xanmod.conf"
    [ -f "$HOME/.bbr-xanmod.conf" ] && source "$HOME/.bbr-xanmod.conf"

    # 交互式菜单
    while true; do
        show_main_menu
    done
}

# 执行主函数
main "$@"
