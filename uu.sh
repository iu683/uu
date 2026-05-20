#!/bin/bash

# =========================================
# S-UI
# =========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="s-ui"
IMAGE_NAME="alireza7/s-ui:latest"

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

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        echo -e "${GREEN}[✓] Docker 已安装${RESET}"
        return
    fi

    echo -e "${YELLOW}[+] 正在安装 Docker...${RESET}"
    curl -fsSL https://get.docker.com | bash

    systemctl enable docker
    systemctl start docker

    echo -e "${GREEN}[✓] Docker 安装完成${RESET}"
}

install_sui() {
    echo -e "${YELLOW}[+] 创建目录...${RESET}"

    mkdir -p /etc/s-ui
    mkdir -p /usr/local/s-ui

    echo -e "${YELLOW}[+] 拉取镜像...${RESET}"
    docker pull ${IMAGE_NAME}

    echo -e "${YELLOW}[+] 删除旧容器...${RESET}"
    docker rm -f ${CONTAINER_NAME} >/dev/null 2>&1

    echo -e "${YELLOW}[+] 启动 S-UI...${RESET}"

    docker run -d \
      --name ${CONTAINER_NAME} \
      --restart unless-stopped \
      --network host \
      -e TZ=Asia/Tokyo \
      -v /etc/s-ui:/etc/s-ui \
      -v /usr/local/s-ui:/usr/local/s-ui \
      ${IMAGE_NAME}

    echo -e "${GREEN}[✓] S-UI 安装完成${RESET}"

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ S-UI 已启动${RESET}"
    echo -e "${YELLOW}🌐 面板地址: http://${SERVER_IP}:2095/app/${RESET}"
    echo -e "${YELLOW}🔌 订阅地址: http://${SERVER_IP}:2096${RESET}"
}

start_sui() {
    docker start ${CONTAINER_NAME}
    echo -e "${GREEN}[✓] S-UI 已启动${RESET}"
}

stop_sui() {
    docker stop ${CONTAINER_NAME}
    echo -e "${YELLOW}[✓] S-UI 已停止${RESET}"
}

restart_sui() {
    docker restart ${CONTAINER_NAME}
    echo -e "${GREEN}[✓] S-UI 已重启${RESET}"
}

status_sui() {
    docker ps -a | grep ${CONTAINER_NAME}
}

logs_sui() {
    docker logs -f ${CONTAINER_NAME}
}

update_sui() {
    echo -e "${YELLOW}[+] 更新镜像...${RESET}"

    docker pull ${IMAGE_NAME}

    docker rm -f ${CONTAINER_NAME}

    docker run -d \
      --name ${CONTAINER_NAME} \
      --restart unless-stopped \
      --network host \
      -e TZ=Asia/Tokyo \
      -v /etc/s-ui:/etc/s-ui \
      -v /usr/local/s-ui:/usr/local/s-ui \
      ${IMAGE_NAME}

    echo -e "${GREEN}[✓] 更新完成${RESET}"
}

uninstall_sui() {
    read -p "确认卸载 S-UI？(y/n): " confirm

    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        docker rm -f ${CONTAINER_NAME}

        echo -e "${GREEN}[✓] 已卸载 S-UI${RESET}"
    fi
}


menu() {
    clear
    echo -e "${GREEN}==== S-UI  管理菜单====${RESET}"
    echo -e "${GREEN}1. 安装启动${RESET}"
    echo -e "${GREEN}2. 重启${RESET}"
    echo -e "${GREEN}3. 查看状态${RESET}"
    echo -e "${GREEN}4. 查看日志${RESET}"
    echo -e "${GREEN}5  更新${RESET}"
    echo -e "${GREEN}6. 卸载${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    read -p "请输入选项: " num

    case "$num" in
        1)
            install_docker
            install_sui
            ;;
        2)
            restart_sui
            ;;
        3)
            status_sui
            ;;
        4)
            logs_sui
            ;;
        5)
            update_sui
            ;;
        6)
            uninstall_sui
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}[×] 无效选项${RESET}"
            ;;
    esac

    echo
    read -p "按回车继续..."
    menu
}

menu
