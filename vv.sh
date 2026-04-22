#!/bin/bash

# ====================================================
# 配置信息
# ====================================================
TARGET="/etc/profile.d/server-motd.sh"

GREEN="\033[1;32m"
RED="\033[1;31m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"

# ====================================================
# 安装函数
# ====================================================
install_motd(){
    echo -e "${CYAN}正在检查系统环境...${RESET}"

    # 1. 自动适配包管理器并安装必要依赖
    if [ -f /etc/alpine-release ]; then
        echo -e "${YELLOW}检测到 Alpine Linux, 正在配置依赖...${RESET}"
        apk add --no-cache util-linux bash coreutils 2>/dev/null
        [ ! -f /var/log/wtmp ] && touch /var/log/wtmp
    elif command -v apt >/dev/null 2>&1; then
        echo -e "${YELLOW}检测到 Debian/Ubuntu, 正在检查依赖...${RESET}"
        if ! command -v last >/dev/null 2>&1; then
            apt update && apt install -y util-linux
        fi
        [ ! -f /var/log/wtmp ] && touch /var/log/wtmp && chown root:utmp /var/log/wtmp && chmod 664 /var/log/wtmp
    fi

    # 2. 写入 MOTD 脚本
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

# 获取基础信息
USER=$(whoami)
HOST=$(hostname)
[ -f /etc/os-release ] && OS=$(grep PRETTY_NAME /etc/os-release | cut -d '"' -f2) || OS="Linux"
DATE=$(date "+%Y年%m月%d日 %H:%M:%S")

# 兼容性处理 Uptime (适配 BusyBox 和 GNU)
UPTIME_RAW=$(uptime)
if [[ "$UPTIME_RAW" == *"up"* ]]; then
    UPTIME=$(echo "$UPTIME_RAW" | sed 's/.*up \([^,]*\),.*/\1/' | sed 's/days/天/g' | sed 's/day/天/g' | sed 's/min/分钟/g')
else
    UPTIME="未知"
fi

LOAD=$(uptime | awk -F'load average:' '{print $2}')

# 兼容性处理 CPU 使用率 (适配 Alpine/Debian)
CPU_IDLE=$(top -bn1 | grep -i "cpu" | head -n 1 | awk -F'id,' '{print $1}' | awk '{print $NF}' | tr -d '%')
if [ -z "$CPU_IDLE" ]; then
    CPU_USAGE=$(top -bn1 | awk '/Cpu/ {print 100 - $8 "%"}')
else
    CPU_USAGE=$(echo "100 - $CPU_IDLE" | bc 2>/dev/null || awk "BEGIN {print 100 - $CPU_IDLE}")"%"
fi

# 内存与磁盘
MEM=$(free -h | awk '/Mem:/ {print $3 "/" $2}')
DISK=$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')
DISK_P=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

echo
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
printf "CPU使用        : %s\n" "$CPU_USAGE"
printf "内存使用       : %s\n" "$MEM"
printf "磁盘使用       : %s\n" "$DISK"
echo -e "${C}----------------------------------------------${X}"

# Docker 状态监测
if command -v docker >/dev/null 2>&1; then
    D_CONT=$(docker ps -q | wc -l)
    D_RUNNING=$(docker ps --format "{{.Names}}")
    echo -e "${Y}🐳 Docker 正在运行容器 ($D_CONT):${X}"
    for i in $D_RUNNING; do echo -e "  ${G}●${X} $i"; done
    echo -e "${C}----------------------------------------------${X}"
fi

# 登录记录逻辑
echo -e "${O}🛡 最近登录记录 (TOP 3)${X}"
if command -v last >/dev/null 2>&1; then
    # 适配不同版本的 last 输出
    last -i -n 3 | grep -vE 'reboot|wtmp|begins' | head -n 3 | while read line; do
        if [ -n "$line" ]; then
            IP=$(echo "$line" | awk '{print $3}')
            TIME=$(echo "$line" | awk '{print $4,$5,$6}')
            printf " ${Y}%-15s${X} %s\n" "$IP" "$TIME"
        fi
    done
else
    echo "  暂无记录或工具未安装"
fi

# 磁盘报警
if [ "$DISK_P" -ge 80 ]; then
    echo -e "\n${R}⚠ 警告: 磁盘空间占用过高 (${DISK_P}%)${X}"
fi
echo
EOF

    chmod +x $TARGET
    echo -e "${GREEN}MOTD 安装成功！请重新登录或输入 'bash $TARGET' 查看效果。${RESET}"
}

# ====================================================
# 卸载与恢复函数
# ====================================================
remove_motd(){
    rm -f $TARGET
    echo -e "${RED}MOTD 已卸载${RESET}"
}

restore_default(){
    rm -f $TARGET
    [ -f /etc/motd ] && true > /etc/motd
    if [ -d /etc/update-motd.d ]; then
        chmod +x /etc/update-motd.d/*
    fi
    echo -e "${CYAN}系统 MOTD 已恢复默认${RESET}"
}

preview(){
    [ -f $TARGET ] && bash $TARGET || echo -e "${RED}请先安装 MOTD${RESET}"
}

# ====================================================
# 主菜单
# ====================================================
menu(){
    while true; do
        clear
        echo -e "${GREEN}==== MOTD 管理菜单====${RESET}"
        echo -e "1. 安装"
        echo -e "2. 卸载"
        echo -e "3. 恢复系统默认设置"
        echo -e "4. 立即预览效果"
        echo -e "0. 退出"
        read -r -p "请输入数字选择: " CH
        case $CH in
            1) install_motd ;;
            2) remove_motd ;;
            3) restore_default ;;
            4) preview ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入${RESET}" ;;
        esac
        read -n 1 -s -r -p "按回车键返回菜单..."
    done
}

menu
