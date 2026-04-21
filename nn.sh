#!/bin/bash
set -e

# =========================
# 通用 Linux SSH 端口修改脚本
# 适配: Debian / Ubuntu / RHEL / Alpine
# =========================

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户运行该脚本"
    exit 1
fi

# -------------------------
# 系统类型识别
# -------------------------
if [ -f /etc/alpine-release ]; then
    OS_TYPE="alpine"
elif [ -f /etc/debian_version ]; then
    OS_TYPE="debian"
elif [ -f /etc/redhat-release ]; then
    OS_TYPE="rhel"
else
    OS_TYPE="other"
fi

# -------------------------
# 当前 SSH 端口
# -------------------------
current_port=$(grep -E '^ *Port [0-9]+' /etc/ssh/sshd_config | awk '{print $2}')
current_port=${current_port:-22}
echo -e "\033[1;36m当前 SSH 端口: $current_port  (系统类型: $OS_TYPE)\033[0m"
echo "------------------------"

# -------------------------
# 输入新端口
# -------------------------
read -p $'\033[1;35m请输入新的 SSH 端口号: \033[0m' new_port

if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -le 0 ] || [ "$new_port" -gt 65535 ]; then
    echo -e "\033[1;31m错误: 请输入 1-65535 的端口号\033[0m"
    exit 1
fi

# -------------------------
# 备份 SSH 配置
# -------------------------
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%F_%T)

# -------------------------
# 修改 SSH 配置
# -------------------------
if grep -q "^Port " /etc/ssh/sshd_config; then
    sed -i "s/^Port .*/Port $new_port/" /etc/ssh/sshd_config
else
    echo "Port $new_port" >> /etc/ssh/sshd_config
fi

# -------------------------
# 停用 systemd socket (仅限 systemd 系统)
# -------------------------
if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q ssh.socket; then
        systemctl stop ssh.socket >/dev/null 2>&1 || true
        systemctl disable ssh.socket >/dev/null 2>&1 || true
    fi
fi

# -------------------------
# 确保工具已安装 (nc/netcat)
# -------------------------
if ! command -v nc >/dev/null 2>&1; then
    echo "安装 nc (netcat)..."
    case "$OS_TYPE" in
        "alpine") apk add --no-cache netcat-openbsd ;;
        "debian") apt update -y && apt install -y netcat-openbsd ;;
        "rhel") yum install -y nc ;;
    esac
fi

# -------------------------
# 安全放行新端口 (防火墙)
# -------------------------
echo "放行新端口 $new_port ..."
if command -v ufw >/dev/null 2>&1; then
    ufw allow $new_port/tcp || true
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=$new_port/tcp || true
    firewall-cmd --reload || true
elif command -v nft >/dev/null 2>&1; then
    nft add rule inet filter input tcp dport $new_port accept 2>/dev/null || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport $new_port -j ACCEPT || true
fi

# -------------------------
# 重启 SSH 服务
# -------------------------
echo "重启 SSH 服务..."
if [ "$OS_TYPE" = "alpine" ]; then
    rc-service sshd restart || /etc/init.d/sshd restart
elif command -v systemctl >/dev/null 2>&1; then
    systemctl restart sshd.service || systemctl restart ssh.service
else
    service ssh restart || service sshd restart
fi

# -------------------------
# 端口监听检测
# -------------------------
echo "正在检测端口监听状态..."
for i in {1..10}; do
    sleep 1
    if command -v ss >/dev/null 2>&1; then
        ss -tnlp | grep -q ":$new_port " && break
    else
        netstat -tnlp | grep -q ":$new_port " && break
    fi
    [ $i -eq 10 ] && echo -e "\033[1;31m⚠ 新端口 $new_port 未能在本地监听\033[0m"
done

# -------------------------
# 远程可达性检测
# -------------------------
echo "检测远程访问..."
VPS_IP=$(curl -s --max-time 5 https://1.1.1.1/cdn-cgi/trace | grep ip | cut -d= -f2 || curl -s --max-time 5 https://ipinfo.io/ip || echo "")

if [ -n "$VPS_IP" ]; then
    if timeout 3 nc -zv $VPS_IP $new_port &>/dev/null; then
        echo -e "\033[1;32m✔ 远程端口 $new_port 可访问\033[0m"
        # 此处可根据需要删除旧端口防火墙规则，逻辑同原脚本
    else
        echo -e "\033[1;33m⚠ 远程访问失败，请检查云服务商安全组设置！\033[0m"
    fi
else
    echo "无法获取外网 IP，跳过远程检测"
fi

echo -e "\033[1;32mSSH 端口切换任务完成: $current_port -> $new_port\033[0m"
