#!/usr/bin/env bash

# ==============================================================================
# Linux TCP/IP & BBR & TFO 智能优化脚本
#
# ==============================================================================

SCRIPT_VERSION="3.1.3"

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

# --- 获取系统信息与动态参数 ---
get_system_info() {
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}' | tr -d '\r')
    
    if [ "$TOTAL_MEM" -le 512 ]; then
        VM_TIER="入门级(≤512MB)"
        RMEM_MAX="16777216"   
        WMEM_MAX="16777216"
        TCP_MEM_MAX="16777216"
        SOMAXCONN="4096"
        FILE_MAX="65535"
        CONNTRACK_MAX="65536"
    elif [ "$TOTAL_MEM" -le 1024 ]; then
        VM_TIER="基础级(1GB)"
        RMEM_MAX="33554432"   
        WMEM_MAX="33554432"
        TCP_MEM_MAX="33554432"
        SOMAXCONN="16384"
        FILE_MAX="524288"
        CONNTRACK_MAX="262144"
    elif [ "$TOTAL_MEM" -le 4096 ]; then
        VM_TIER="进阶级(2GB-4GB)"
        RMEM_MAX="67108864"   
        WMEM_MAX="67108864"
        TCP_MEM_MAX="67108864"
        SOMAXCONN="32768"
        FILE_MAX="1048576"
        CONNTRACK_MAX="524288"
    else
        VM_TIER="专业级(>4GB)"
        RMEM_MAX="134217728"  
        WMEM_MAX="134217728"
        TCP_MEM_MAX="134217728"
        SOMAXCONN="65535"
        FILE_MAX="2097152"
        CONNTRACK_MAX="1048576"
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
        ls -t "$CONF_FILE.bak_"* 2>/dev/null | tail -n +4 | xargs -r rm -f
    fi
}

# --- 看板状态获取 ---
get_status_text() {
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    
    if [ "$cc" == "bbr" ]; then
        BBR_STATUS="${YELLOW}已启用 (${qdisc})${NC}"
    else
        BBR_STATUS="${RED}未启用 (${cc})${NC}"
    fi

    if [ -f "$CONF_FILE" ]; then
        CONF_STATUS="${YELLOW}已应用方案${NC}"
    else
        CONF_STATUS="${RED}未应用方案${NC}"
    fi
}

# --- 功能 1：一键安装优化 ---
apply_optimizations() {
    echo -e "\n${CYAN}>>> 正在分析系统硬件并生成最佳配置方案...${NC}"
    get_system_info
    manage_backups
    
    modprobe nf_conntrack >/dev/null 2>&1 || true
    modprobe tcp_bbr >/dev/null 2>&1 || true

    > "$CONF_FILE"
    cat >> "$CONF_FILE" << EOF
# ==========================================================
# Linux Network Tuning (Proxy/Forwarding Optimized)
# 生成时间: $(date)
# 硬件适配: ${TOTAL_MEM}MB RAM (${VM_TIER})
# ==========================================================
EOF

    # 1. BBR 与 队列算法 (更改为默认固定 fq)
    add_conf "net.core.default_qdisc" "fq" "FQ 队列算法 (BBR 官方推荐最佳拍档)"
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
    add_conf "net.ipv4.udp_mem" "262144 524288 1048576" "系统 UDP 内存页限制"

    # 4. 连接与队列上限
    add_conf "net.core.somaxconn" "$SOMAXCONN" "最大监听队列"
    add_conf "net.core.netdev_max_backlog" "$SOMAXCONN" "网卡积压队列"
    add_conf "net.ipv4.tcp_max_syn_backlog" "$SOMAXCONN" "SYN 半连接队列"
    add_conf "net.ipv4.tcp_notsent_lowat" "16384" "降低缓冲区未发送数据阈值"

    # 5. TIME_WAIT 与 端口复用
    add_conf "net.ipv4.tcp_tw_reuse" "1" "开启 TIME_WAIT 复用"
    add_conf "net.ipv4.tcp_timestamps" "1" "开启时间戳"
    add_conf "net.ipv4.tcp_fin_timeout" "20" "缩短 FIN_WAIT 时间"
    add_conf "net.ipv4.ip_local_port_range" "1024 65535" "扩大本地端口范围"
    add_conf "net.ipv4.tcp_max_tw_buckets" "500000" "允许更多 TIME_WAIT socket"

    # 6. TCP Keepalive
    add_conf "net.ipv4.tcp_keepalive_time" "300" "TCP 保活时间"
    add_conf "net.ipv4.tcp_keepalive_intvl" "15" "探测间隔"
    add_conf "net.ipv4.tcp_keepalive_probes" "3" "探测次数"

    # 7. 连接跟踪 (Conntrack)
    if lsmod | grep -q "nf_conntrack"; then
        add_conf "net.netfilter.nf_conntrack_max" "$CONNTRACK_MAX" "最大连接跟踪数"
        add_conf "net.netfilter.nf_conntrack_tcp_timeout_established" "3600" "连接跟踪超时"
        add_conf "net.netfilter.nf_conntrack_tcp_timeout_time_wait" "60" "减少 TIME_WAIT 跟踪时间"
    fi

    # 8. 其他安全与链路调优
    add_conf "fs.file-max" "$FILE_MAX" "最大文件句柄"
    add_conf "vm.swappiness" "10" "减少 Swap 使用"
    add_conf "net.ipv4.tcp_mtu_probing" "1" "开启 MTU 探测"
    add_conf "net.ipv4.tcp_syncookies" "1" "防 SYN Flood"
    add_conf "net.ipv4.tcp_ecn" "1" "开启 ECN"

    echo -e "${CYAN}>>> 正在将参数注入内核控制流...${NC}"
    sysctl --system >/dev/null 2>&1 || true
    if [ -f "$CONF_FILE" ]; then
        sysctl -p "$CONF_FILE" >/dev/null 2>&1 || true
    fi

    echo -e "${GREEN}✅ 高级网络优化配置应用成功！(默认 FQ 队列算法与 TCP Fast Open 已生效)${NC}"
}

# --- 功能 2：卸载优化恢复默认 ---
uninstall_optimizations() {
    echo -e "\n${YELLOW}>>> 正在准备卸载优化配置...${NC}"
    if [ -f "$CONF_FILE" ]; then
        rm -f "$CONF_FILE"
        echo -e "${GREEN}✅ 已删除优化配置文件: ${CONF_FILE}${NC}"
        echo -e "${CYAN}>>> 重新校准并加载系统默认网络参数...${NC}"
        sysctl --system >/dev/null 2>&1 || true
        echo -e "${GREEN}✅ 卸载完成，系统控制流已恢复至全局默认状态。${NC}"
    else
        echo -e "${YELLOW}💡 提示: 未检测到由本脚本生成的配置文件，无需卸载。${NC}"
    fi
}

# --- 交互菜单 ---
menu() {
    while true; do
        get_status_text
        
        echo -e "${GREEN}======================================================${NC}"
        echo -e "${GREEN}     BBR+TCP智能调参     ${NC}"
        echo -e "${GREEN}======================================================${NC}"
        echo -e "${GREEN}  🚀 BBR状态看板 : ${BBR_STATUS}"
        echo -e "${GREEN}  📂     配置状态 : ${CONF_STATUS}"
        echo -e "${GREEN}------------------------------------------------------${NC}"
        echo -e "${GREEN}  1. 一键网络优化${NC}"
        echo -e "${GREEN}  2. 还原卸载优化${NC}"
        echo -e "${GREEN}  3. 退出${NC}"
        echo -e "${GREEN}======================================================${NC}"
        
        echo -ne "${GREEN}请输入选项: ${NC}"
        read -r choice
        
        case "$choice" in
            1)
                apply_optimizations
                ;;
            2)
                uninstall_optimizations
                ;;
            3)
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ 输入错误，请输入数字 1-3。${NC}"
                ;;
        esac
    done
}

# --- 主入口 ---
main() {
    check_root
    menu
}

main "$@"
