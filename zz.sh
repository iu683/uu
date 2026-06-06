#!/usr/bin/env bash

# ==============================================================================
# Linux TCP/IP & BBR & TFO 智能综合优化
# ==============================================================================

set -euo pipefail

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 配置文件路径 ---
CONF_FILE="/etc/sysctl.d/99-bbr.conf"

# --- 权限检查 ---
check_root() {
    if [[ $(id -u) -ne 0 ]]; then
        echo -e "${RED}❌ 错误: 必须以 root 权限运行此脚本。${NC}"
        exit 1
    fi
}

# --- BBR 与 架构兼容性硬检测 ---
check_bbr_support() {
    
    # 1. 检测容器虚拟化架构 (OpenVZ / LXC / 容器判定)
    local virt_type="unknown"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt_type=$(systemd-detect-virt)
    else
        # 针对 Alpine 等无 systemd 系统或特殊环境的兜底检测
        if [ -f /proc/user_beancounters ]; then
            virt_type="openvz"
        elif grep -qi "lxc" /proc/1/environ 2>/dev/null || [ -f /run/container_type ]; then
            virt_type="lxc"
        fi
    fi

    if [[ "$virt_type" == "openvz" || "$virt_type" == "lxc" ]]; then
        echo -e "${RED}❌ 错误: 当前 VPS 架构为 [${virt_type^^}] 容器/NAT小鸡。${NC}"
        echo -e "${YELLOW}💡 原因: 该架构与宿主机共享内核，非独立内核，无法自主应用 BBR 拥塞控制与 FQ 队列。${NC}"
        exit 1
    fi

    # 2. 内核版本前置过滤
    local kernel_version major minor
    kernel_version=$(uname -r | cut -d. -f1,2)
    major=$(echo "$kernel_version" | cut -d. -f1)
    minor=$(echo "$kernel_version" | cut -d. -f2)
    
    local has_bbr_mod=0
    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q "bbr"; then
        has_bbr_mod=1
    elif modprobe -n tcp_bbr >/dev/null 2>&1; then
        has_bbr_mod=1
    fi

    # 允许在 4.9 以下但有反向 backport BBR 模块的特殊内核通过
    if [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 9 ]; }; then
        if [ "$has_bbr_mod" -ne 1 ]; then
            echo -e "${RED}❌ 错误: 当前系统内核版本为 $(uname -r)，低于官方要求的 4.9 最低限制，且无可用 BBR 模块。${NC}"
            exit 1
        fi
    fi

    # 3. 核心参数修改权限沙箱预检 (终极防线)
    if ! sysctl -w net.ipv4.tcp_congestion_control="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'cubic')" >/dev/null 2>&1; then
        echo -e "${RED}❌ 错误: 检测到系统内核网络参数文件为 [只读] 状态或无修改权限。${NC}"
        echo -e "${YELLOW}💡 原因: 这通常发生在某些受限的环境（如部分 NAT 共享小鸡或特殊安全策略容器中）。${NC}"
        exit 1
    fi
}

# --- 获取系统信息与动态参数 (针对小内存 UDP 深度调优) ---
get_system_info() {
    # 兼容没有 free 命令的精简系统（如未装 full box 的 Alpine）
    if command -v free >/dev/null 2>&1; then
        TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}' | tr -d '\r')
    else
        TOTAL_MEM=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    fi
    
    if [ -z "$TOTAL_MEM" ] || [ "$TOTAL_MEM" -le 0 ]; then
        TOTAL_MEM=1024 # 无法获取时默认按 1G 计算安全值
    fi

    if [ "$TOTAL_MEM" -le 512 ]; then
        VM_TIER="入门微型小鸡(≤512MB RAM)"
        RMEM_MAX="16777216"   
        WMEM_MAX="16777216"
        TCP_MEM_MAX="16777216"
        SOMAXCONN="2048"       
        FILE_MAX="65535"
        CONNTRACK_MAX="32768"
        UDP_MEM_CONF="1152 1536 2304"
    elif [ "$TOTAL_MEM" -le 1024 ]; then
        VM_TIER="基础级(1GB)"
        RMEM_MAX="33554432"   
        WMEM_MAX="33554432"
        TCP_MEM_MAX="33554432"
        SOMAXCONN="16384"
        FILE_MAX="524288"
        CONNTRACK_MAX="262144"
        UDP_MEM_CONF="16384 32768 65536"
    elif [ "$TOTAL_MEM" -le 4096 ]; then
        VM_TIER="进阶级(2GB-4GB)"
        RMEM_MAX="67108864"   
        WMEM_MAX="67108864"
        TCP_MEM_MAX="67108864"
        SOMAXCONN="32768"
        FILE_MAX="1048576"
        CONNTRACK_MAX="524288"
        UDP_MEM_CONF="65536 131072 262144"
    else
        VM_TIER="专业级(>4GB)"
        RMEM_MAX="134217728"  
        WMEM_MAX="134217728"
        TCP_MEM_MAX="134217728"
        SOMAXCONN="65535"
        FILE_MAX="2097152"
        CONNTRACK_MAX="1048576"
        UDP_MEM_CONF="262144 524288 1048576"
    fi
}

# --- 写入配置辅助 ---
add_conf() {
    local key="$1"
    local value="$2"
    local comment="$3"
    echo "# $comment" >> "$CONF_FILE"
    echo "$key = $value" >> "$CONF_FILE"
    echo "" >> "$CONF_FILE"
}

# --- 备份管理 ---
manage_backups() {
    if [ -f "$CONF_FILE" ]; then
        cp "$CONF_FILE" "$CONF_FILE.bak_$(date +%F_%H-%M-%S)"
        # 仅保留最近3次备份
        ls -t "${CONF_FILE}.bak_"* 2>/dev/null | tail -n +4 | xargs -r rm -f 2>/dev/null || true
    fi
}

# --- 看板状态获取 ---
get_status_text() {
    local cc fq_check bbr_status fq_status
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | tr -d '[:space:]' || echo "未知")
    fq_check=$(sysctl -n net.core.default_qdisc 2>/dev/null | tr -d '[:space:]' || echo "未知")

    # 1. 验证 BBR 状态及版本
    if [ "$cc" == "bbr" ]; then
        BBR_STATUS="${YELLOW}已启用${NC}"
    else
        BBR_STATUS="${RED}未启用${NC}"
    fi
    # 2. 验证 FQ 状态
    if [ "$fq_check" == "fq" ] || [ "$fq_check" == "fq_pie" ] || [ "$fq_check" == "fq_codel" ]; then
        FQ_STATUS="${YELLOW}已启用${NC}"
    else
        FQ_STATUS="${RED}未启用${NC}"
    fi

    # 2. 验证配置文件是否【真正由本脚本应用】
    # 判断文件存在，且内容里包含专属的头部备注
    if [ -f "$CONF_FILE" ] && grep -q "Linux Network Tuning (Proxy/Forwarding Optimized)" "$CONF_FILE"; then
        CONF_STATUS="${YELLOW}已应用${NC}"
    elif [ -f "$CONF_FILE" ]; then
        CONF_STATUS="${RED}未应用${NC}"
    else
        CONF_STATUS="${RED}未应用${NC}"
    fi
}

# --- 检测并处理 Alpine 发行版特殊逻辑 ---
handle_alpine_special() {
    if [ -f /etc/os-release ]; then
        # 通过 source 引入系统变量
        # shellcheck disable=SC1091
        . /etc/os-release
        if [ "${ID:-}" = "alpine" ]; then
            echo -e "${CYAN}ℹ️ 检测到当前系统为 Alpine Linux，注入模块持久化配置...${NC}"
            if ! grep -q "tcp_bbr" /etc/modules 2>/dev/null; then
                echo "tcp_bbr" >> /etc/modules 2>/dev/null || true
            fi
        fi
    fi
}

# --- 功能 1：一键安装优化 ---
apply_optimizations() {
    echo -e "\n${CYAN}>>> 正在分析系统硬件并生成最佳配置方案...${NC}"
    get_system_info
    manage_backups
    
    # 尝试加载内核模块（静默处理）
    modprobe nf_conntrack >/dev/null 2>&1 || true
    modprobe tcp_bbr >/dev/null 2>&1 || true

    mkdir -p "$(dirname "$CONF_FILE")"
    > "$CONF_FILE"
    cat >> "$CONF_FILE" << EOF
# ==========================================================
# Linux Network Tuning (Proxy/Forwarding Optimized)
# 生成时间: $(date)
# 硬件适配: ${TOTAL_MEM}MB RAM (${VM_TIER})
# ==========================================================
EOF

    # 1. BBR 与 队列算法
    add_conf "net.core.default_qdisc" "fq" "FQ 队列算法"
    add_conf "net.ipv4.tcp_congestion_control" "bbr" "开启 BBR 拥塞控制"
    add_conf "net.ipv4.tcp_slow_start_after_idle" "0" "关闭空闲慢启动"

    # 2. TCP Fast Open (双向开启)
    add_conf "net.ipv4.tcp_fastopen" "3" "开启 TCP Fast Open"

    # 3. 缓冲区优化
    add_conf "net.core.rmem_max" "$RMEM_MAX" "系统最大接收缓存"
    add_conf "net.core.wmem_max" "$WMEM_MAX" "系统最大发送缓存"
    add_conf "net.core.rmem_default" "262144" "默认接收缓存" 
    add_conf "net.core.wmem_default" "262144" "默认发送缓存"
    add_conf "net.ipv4.tcp_rmem" "4096 87380 $TCP_MEM_MAX" "TCP 读缓存"
    add_conf "net.ipv4.tcp_wmem" "4096 65536 $TCP_MEM_MAX" "TCP 写缓存"
    add_conf "net.ipv4.udp_rmem_min" "16384" "UDP 读缓存下限"
    add_conf "net.ipv4.udp_wmem_min" "16384" "UDP 写缓存下限"
    add_conf "net.ipv4.udp_mem" "$UDP_MEM_CONF" "系统 UDP 内存页全局限制"

    # 4. 连接与队列上限
    add_conf "net.core.somaxconn" "$SOMAXCONN" "最大监听队列"
    add_conf "net.core.netdev_max_backlog" "$SOMAXCONN" "网卡积压队列"
    add_conf "net.ipv4.tcp_max_syn_backlog" "$SOMAXCONN" "SYN 半连接队列"
    add_conf "net.ipv4.tcp_notsent_lowat" "16384" "降低缓冲区未发送数据阈值"

    # 5. TIME_WAIT 与 端口复用
    add_conf "net.ipv4.tcp_tw_reuse" "1" "开启 TIME_WAIT 复用"
    add_conf "net.ipv4.tcp_timestamps" "1" "开启时间戳"
    add_conf "net.ipv4.tcp_fin_timeout" "30" "缩短 FIN_WAIT 时间"
    add_conf "net.ipv4.ip_local_port_range" "10000 65535" "扩大本地端口范围"
    add_conf "net.ipv4.tcp_max_tw_buckets" "500000" "允许更多 TIME_WAIT socket"

    # 6. TCP Keepalive
    add_conf "net.ipv4.tcp_keepalive_time" "600" "TCP 保活时间"
    add_conf "net.ipv4.tcp_keepalive_intvl" "15" "探测间隔"
    add_conf "net.ipv4.tcp_keepalive_probes" "3" "探测次数"

    # 7. 连接跟踪 (Conntrack)
    if lsmod | grep -q "nf_conntrack" || [ -d /proc/sys/net/netfilter ]; then
        add_conf "net.netfilter.nf_conntrack_max" "$CONNTRACK_MAX" "最大连接跟踪数"
        add_conf "net.netfilter.nf_conntrack_tcp_timeout_established" "7200" "连接跟踪超时"
        add_conf "net.netfilter.nf_conntrack_tcp_timeout_time_wait" "120" "减少 TIME_WAIT 跟踪时间"
    fi

    # 8. 其他安全与链路调优
    add_conf "fs.file-max" "$FILE_MAX" "最大文件句柄"
    add_conf "vm.swappiness" "10" "减少 Swap 使用"
    add_conf "net.ipv4.tcp_mtu_probing" "1" "开启 MTU 探测"
    add_conf "net.ipv4.tcp_syncookies" "1" "防 SYN Flood"
    add_conf "net.ipv4.tcp_ecn" "1" "开启 ECN"

    echo -e "${CYAN}>>> 正在将参数注入内核控制流...${NC}"
    
    # 针对不同发行版采用兼容的 sysctl 生效命令
    sysctl --system >/dev/null 2>&1 || sysctl -p "$CONF_FILE" >/dev/null 2>&1 || true

    # 针对 Alpine Linux 的持久化补充
    handle_alpine_special

    # 最终复核
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}✅ 高级网络优化配置应用成功！BBR 已成功加速。${NC}\n"
    else
        echo -e "${RED}❌ 警告: 配置已写入，但检测到内核当前仍未成功切换至 BBR。${NC}"
        echo -e "${YELLOW}💡 提示: 如果是 Alpine，可能由于缺少内核模块包。可尝试运行 'apk add linux-lts' 升级或重启。${NC}\n"
    fi
    
    echo -ne "${GREEN}"
    read -r -p "按回车键返回主菜单..." _
    echo -ne "${NC}"
}

# --- 功能 2：卸载优化恢复默认 ---
uninstall_optimizations() {
    echo -e "\n${YELLOW}>>> 正在准备卸载优化配置...${NC}"
    if [ -f "$CONF_FILE" ]; then
        rm -f "$CONF_FILE"
        echo -e "${GREEN}✅ 已删除优化配置文件: ${CONF_FILE}${NC}"
        echo -e "${CYAN}>>> 重新校准并加载系统默认网络参数...${NC}"
        sysctl --system >/dev/null 2>&1 || true
        echo -e "${GREEN}✅ 卸载完成，系统控制流已恢复至全局默认状态。${NC}\n"
    else
        echo -e "${YELLOW}💡 提示: 未检测到生成的配置文件，无需卸载。${NC}\n"
    fi
    
    echo -ne "${GREEN}"
    read -r -p "按回车键返回主菜单..." _
    echo -ne "${NC}"
}

# --- 交互菜单 ---
menu() {
    while true; do
        clear
        get_status_text
        
        echo -e "${GREEN}====================================${NC}"
        echo -e "${GREEN}      BBR+TCP智能调参综合优化        ${NC}"
        echo -e "${GREEN}====================================${NC}"
        echo -e "${GREEN}  BBR  : ${BBR_STATUS}"
        echo -e "${GREEN}  FQ   : ${FQ_STATUS}"
        echo -e "${GREEN}  配置 : ${CONF_STATUS}"
        echo -e "${GREEN}====================================${NC}"
        echo -e "${GREEN}  1. 网络优化${NC}"
        echo -e "${GREEN}  2. 卸载优化${NC}"
        echo -e "${GREEN}  0. 退出${NC}"
        echo -e "${GREEN}====================================${NC}"
        
        echo -ne "${GREEN} 请输入选项: ${NC}"
        read -r choice
        
        case "$choice" in
            1)
                apply_optimizations
                ;;
            2)
                uninstall_optimizations
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}❌ 输入错误${NC}"
                sleep 1
                ;;
        esac
    done
}

# --- 主入口 ---
main() {
    check_root
    check_bbr_support
    menu
}

main "$@"
