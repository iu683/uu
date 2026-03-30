#!/bin/bash

APP_NAME="edict"
APP_DIR="/opt/$APP_NAME"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

loop_service="edict-loop"
dashboard_service="edict-dashboard"

pause(){
read -p "按回车继续..."
}

install_edict(){

echo -e "${YELLOW}安装依赖...${RESET}"

apt update
apt install -y git python3 python3-pip

if [ ! -d "$APP_DIR" ]; then
git clone https://github.com/cft0808/edict.git $APP_DIR
fi

cd $APP_DIR

chmod +x install.sh
./install.sh

if [ -f requirements.txt ]; then
pip3 install -r requirements.txt
fi

echo -e "${YELLOW}创建系统服务...${RESET}"

cat > /etc/systemd/system/$loop_service.service <<EOF
[Unit]
Description=edict loop
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=/bin/bash $APP_DIR/scripts/run_loop.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/$dashboard_service.service <<EOF
[Unit]
Description=edict dashboard
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/python3 $APP_DIR/dashboard/server.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $loop_service
systemctl enable $dashboard_service

systemctl restart $loop_service
systemctl restart $dashboard_service

echo -e "${GREEN}安装完成${RESET}"
echo -e "${GREEN}访问：http://127.0.0.1:7891${RESET}"

pause
}

start_edict(){

systemctl start $loop_service
systemctl start $dashboard_service

echo -e "${GREEN}服务已启动${RESET}"
pause
}

stop_edict(){

systemctl stop $loop_service
systemctl stop $dashboard_service

echo -e "${RED}服务已停止${RESET}"
pause
}

restart_edict(){

systemctl restart $loop_service
systemctl restart $dashboard_service

echo -e "${GREEN}服务已重启${RESET}"
pause
}

update_edict(){

cd $APP_DIR

git pull

systemctl restart $loop_service
systemctl restart $dashboard_service

echo -e "${GREEN}更新完成${RESET}"
pause
}

logs_edict(){

echo -e "${BLUE}查看 dashboard 日志${RESET}"
journalctl -u $dashboard_service -f
}

uninstall_edict(){

systemctl stop $loop_service
systemctl stop $dashboard_service

systemctl disable $loop_service
systemctl disable $dashboard_service

rm -f /etc/systemd/system/$loop_service.service
rm -f /etc/systemd/system/$dashboard_service.service

rm -rf $APP_DIR

systemctl daemon-reload

echo -e "${RED}edict 已卸载${RESET}"

pause
}

menu(){

clear

echo -e "${GREEN}================================${RESET}"
echo -e "${GREEN}    三省六部 · Edict 管理        ${RESET}"
echo -e "${GREEN}================================${RESET}"
echo -e "${GREEN}1. 安装 edict${RESET}"
echo -e "${GREEN}2. 启动 edict${RESET}"
echo -e "${GREEN}3. 停止 edict${RESET}"
echo -e "${GREEN}4. 重启 edict${RESET}"
echo -e "${GREEN}5. 查看日志${RESET}"
echo -e "${GREEN}6. 更新 edict${RESET}"
echo -e "${GREEN}7. 卸载 edict${RESET}"
echo -e "${GREEN}0. 退出${RESET}"

read -r -p $'\033[32m请输入选项: \033[0m' num

case "$num" in

1) install_edict ;;
2) start_edict ;;
3) stop_edict ;;
4) restart_edict ;;
5) logs_edict ;;
6) update_edict ;;
7) uninstall_edict ;;
0) exit 0 ;;

*) echo "无效选项"; sleep 1 ;;

esac

}

while true
do
menu
done
