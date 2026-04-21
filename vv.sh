#!/bin/bash
set -e

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# 1. 权限与系统检查
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 root 权限运行${RESET}"
    exit 1
fi

if [ -f /etc/alpine-release ]; then
    OS="Alpine"
elif grep -qi "ubuntu" /etc/os-release; then
    OS="Ubuntu"
elif [ -f /etc/debian_version ]; then
    OS="Debian"
else
    OS="Linux"
fi

echo -e "${GREEN}检测到系统: $OS${RESET}"

# 2. 工具安装 (远程检测需要 nc)
echo -e "${YELLOW}检查必要工具...${RESET}"
if ! command -v nc >/dev/null 2>&1; then
    if [ "$OS" = "Alpine" ]; then
        apk add --no-cache netcat-openbsd
    else
        apt-get update -q && apt-get install -y netcat-openbsd >/dev/null 2>&1
    fi
fi

# 3. 获取并设置端口
current_port=$(grep -E '^ *Port [0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | head -n1)
current_port=${current_port:-22}
echo -e "${YELLOW}当前 SSH 端口: $current_port${RESET}"

read -p "请输入新的 SSH 端口号: " new_port
if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -le 0 ] || [ "$new_port" -gt 65535 ]; then
    echo -e "${RED}端口无效！${RESET}"
    exit 1
fi

# 4. 备份与修改
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
if grep -q "^Port " /etc/ssh/sshd_config; then
    sed -i "s/^Port .*/Port $new_port/" /etc/ssh/sshd_config
else
    echo "Port $new_port" >> /etc/ssh/sshd_config
fi

# 5. 放行防火墙
echo -e "${YELLOW}放行防火墙端口 $new_port...${RESET}"
if command -v ufw >/dev/null 2>&1; then
    ufw allow "$new_port"/tcp >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$new_port"/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "$new_port" -j ACCEPT || true
fi

# 6. 重启服务
echo -e "${YELLOW}重启 SSH 服务...${RESET}"
restart_done=false
for svc in ssh sshd; do
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart "$svc" >/dev/null 2>&1 && restart_done=true && break
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" restart >/dev/null 2>&1 && restart_done=true && break
    fi
done

if [ "$restart_done" = false ]; then
    echo -e "${RED}❌ SSH 服务重启失败！${RESET}"
    exit 1
fi

# 7. 本地监听检测
echo -e "${YELLOW}正在检测本地监听状态...${RESET}"
sleep 2
if command -v ss >/dev/null 2>&1; then
    LISTEN_CHECK=$(ss -tlnp | grep ":$new_port ")
else
    LISTEN_CHECK=$(netstat -tlnp | grep ":$new_port ")
fi

if [ -n "$LISTEN_CHECK" ]; then
    echo -e "${GREEN}✔ 本地端口 $new_port 监听成功${RESET}"
else
    echo -e "${RED}❌ 本地端口 $new_port 未监听，请检查配置${RESET}"
    exit 1
fi

# 8. 远程连通性检测
echo -e "${YELLOW}正在执行远程连通性检测...${RESET}"
# 获取外网 IP
PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org || curl -s --max-time 5 https://ifconfig.me || echo "")

if [ -n "$PUBLIC_IP" ]; then
    echo -e "外网 IP: $PUBLIC_IP"
    # 使用 nc 模拟远程访问
    if timeout 5 nc -zv "$PUBLIC_IP" "$new_port" >/dev/null 2>&1; then
        echo -e "${GREEN}✔ 远程检测通过！端口 $new_port 已开放${RESET}"
    else
        echo -e "${RED}❌ 远程检测失败！${RESET}"
        echo -e "${YELLOW}原因可能是：${RESET}"
        echo -e "1. 云服务商（腾讯/阿里/甲骨文）的安全组/防火墙未开放 $new_port 端口"
        echo -e "2. 运营商屏蔽了该端口"
        echo -e "${RED}请务必先去云后台开放端口，否则断开后将无法连接！${RESET}"
    fi
else
    echo -e "${RED}⚠ 无法获取外网 IP，跳过远程检测${RESET}"
fi

echo -e "\n${GREEN}操作完成！当前端口: $new_port${RESET}"
echo -e "${YELLOW}警告: 在确认新窗口能成功登录前，请勿关闭此终端！${RESET}"
