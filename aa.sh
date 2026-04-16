#!/bin/bash

TARGET="/etc/profile.d/server-motd.sh"

GREEN="\033[1;32m"
RED="\033[1;31m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"

install_motd(){

cat << 'EOF' > $TARGET
#!/bin/bash

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
OS=$(grep PRETTY_NAME /etc/os-release | cut -d '"' -f2)

DATE=$(date "+%Y年%m月%d日 %H:%M:%S")


UPTIME=$(uptime -p | sed 's/up //' \
| sed 's/weeks/周/g' \
| sed 's/week/周/g' \
| sed 's/days/天/g' \
| sed 's/day/天/g' \
| sed 's/hours/小时/g' \
| sed 's/hour/小时/g' \
| sed 's/minutes/分钟/g' \
| sed 's/minute/分钟/g')

LOAD=$(uptime | awk -F'load average:' '{print $2}')

CPU=$(top -bn1 | awk '/Cpu/ {print 100 - $8 "%"}')

MEM=$(free -h | awk '/Mem:/ {print $3 "/" $2}')
SWAP=$(free -h | awk '/Swap:/ {print $3 "/" $2}')

DISK=$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')
DISK_P=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

echo
echo -e "${G}╔════════════════════════════════════════════╗${X}"
echo -e "${G}           🚀 Server Dashboard                ${X}"
echo -e "${G}╚════════════════════════════════════════════╝${X}"
echo -e "${CYAN}----------------------------------------------${RESET}"
printf "用户           : %s\n" "$USER"
printf "主机           : %s\n" "$HOST"
printf "系统           : %s\n" "$OS"
echo -e "${CYAN}----------------------------------------------${RESET}"

printf "当前时间       : %s\n" "$DATE"
printf "运行时间       : %s\n" "$UPTIME"
printf "系统负载       : %s\n" "$LOAD"

echo -e "${CYAN}----------------------------------------------${RESET}"

printf "CPU使用        : %s\n" "$CPU"
printf "内存使用       : %s\n" "$MEM"
printf "Swap使用       : %s\n" "$SWAP"
printf "磁盘使用       : %s\n" "$DISK"

echo -e "${CYAN}----------------------------------------------${RESET}"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then

D_CONT=$(docker ps -aq | wc -l)
D_IMG=$(docker images -q | wc -l)
D_SIZE=$(docker system df | awk '/Images/ {print $4}')

echo -e "${Y}🐳 Docker 状态${X}"

printf "容器数量       : %s\n" "$D_CONT"
printf "镜像数量       : %s\n" "$D_IMG"
printf "Docker占用     : %s\n" "$D_SIZE"

RUN=$(docker ps --format "{{.Names}}")
STOP=$(docker ps -a --filter status=exited --format "{{.Names}}")

if [ -n "$RUN" ]; then
echo
echo "运行容器"
for i in $RUN; do
echo -e " ${G}✅ $i${X}"
done
fi

if [ -n "$STOP" ]; then
echo
echo "停止容器"
for i in $STOP; do
echo -e " ${R}❌ $i${X}"
done
fi


else
echo -e "${R}Docker 未安装${X}"
fi


echo -e "${CYAN}----------------------------------------------${RESET}"
echo -e "${O}🛡 最近登录记录${X}"

LAST_BIN=$(command -v last 2>/dev/null)

if [ -z "$LAST_BIN" ]; then
    if command -v apt >/dev/null 2>&1; then
        apt -qq update >/dev/null 2>&1
        apt -y install wtmpdb >/dev/null 2>&1 || apt -y install util-linux >/dev/null 2>&1
    fi
    LAST_BIN=$(command -v last 2>/dev/null)
fi

if [ -n "$LAST_BIN" ]; then

    if [ ! -f /var/log/wtmp ]; then
        touch /var/log/wtmp
        chmod 664 /var/log/wtmp
        chown root:utmp /var/log/wtmp
    fi

echo "IP               时间"

$LAST_BIN -i -n 3 | grep '^root' | grep -v reboot | while read line
do

IP=$(echo "$line" | awk '{print $3}')
MONTH=$(echo "$line" | awk '{print $5}')
DAY=$(echo "$line" | awk '{print $6}')
TIME=$(echo "$line" | awk '{print $7}')

case $MONTH in
Jan) MONTH="01月" ;;
Feb) MONTH="02月" ;;
Mar) MONTH="03月" ;;
Apr) MONTH="04月" ;;
May) MONTH="05月" ;;
Jun) MONTH="06月" ;;
Jul) MONTH="07月" ;;
Aug) MONTH="08月" ;;
Sep) MONTH="09月" ;;
Oct) MONTH="10月" ;;
Nov) MONTH="11月" ;;
Dec) MONTH="12月" ;;
esac

DATE="${MONTH}${DAY}日 ${TIME}"

printf "${Y}%-15s %s${X}\n" "$IP" "$DATE"

done

else

echo -e "${Y}系统未记录登录日志${X}"

fi

if [ "$DISK_P" -ge 70 ]; then
echo
echo -e "${R}⚠ 磁盘使用率 ${DISK_P}% 请清理${X}"
fi

echo
EOF

chmod +x $TARGET

echo -e "${GREEN}MOTD 安装完成${RESET}"

}

remove_motd(){

rm -f $TARGET
echo -e "${RED}MOTD 已卸载${RESET}"

}

restore_default(){

rm -f $TARGET

true > /etc/motd

if [ -d /etc/update-motd.d ]; then
chmod +x /etc/update-motd.d/*
fi

echo -e "${CYAN}系统 MOTD 已恢复默认${RESET}"

}

preview(){

bash $TARGET

}

menu(){

while true
do

clear

echo -e "${GREEN}====MOTD管理菜单====${RESET}"
echo -e "${GREEN}1. 安装MOTD${RESET}"
echo -e "${GREEN}2. 卸载MOTD${RESET}"
echo -e "${GREEN}3. 恢复系统默认${RESET}"
echo -e "${GREEN}4. 预览MOTD${RESET}"
echo -e "${GREEN}0. 退出${RESET}"
read -r -p $'\033[32m请选择: \033[0m' CH

case $CH in

1) install_motd ;;
2) remove_motd ;;
3) restore_default ;;
4) preview ;;
0) exit ;;

esac

read -p "按回车返回菜单..."

done

}

menu
