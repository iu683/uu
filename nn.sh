#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# --------------------------
# 架构检测函数
# --------------------------
check_virt() {
    echo -e "${YELLOW}正在检测服务器虚拟化架构...${RESET}"
    
    # 尝试使用 systemd-detect-virt (如果系统支持)
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT=$(systemd-detect-virt)
    else
        # 针对 Alpine 等无 systemd 系统，通过常见特征检测
        if [ -f /proc/user_beancounters ]; then
            VIRT="openvz"
        elif grep -q "lxc" /proc/1/environ 2>/dev/null || [ -f /run/container_type ]; then
            VIRT="lxc"
        else
            VIRT="kvm_or_other"
        fi
    fi

    echo -e "虚拟化架构: ${GREEN}$VIRT${RESET}"

    if [ "$VIRT" == "lxc" ] || [ "$VIRT" == "openvz" ]; then
        echo -e "${RED}❌ 警告: 您的系统处于 $VIRT 容器环境下。${RESET}"
        echo -e "${RED}容器环境无法自主修改内核模块，请联系宿主机提供商在母鸡开启 BBR。${RESET}"
        exit 1
    fi
}

# --------------------------
# Alpine 开启 BBR 逻辑
# --------------------------
enable_bbr_alpine() {
    echo -e "${YELLOW}检测到系统为 Alpine Linux，正在尝试配置...${RESET}"
    
    # 尝试加载模块（静默处理，防止报错）
    modprobe tcp_bbr 2>/dev/null || true
    
    mkdir -p /etc/sysctl.d/
    cat > /etc/sysctl.d/bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    # 尝试使其生效
    sysctl -p /etc/sysctl.d/bbr.conf 2>/dev/null || true

    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "tcp_bbr" >> /etc/modules 2>/dev/null || true
        echo -e "${GREEN}✅ Alpine BBR 已成功开启！${RESET}"
    else
        echo -e "${RED}❌ BBR 开启失败。可能原因：内核版本过低或缺少内核模块包。${RESET}"
        echo -e "${YELLOW}提示: 尝试运行 'apk add linux-lts' 升级内核后重启再试。${RESET}"
    fi
}

# --------------------------
# 主逻辑
# --------------------------

# 1. 先查架构
check_virt

# 2. 再查发行版
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS="unknown"
fi

case "$OS" in
    alpine)
        enable_bbr_alpine
        ;;
    debian|ubuntu|centos|rocky|almalinux|fedora)
        echo -e "${GREEN}检测到系统为 $OS (KVM/独立内核)，调用标准 BBR 脚本...${RESET}"
        bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/BBRTCP.sh)
        ;;
    *)
        echo -e "${YELLOW}未能精准识别系统，尝试运行通用脚本...${RESET}"
        bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/BBRTCP.sh)
        ;;
esac
