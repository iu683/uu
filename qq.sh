#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

install_openclaw(){

echo -e "${GREEN}安装 Node.js 22 和 OpenClaw...${RESET}"

# 安装 nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash

# 加载 nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# 安装 Node
nvm install 22
nvm use 22

# 安装 OpenClaw
npm install -g @qingchencloud/openclaw-zh@latest

echo -e "${GREEN}安装完成${RESET}"

}

update_openclaw(){

echo -e "${GREEN}更新 OpenClaw...${RESET}"

npm update -g @qingchencloud/openclaw-zh

}

start_openclaw(){

openclaw gateway start

}

restart_openclaw(){

openclaw gateway restart

}

logs_openclaw(){

openclaw

}

dashboard_openclaw(){

openclaw dashboard

}

status_openclaw(){

openclaw status

}

doctor_openclaw(){

openclaw doctor

}

tg_pair(){

read -p "TG连接码: " code
openclaw pairing approve telegram "$code"

}

skills_list(){

openclaw skills list

}

skills_install(){

openclaw skills install

}

uninstall_openclaw(){

echo -e "${YELLOW}卸载 OpenClaw...${RESET}"

npm uninstall -g @qingchencloud/openclaw-zh
npm uninstall -g openclaw
rm -rf ~/.openclaw

echo -e "${GREEN}卸载完成${RESET}"

}

while true
do

clear

echo -e "${GREEN}=== OpenClaw 管理菜单 ===${RESET}"
echo -e "${GREEN} 1) 安装OpenClaw${RESET}"
echo -e "${GREEN} 2) 更新OpenClaw${RESET}"
echo -e "${GREEN} 3) 启动网关${RESET}"
echo -e "${GREEN} 4) 重启网关${RESET}"
echo -e "${GREEN} 5) 查看日志${RESET}"
echo -e "${GREEN} 6) 打开控制台${RESET}"
echo -e "${GREEN} 7) 查看状态${RESET}"
echo -e "${GREEN} 8) 系统诊断${RESET}"
echo -e "${GREEN} 9) TG配对${RESET}"
echo -e "${GREEN}10) 查看技能${RESET}"
echo -e "${GREEN}11) 安装技能${RESET}"
echo -e "${GREEN}12) 卸载 OpenClaw${RESET}"
echo -e "${GREEN} 0) 退出${RESET}"

read -rp "$(echo -e ${GREEN}请选择:${RESET}) " choice

case "$choice" in

1) install_openclaw ;;
2) update_openclaw ;;
3) start_openclaw ;;
4) restart_openclaw ;;
5) logs_openclaw ;;
6) dashboard_openclaw ;;
7) status_openclaw ;;
8) doctor_openclaw ;;
9) tg_pair ;;
10) skills_list ;;
11) skills_install ;;
12) uninstall_openclaw ;;
0) exit 0 ;;
*) echo -e "${RED}无效选项${RESET}"

esac

echo
read -n 1 -s -r -p "按任意键返回菜单..."

done
