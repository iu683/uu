#!/bin/bash
# ============================================================
# 通用 SSH 端口修改脚本 (支持 Alpine/Debian/Ubuntu/CentOS)
# ============================================================
set -e

# 颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

# 1. Root 检查
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 用户运行${RESET}"
    exit 1
fi

# 2. 系统识别
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
else
    OS_ID="unknown"
fi

# 3. 基础工具自动化安装 (Alpine/Debian/RHEL)
install_deps() {
    echo -e "${CYAN}🔍 正在检查必要组件...${RESET}"
    case "$OS_ID" in
        alpine)
            apk update
            # Alpine 需要安装 busybox-extras 以获得更强的 netstat，安装 nc 供探测使用
            apk add --no-cache curl bash openssh-server busybox-extras netcat-openbsd 2>/dev/null
            ;;
        debian|ubuntu)
            apt-get update -y
            apt-get install -y curl netcat-openbsd procps 2>/dev/null
            ;;
        centos|rhel|rocky|almalinux)
            yum install -y curl nc 2>/dev/null
            ;;
    esac
}
install_deps

# 4. 获取当前 SSH 端口
current_port=$(grep -E '^ *Port [0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
current_port=${current_port:-22}
echo -e "${CYAN}当前 SSH 端口: ${YELLOW}$current_port${RESET}"

# 5. 输入并验证新端口
echo -e "----------------------------------"
read -p "$(echo -e ${CYAN}请输入新的 SSH 端口号: ${RESET})" new_port
if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -le 0 ] || [ "$new_port" -gt 65535 ]; then
    echo -e "${RED}❌ 错误: 请输入 1-65535 的合法端口号${RESET}"
    exit 1
fi

# 6. 备份并修改配置
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
if grep -q "^Port " /etc/ssh/sshd_config; then
    sed -i "s/^Port .*/Port $new_port/" /etc/ssh/sshd_config
else
    echo "Port $new_port" >> /etc/ssh/sshd_config
fi

# 7. 停用 systemd ssh.socket (如果存在)
if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q ssh.socket; then
        systemctl stop ssh.socket 2>/dev/null || true
        systemctl disable ssh.socket 2>/dev/null || true
    fi
fi

# 8. 防火墙安全放行 (兼容 ufw/firewalld/iptables/nftables)
echo -e "${CYAN}🛡️ 正在尝试放行新端口 $new_port...${RESET}"
if command -v ufw >/dev/null 2>&1; then
    ufw allow $new_port/tcp || true
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=$new_port/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
elif command -v nft >/dev/null 2>&1; then
    nft add rule inet filter input tcp dport $new_port accept 2>/dev/null || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport $new_port -j ACCEPT || true
fi

# 9. 重启 SSH 服务 (兼容 OpenRC 和 Systemd)
echo -e "${CYAN}🔄 正在重启 SSH 服务...${RESET}"
if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-units --full --all | grep -q "sshd.service"; then
        systemctl restart sshd.service
    else
        systemctl restart ssh.service
    fi
elif command -v rc-service >/dev/null 2>&1; then
    # Alpine OpenRC 路径
    rc-service sshd restart
else
    service sshd restart || /etc/init.d/sshd restart
fi

# 10. 本地监听与远程可达性双重检测
echo -e "${CYAN}📡 正在检测端口 $new_port 是否就绪...${RESET}"
sleep 2

# 本地检测
if netstat -tnlp | grep -q ":$new_port "; then
    echo -e "${GREEN}✔ 本地端口监听成功${RESET}"
else
    echo -e "${RED}❌ 端口 $new_port 未能在本地开启，请检查 sshd_config${RESET}"
    exit 1
fi

# 远程检测 (使用 Cloudflare trace 获取 IP)
VPS_IP=$(curl -s --max-time 5 https://1.1.1.1/cdn-cgi/trace | grep ip | cut -d= -f2)
[ -z "$VPS_IP" ] && VPS_IP=$(curl -s --max-time 5 ipinfo.io/ip)

if [ -n "$VPS_IP" ]; then
    echo -e "${CYAN}正在从远程探测 $VPS_IP:$new_port ...${RESET}"
    # 使用 nc 检测
    if nc -zv -w 5 "$VPS_IP" "$new_port" 2>/dev/null; then
        echo -e "${GREEN}✔ 远程端口检测通过！${RESET}"
        
        # 只有在远程确认可达后，才建议手动关闭旧端口防火墙（此处不再自动强制删除，以防万一）
        echo -e "${YELLOW}提示: 新端口已通，建议手动清理旧端口 $current_port 的防火墙规则${RESET}"
    else
        echo -e "${RED}⚠ 远程检测失败！可能是服务商云控制台防火墙未放行。${RESET}"
        echo -e "${YELLOW}警告: 请勿关闭当前窗口，尝试再开一个 SSH 窗口确认是否能连上新端口！${RESET}"
    fi
fi

echo -e "----------------------------------"
echo -e "${GREEN}✅ SSH 端口安全切换完成: $current_port -> $new_port${RESET}"
