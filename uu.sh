#!/bin/bash

TARGET="/etc/profile.d/server-motd.sh"

GREEN="\033[1;32m"
RED="\033[1;31m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"

install_motd(){

# 如果是 Alpine，先准备环境
if [ -f /etc/alpine-release ]; then
    echo -e "${YELLOW}检测到 Alpine 系统，正在配置环境...${RESET}"
    apk add --no-cache util-linux bash coreutils 2>/dev/null
    touch /var/log/wtmp
fi

cat << 'EOF' > $TARGET
#!/bin/bash

# 忽略 sudo 切换时的显示
[ -n "$SUDO_USER" ] && exit

G='\033[1;32m'
B='\033[1;34m'
C='\033[1;36m'
Y='\033[1;33m'
O='\033[38;5;208m'
R='\033[1;31m'
X='\033[0m'

USER=$(whoami)
HOST=$(hostname)
[ -f /etc/os-release ] && OS=$(grep PRETTY_NAME /etc/os-release | cut -d '"' -f2) || OS="Linux"

DATE=$(date "+%Y-%m-%d %H:%M:%S")
UPTIME=$(uptime | awk -F', ' '{print $1}' | sed 's/.*up //')
LOAD=$(uptime | awk -F'load average:' '{print $2}')

# 兼容性处理 CPU 使用率 (Alpine/Debian 通用)
CPU=$(top -bn1 | grep "CPU" | head -n 1 | awk '{print $2 + $4"%"}')
[ -z "$CPU" ] && CPU=$(top -bn1 | awk '/Cpu/ {print 100 - $8 "%"}')

MEM=$(free -h | awk '/Mem:/ {print $3 "/" $2}')
SWAP=$(free -h | awk '/Swap:/ {print $3 "/" $2}')

DISK=$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')
DISK_P=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

echo -e "${G}╔════════════════════════════════════════════╗${X}"
echo -e "${G}           🚀 Server Dashboard                ${X}"
echo -e "${G}╚════════════════════════════════════════════╝${X}"
echo -e "${C}----------------------------------------------${X}"
printf "用户           : %s\n" "$USER"
printf "主机           : %s\n" "$HOST"
printf "系统           : %s\n" "$OS"
echo -e "${C}----------------------------------------------${X}"
printf "当前时间       : %s\n" "$DATE"
printf "运行时间       : %s\n" "$UPTIME"
printf "系统负载       : %s\n" "$LOAD"
echo -e "${C}----------------------------------------------${X}"
printf "CPU使用        : %s\n" "$CPU"
printf "内存使用       : %s\n" "$MEM"
printf "磁盘使用       : %s\n" "$DISK"
echo -e "${C}----------------------------------------------${X}"

# Docker 部分
if command -v docker >/dev/null 2>&1; then
    D_CONT=$(docker ps -aq | wc -l)
    echo -e "${Y}🐳 Docker 容器数量: $D_CONT${X}"
fi

echo -e "${O}🛡 最近登录记录 (TOP 3)${X}"

if [ ! -f /var/log/wtmp ] || [ ! -s /var/log/wtmp ]; then
    echo -e "  ${Y}系统暂无登录记录${X}"
else
    # 打印中文表头
    printf "  ${C}%-10s %-16s %s${X}\n" "用户名" "来源IP/终端" "登录时间"
    
    # 获取记录并处理
    # head -n 3 限制显示条数
    last | grep -vE "reboot|wtmp|begins|^$" | head -n 3 | while read -r line
    do
        [ -z "$line" ] && continue

        USER_NAME=$(echo "$line" | awk '{print $1}')
        IP_ADDR=$(echo "$line" | awk '{print $3}')
        
        # 提取时间并尝试汉化月份
        # 原始格式通常是: Wed Apr 22 10:00
        MONTH=$(echo "$line" | awk '{print $5}')
        DAY=$(echo "$line" | awk '{print $6}')
        TIME=$(echo "$line" | awk '{print $7}')
        
        case $MONTH in
            Jan) MONTH="01月" ;; Feb) MONTH="02月" ;; Mar) MONTH="03月" ;;
            Apr) MONTH="04月" ;; May) MONTH="05月" ;; Jun) MONTH="06月" ;;
            Jul) MONTH="07月" ;; Aug) MONTH="08月" ;; Sep) MONTH="09月" ;;
            Oct) MONTH="10月" ;; Nov) MONTH="11月" ;; Dec) MONTH="12月" ;;
        esac

        # 格式化输出
        printf "  %-11s %-16s %s\n" "$USER_NAME" "$IP_ADDR" "${MONTH}${DAY}日 ${TIME}"
    done
fi

[ "$DISK_P" -ge 80 ] && echo -e "${R}⚠ 磁盘空间不足: ${DISK_P}%${X}"
echo
EOF

chmod +x $TARGET
echo -e "${GREEN}MOTD 安装完成!${RESET}"
}

remove_motd(){
    rm -f $TARGET
    echo -e "${RED}MOTD 已卸载${RESET}"
}

restore_default(){
    rm -f $TARGET
    [ -f /etc/motd ] && true > /etc/motd
    echo -e "${CYAN}系统 MOTD 已恢复默认${RESET}"
}

preview(){
    bash $TARGET
}

menu(){
    while true; do
        clear
        echo -e "${GREEN}==== MOTD 管理菜单 ====${RESET}"
        echo -e "1. 安装 MOTD"
        echo -e "2. 卸载 MOTD"
        echo -e "3. 恢复默认"
        echo -e "4. 预览"
        echo -e "0. 退出"
        read -p "选择: " CH
        case $CH in
            1) install_motd ;;
            2) remove_motd ;;
            3) restore_default ;;
            4) preview ;;
            0) exit ;;
        esac
        read -p "按回车继续..." temp
    done
}

menu
