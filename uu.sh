#!/bin/bash

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_DIR="/opt/rbot"
SCRIPT="$APP_DIR/sh_client_bot.sh"


get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。" && return
}


install_bot() {

echo -e "${GREEN}开始安装 RBot...${RESET}"

mkdir -p $APP_DIR
cd $APP_DIR

# 下载脚本
wget -O sh_client_bot.sh https://github.com/semicons/java_oci_manage/releases/latest/download/sh_client_bot.sh

chmod +x sh_client_bot.sh
bash sh_client_bot.sh

SERVER_IP=$(get_public_ip)
echo
echo -e "${GREEN}安装完成${RESET}"
echo -e "${YELLOW}配置文件:$APP_DIR/client_config${RESET}"
echo -e "${YELLOW}访问地址:https://${SERVER_IP}:9527${RESET}"
echo -e "${YELLOW}完成配置，再选择2启动${RESET}"
echo

}

check_install() {

if [ ! -f "$SCRIPT" ]; then
    echo -e "${RED}RBot 未安装，请先安装${RESET}"
    return 1
fi

cd $APP_DIR
return 0
}

start_bot() {
check_install || return
bash sh_client_bot.sh
}

status_bot() {
check_install || return
bash sh_client_bot.sh status
}

log_bot() {
check_install || return
bash sh_client_bot.sh log
}

stop_bot() {
check_install || return
bash sh_client_bot.sh stop
}

restart_bot() {
check_install || return
bash sh_client_bot.sh restart
}

upgrade_bot() {
check_install || return
bash sh_client_bot.sh upgrade
}

uninstall_bot() {

check_install || return

echo -e "${RED}正在卸载 RBot...${RESET}"

bash sh_client_bot.sh uninstall
rm -rf $APP_DIR

echo -e "${GREEN}RBot 已卸载完成${RESET}"

}

menu() {

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
read -rp "$(echo -e ${GREEN}请输入选项:${RESET} )" choice

}

while true
do

menu

case $choice in

1)
install_bot
;;

2)
start_bot
;;

3)
status_bot
;;

4)
log_bot
;;

5)
stop_bot
;;

6)
restart_bot
;;

7)
upgrade_bot
;;

8)
uninstall_bot
;;

0)
exit
;;

*)
echo -e "${RED}无效选项${RESET}"
;;

esac

echo
read -rp "按回车返回菜单..." temp

done
