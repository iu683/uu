#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

CONTAINER="openclaw"
IMAGE="ghcr.io/1186258278/openclaw:latest"
INSTALL_SCRIPT="https://cdn.jsdelivr.net/gh/1186258278/OpenClawChineseTranslation@main/docker-deploy.sh"

install_openclaw(){

echo -e "${GREEN}开始安装 OpenClaw...${RESET}"

curl -fsSL $INSTALL_SCRIPT | bash

}

update_openclaw(){

echo -e "${GREEN}更新 OpenClaw...${RESET}"

docker pull $IMAGE

docker stop $CONTAINER 2>/dev/null
docker rm $CONTAINER 2>/dev/null

docker run -d --name openclaw -p 18789:18789 \
-v openclaw-data:/root/.openclaw \
--restart unless-stopped \
$IMAGE \
openclaw gateway run

echo -e "${GREEN}更新完成${RESET}"

}

restart_openclaw(){

echo -e "${GREEN}重启 OpenClaw...${RESET}"

docker restart $CONTAINER

}

logs_openclaw(){

docker logs -f $CONTAINER

}

status_openclaw(){

docker exec $CONTAINER openclaw status

}

config_openclaw(){

docker exec $CONTAINER openclaw config get gateway

}

shell_openclaw(){

docker exec -it $CONTAINER sh

}

docker_clean(){

echo -e "${YELLOW}清理未使用 Docker 资源...${RESET}"

docker system prune -a

}

uninstall_openclaw(){

echo -e "${YELLOW}卸载 OpenClaw...${RESET}"

docker stop $CONTAINER 2>/dev/null
docker rm $CONTAINER 2>/dev/null
docker volume rm openclaw-data 2>/dev/null

echo -e "${GREEN}OpenClaw 已卸载 (数据已删除)${RESET}"

}

#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

CONTAINER="openclaw"
IMAGE="ghcr.io/1186258278/openclaw:latest"
INSTALL_SCRIPT="https://cdn.jsdelivr.net/gh/1186258278/OpenClawChineseTranslation@main/docker-deploy.sh"

install_openclaw(){

echo -e "${GREEN}开始安装 OpenClaw...${RESET}"

bash <(curl -fsSL https://cdn.jsdelivr.net/gh/1186258278/OpenClawChineseTranslation@main/docker-deploy.sh)

}
update_openclaw(){

echo -e "${GREEN}更新 OpenClaw...${RESET}"

docker pull $IMAGE

docker stop $CONTAINER 2>/dev/null
docker rm $CONTAINER 2>/dev/null

docker run -d --name openclaw -p 18789:18789 \
-v openclaw-data:/root/.openclaw \
--restart unless-stopped \
$IMAGE \
openclaw gateway run

echo -e "${GREEN}更新完成${RESET}"

}

restart_openclaw(){

echo -e "${GREEN}重启 OpenClaw...${RESET}"

docker restart $CONTAINER

}

logs_openclaw(){

docker logs -f $CONTAINER

}

status_openclaw(){

docker exec $CONTAINER openclaw status

}

config_openclaw(){

docker exec $CONTAINER openclaw config get gateway

}

shell_openclaw(){

docker exec -it $CONTAINER sh

}

docker_clean(){

echo -e "${YELLOW}清理未使用 Docker 资源...${RESET}"

docker system prune -a

}

uninstall_openclaw(){

echo -e "${YELLOW}卸载 OpenClaw...${RESET}"

docker stop $CONTAINER 2>/dev/null
docker rm $CONTAINER 2>/dev/null
docker volume rm openclaw-data 2>/dev/null

echo -e "${GREEN}OpenClaw 已卸载 (数据已删除)${RESET}"

}

while true
do

clear

echo -e "${GREEN}=== OpenClaw 管理菜单 ===${RESET}"
echo -e "${GREEN}1) 安装启动${RESET}"
echo -e "${GREEN}2) 更新${RESET}"
echo -e "${GREEN}3) 重启${RESET}"
echo -e "${GREEN}4) 查看日志${RESET}"
echo -e "${GREEN}5) 查看状态${RESET}"
echo -e "${GREEN}6) 查看配置${RESET}"
echo -e "${GREEN}7) 进入容器${RESET}"
echo -e "${GREEN}8) Docker清理${RESET}"
echo -e "${GREEN}9) 卸载(含数据)${RESET}"
echo -e "${GREEN}0) 退出${RESET}"

read -rp "$(echo -e ${GREEN}请选择:${RESET}) " choice

case "$choice" in

1) install_openclaw ;;
2) update_openclaw ;;
3) restart_openclaw ;;
4) logs_openclaw ;;
5) status_openclaw ;;
6) config_openclaw ;;
7) shell_openclaw ;;
8) docker_clean ;;
9) uninstall_openclaw ;;
0) exit 0 ;;
*) echo -e "${RED}无效选项${RESET}"

esac

read -n 1 -s -r -p "按任意键返回菜单..."

done
