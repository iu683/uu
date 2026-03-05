#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

install_openclaw(){

echo -e "${GREEN}安装 Node.js 22 和 OpenClaw...${RESET}"

# 更新 apt 并安装必要工具
sudo apt-get update
sudo apt-get install -y curl

# 安装 Node.js 22（官方 NodeSource 源）
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# 验证安装
node -v
npm -v

# 安装 OpenClaw 汉化版（全局）
sudo npm install -g @qingchencloud/openclaw-zh@latest

echo -e "${GREEN}安装完成，OpenClaw 命令已可用${RESET}"

# 安装为守护进程（后台运行，开机自启）
openclaw onboard --install-daemon

# 打开控制台
openclaw dashboard

}

enable_lan_access(){
    echo -e "${GREEN}开启局域网访问...${RESET}"

    # 绑定到局域网
    openclaw config set gateway.bind lan

    # 设置访问密码
    read -rp "请输入网关访问密码: " token
    openclaw config set gateway.auth.token "$token"

    # 重启网关生效
    openclaw gateway restart

    echo -e "${GREEN}局域网访问已开启！请在局域网访问 http://你的IP:18789 并输入密码${RESET}"
}

update_openclaw(){

echo -e "${GREEN}更新 OpenClaw...${RESET}"

npm update -g @qingchencloud/openclaw-zh

}

start_openclaw(){

openclaw gateway stop

}

restart_openclaw(){

openclaw gateway restart

}

logs_openclaw(){

journalctl --user -u openclaw-gateway

}

dashboard_openclaw(){

openclaw dashboard

}

status_openclaw(){

openclaw gateway status

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

config_openclaw(){

openclaw config set KEY VALUE

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
echo -e "${GREEN} 2) 开启局域网访问${RESET}"
echo -e "${GREEN} 3) 停止网关${RESET}"
echo -e "${GREEN} 4) 重启网关${RESET}"
echo -e "${GREEN} 5) 查看日志${RESET}"
echo -e "${GREEN} 6) 打开控制台${RESET}"
echo -e "${GREEN} 7) 查看状态${RESET}"
echo -e "${GREEN} 8) 系统诊断${RESET}"
echo -e "${GREEN} 9) TG配对码${RESET}"
echo -e "${GREEN}10) 查看技能${RESET}"
echo -e "${GREEN}11) 安装技能${RESET}"
echo -e "${GREEN}12) 修改配置${RESET}"
echo -e "${GREEN}13) 更新OpenClaw${RESET}"
echo -e "${GREEN}14) 卸载 OpenClaw${RESET}"
echo -e "${GREEN} 0) 退出${RESET}"

read -rp "$(echo -e ${GREEN}请选择:${RESET}) " choice

case "$choice" in

1) install_openclaw ;;
2) enable_lan_access ;;
3) start_openclaw ;;
4) restart_openclaw ;;
5) logs_openclaw ;;
6) dashboard_openclaw ;;
7) status_openclaw ;;
8) doctor_openclaw ;;
9) tg_pair ;;
10) skills_list ;;
11) skills_install ;;
12) config_openclaw ;;
13) update_openclaw ;;
14) uninstall_openclaw ;;
0) exit 0 ;;
*) echo -e "${RED}无效选项${RESET}"

esac

echo
read -n 1 -s -r -p "按任意键返回菜单..."

done
