#!/bin/bash

TARGET="/etc/profile.d/server-motd.sh"

GREEN="\033[1;32m"
RED="\033[1;31m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"

install_motd(){

#!/bin/bash

[ -n "$SUDO_USER" ] && exit

G='\033[1;32m'
B='\033[1;34m'
C='\033[1;36m'
Y='\033[1;33m'
O='\033[38;5;208m'
R='\033[1;31m'
X='\033[0m'

label_w=12

USER=$(whoami)
HOST=$(hostname)
OS=$(grep PRETTY_NAME /etc/os-release | cut -d '"' -f2)

DATE=$(date "+%Y年%m月%d日 %H:%M:%S")
WEEKDAY=$(date "+星期%u" | sed 's/1/一/;s/2/二/;s/3/三/;s/4/四/;s/5/五/;s/6/六/;s/7/日/')

UPTIME=$(uptime -p | sed -E \
's/up //;
s/weeks?/周/g;
s/days?/天/g;
s/hours?/小时/g;
s/minutes?/分钟/g')

LOAD=$(uptime | awk -F'load average:' '{print $2}' | sed 's/,/ |/g')

CPU=$(awk '/^cpu /{printf "%.1f%%",100-($5*100/($2+$3+$4+$5))}' /proc/stat)

MEM=$(free -h | awk '/Mem:/ {print $3 "/" $2}')
SWAP=$(free -h | awk '/Swap:/ {print $3 "/" $2}')

DISK=$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')
DISK_P=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

echo
echo -e "${G}╔════════════════════════════════════════════╗${X}"
echo -e "${G}           🚀 Server Dashboard                ${X}"
echo -e "${G}╚════════════════════════════════════════════╝${X}"

printf "👤 %-*s : %s\n" $label_w "用户" "$USER"
printf "💻 %-*s : %s\n" $label_w "主机" "$HOST"
printf "🖥 %-*s : %s\n" $label_w "系统" "$OS"

echo

printf "⏰ %-*s : %s (%s)\n" $label_w "时间" "$DATE"
printf "🆙 %-*s : %s\n" $label_w "运行时间" "$UPTIME"
printf "📊 %-*s : %s\n" $label_w "系统负载" "$LOAD"

echo

printf "🔥 %-*s : %s\n" $label_w "CPU使用" "$CPU"
printf "💾 %-*s : %s\n" $label_w "内存使用" "$MEM"
printf "🧠 %-*s : %s\n" $label_w "Swap使用" "$SWAP"
printf "🗂 %-*s : %s\n" $label_w "磁盘使用" "$DISK"

echo

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then

D_CONT=$(docker ps -aq | wc -l)
D_IMG=$(docker images -q | wc -l)
D_SIZE=$(docker system df | awk '/Images/ {print $4}')

echo -e "${Y}🐳 Docker 状态${X}"

printf "📦 %-*s : %s\n" $label_w "容器数量" "$D_CONT"
printf "🖼 %-*s : %s\n" $label_w "镜像数量" "$D_IMG"
printf "📦 %-*s : %s\n" $label_w "Docker占用" "$D_SIZE"

RUN=$(docker ps --format "{{.Names}}")
STOP=$(docker ps -a --filter status=exited --format "{{.Names}}")

[ -n "$RUN" ] && {
echo
echo "运行容器"
for i in $RUN; do
echo -e " ${G}✔ $i${X}"
done
}

[ -n "$STOP" ] && {
echo
echo "停止容器"
for i in $STOP; do
echo -e " ${R}✘ $i${X}"
done
}

echo
docker stats --no-stream --format "  {{.Name}} CPU:{{.CPUPerc}} MEM:{{.MemUsage}}"

else
echo -e "${R}Docker 未安装${X}"
fi

echo
echo -e "${O}🛡 最近登录记录${X}"

LAST_BIN=$(command -v last)

if [ -n "$LAST_BIN" ]; then

[ ! -f /var/log/wtmp ] && touch /var/log/wtmp

printf "%-18s %s\n" "IP地址" "登录时间"

$LAST_BIN -i -n 3 | awk '/^root/ && !/reboot/{
ip=$3
month=$5
day=$6
time=$7

m["Jan"]="01月";m["Feb"]="02月";m["Mar"]="03月";m["Apr"]="04月";
m["May"]="05月";m["Jun"]="06月";m["Jul"]="07月";m["Aug"]="08月";
m["Sep"]="09月";m["Oct"]="10月";m["Nov"]="11月";m["Dec"]="12月";

printf "%-18s %s%s日 %s\n",ip,m[month],day,time
}'

else
echo -e "${Y}系统未记录登录日志${X}"
fi

if [ "$DISK_P" -ge 70 ]; then
echo
echo -e "${R}⚠ 磁盘使用率 ${DISK_P}% 请清理${X}"
fi

echo

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
