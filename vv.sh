#!/bin/bash

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_DIR="/opt/rbot"
SCRIPT="$APP_DIR/sh_client_bot.sh"

pause(){
echo
read -rp "按回车返回菜单..." temp
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
}

install_bot(){

echo -e "${GREEN}开始安装 RBot...${RESET}"

mkdir -p $APP_DIR
cd $APP_DIR

wget -O sh_client_bot.sh https://github.com/semicons/java_oci_manage/releases/latest/download/sh_client_bot.sh

chmod +x sh_client_bot.sh
bash sh_client_bot.sh

SERVER_IP=$(get_public_ip)

echo
echo -e "${GREEN}安装完成${RESET}"
echo -e "${YELLOW}配置文件:$APP_DIR/client_config${RESET}"
echo -e "${YELLOW}访问地址:https://${SERVER_IP}:9527${RESET}"
echo -e "${YELLOW}完成配置，再选择2启动${RESET}"

pause
}

check_install(){

if [ ! -f "$SCRIPT" ]; then
echo -e "${RED}RBot 未安装，请先安装${RESET}"
pause
return 1
fi

cd $APP_DIR
}

start_bot(){
check_install || return
bash sh_client_bot.sh
pause
}

status_bot(){
check_install || return
bash sh_client_bot.sh status
pause
}

log_bot(){
check_install || return
bash sh_client_bot.sh log
pause
}

stop_bot(){
check_install || return
bash sh_client_bot.sh stop
pause
}

restart_bot(){
check_install || return
bash sh_client_bot.sh restart
pause
}

upgrade_bot(){
check_install || return
bash sh_client_bot.sh upgrade
pause
}

uninstall_bot(){

check_install || return

echo -e "${RED}正在卸载 RBot...${RESET}"

bash sh_client_bot.sh uninstall
rm -rf $APP_DIR

echo -e "${GREEN}RBot 已卸载完成${RESET}"

pause
}

menu(){

clear

echo -e "${GREEN}================================${RESET}"
echo -e "${GREEN}      RBot 管理脚本${RESET}"
echo -e "${GREEN}================================${RESET}"
echo -e "${YELLOW}1.安装 RBot${RESET}"
echo -e "${YELLOW}2.启动${RESET}"
echo -e "${YELLOW}3.查看状态${RESET}"
echo -e "${YELLOW}4.查看日志${RESET}"
echo -e "${YELLOW}5.停止${RESET}"
echo -e "${YELLOW}6.重启${RESET}"
echo -e "${YELLOW}7.升级${RESET}"
echo -e "${YELLOW}8.卸载${RESET}"
echo -e "${YELLOW}0.退出${RESET}"

read -rp "$(echo -e ${GREEN}请输入选项:${RESET}) " choice
}

while true
do

menu

case $choice in

1) install_bot ;;
2) start_bot ;;
3) status_bot ;;
4) log_bot ;;
5) stop_bot ;;
6) restart_bot ;;
7) upgrade_bot ;;
8) uninstall_bot ;;
0) exit ;;

*)
echo -e "${RED}无效选项${RESET}"
pause
;;

esac

done
