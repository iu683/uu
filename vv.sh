#!/bin/bash

# ========================================
# SSH 端口修改与双栈检测全能脚本
# 适配: Ubuntu, Debian, Alpine, RHEL/CentOS
# 支持: IPv4 / IPv6 远程连通性检测
# ========================================

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

# 2. 安装必要工具 (nc)
echo -e "${YELLOW}检查必要工具...${RESET}"
if ! command -v nc >/dev/null 2>&1; then
    if [ "$OS" = "Alpine" ]; then
        apk add --no-cache netcat-openbsd >/dev/null 2>&1
    else
        apt-get update -y >/dev/null 2>&1
        apt-get install -y netcat-openbsd >/dev/null 2>&1
    fi
fi

# 3. 获取端口信息
current_port=$(grep -E '^ *Port [0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | head -n1)
current_port=${current_port:-22}
echo -e "${YELLOW}当前 SSH 端口: $current_port${RESET}"

read -p "请输入新的 SSH 端口号: " new_port
if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -le 0 ] || [ "$new_port" -gt 65535 ]; then
    echo -e "${RED}错误: 端口无效！${RESET}"
    exit 1
fi

# 4. 备份与修改配置
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
if grep -q "^Port " /etc/ssh/sshd_config; then
    sed -i "s/^Port .*/Port $new_port/" /etc/ssh/sshd_config
else
    echo "Port $new_port" >> /etc/ssh/sshd_config
fi

# 5. 放行防火墙 (UFW/Firewalld/Iptables)
echo -e "${YELLOW}正在放行防火墙端口 $new_port...${RESET}"
if command -v ufw >/dev/null 2>&1; then
    # UFW 默认同时处理 v4 和 v6
    ufw allow "$new_port"/tcp >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$new_port"/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null || true
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null || true
    fi
fi

# 6. 重启服务 (解决 Ubuntu/Debian Socket 冲突)
echo -e "${YELLOW}正在重启 SSH 服务...${RESET}"
if [[ "$OS" == "Ubuntu" ]] || [[ "$OS" == "Debian" ]]; then
    systemctl stop ssh.socket >/dev/null 2>&1 || true
    systemctl disable ssh.socket >/dev/null 2>&1 || true
fi

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
SUCCESS=false
for i in {1..5}; do
    sleep 2
    if command -v ss >/dev/null 2>&1; then
        CHECK=$(ss -tlnp | grep ":$new_port ")
    else
        CHECK=$(netstat -tlnp | grep ":$new_port ")
    fi
    if [ -n "$CHECK" ]; then SUCCESS=true && break; fi
    echo -e "${YELLOW}等待服务绑定端口... ($i/5)${RESET}"
done

if [ "$SUCCESS" = true ]; then
    echo -e "${GREEN}✔ 本地端口 $new_port 监听成功${RESET}"
else
    echo -e "${RED}❌ 本地检测失败，请手动执行 'ss -tlnp | grep :$new_port' 确认${RESET}"
    exit 1
fi

# 8. 远程连通性检测 (兼容 v4/v6)
echo -e "${YELLOW}正在执行远程连通性检测...${RESET}"

# 探测 IP (优先获取 IPv6，其次 IPv4)
IP_V6=$(curl -6 -sL --max-time 5 https://6.ipw.cn || echo "")
IP_V4=$(curl -4 -sL --max-time 5 https://4.ipw.cn || curl -sL --max-time 5 https://api.ipify.org || echo "")

test_remote() {
    local ip=$1
    local mode=$2
    if [ -n "$ip" ]; then
        echo -en "检测 $mode 地址 $ip ... "
        # IPv6 检测需加 -6 参数
        local nc_cmd="nc -zv"
        [[ "$mode" == "IPv6" ]] && nc_cmd="nc -6 -zv"
        
        if timeout 6 $nc_cmd "$ip" "$new_port" 2>&1 | grep -q "succeeded\|open"; then
            echo -e "${GREEN}✔ 通畅${RESET}"
            return 0
        else
            echo -e "${RED}✘ 失败${RESET}"
            return 1
        fi
    fi
    return 2
}

V4_RES=$(test_remote "$IP_V4" "IPv4")
V6_RES=$(test_remote "$IP_V6" "IPv6")

if [[ $V4_RES -ne 0 && $V6_RES -ne 0 ]]; then
    echo -e "\n${RED}❌ 远程检测全部失败！${RESET}"
    echo -e "${YELLOW}请检查：${RESET}"
    echo -e "1. 云服务商后台安全组是否放行了 TCP:$new_port (需分别检查 v4/v6 规则)"
    echo -e "2. 某些地区运营商可能屏蔽了非标准端口"
else
    echo -e "\n${GREEN}✔ 远程连通性检测通过！${RESET}"
fi

echo -e "\n${GREEN}========================================${RESET}"
echo -e "${GREEN}  操作完成！当前 SSH 端口为: $new_port ${RESET}"
echo -e "${YELLOW}  请务必打开新窗口测试连接，确认成功后再退出！${RESET}"
echo -e "${GREEN}========================================${RESET}"
