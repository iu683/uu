#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 获取操作系统 ID
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS="unknown"
fi

# --------------------------
# Alpine 开启 BBR 逻辑
# --------------------------
enable_bbr_alpine() {
    echo -e "${YELLOW}检测到系统为 Alpine Linux，正在尝试开启 BBR+FQ...${RESET}"

    # 1. 加载内核模块
    modprobe tcp_bbr
    echo "tcp_bbr" >> /etc/modules

    # 2. 写入 sysctl 配置
    cat > /etc/sysctl.d/bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    # 3. 立即生效
    sysctl -p /etc/sysctl.d/bbr.conf

    # 4. 验证
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}✅ Alpine BBR 已成功开启！${RESET}"
    else
        echo -e "${RED}❌ BBR 开启失败，请检查内核版本是否支持。${RESET}"
    fi
}

# --------------------------
# 主逻辑分流
# --------------------------
case "$OS" in
    alpine)
        enable_bbr_alpine
        ;;
    debian|ubuntu|centos|rocky|almalinux|fedora)
        echo -e "${GREEN}检测到系统为 $OS，正在打开标准 BBR 配置脚本...${RESET}"
        # 调用你提供的原 BBR 脚本
        bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/BBRTCP.sh)
        ;;
    *)
        echo -e "${RED}❌ 未能识别系统类型 ($OS)，尝试运行通用脚本...${RESET}"
        bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/BBRTCP.sh)
        ;;
esac
