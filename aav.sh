#!/bin/bash

# ================== 颜色定义 ==================
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="webssh"
IMAGE_NAME="cmliu/webssh:latest"
WORKDIR="$HOME/.webssh_manager"
PORT_FILE="$WORKDIR/port.conf"

mkdir -p "$WORKDIR"

# ================== 获取公网 IP ==================
get_ip() {
    for api in \
        "https://api.ip.sb/ip" \
        "https://api.ipify.org" \
        "https://ifconfig.me" \
        "https://icanhazip.com"
    do
        IP=$(curl -s --max-time 5 "$api")
        if [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$IP"
            return 0
        fi
    done

    echo "获取公网IP失败"
    return 1
}

# ================== 暂停并返回菜单 ==================
pause() {
    read -p "按回车返回菜单..." 
    show_menu
}

# ================== 端口检查函数 ==================
check_port() {
    while true; do
        if lsof -i:$PORT &>/dev/null; then
            echo -e "${RED}端口 $PORT 已被占用！${RESET}"
        elif ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
            echo -e "${RED}端口号不合法，请输入 1024-65535 的数字${RESET}"
        else
            break
        fi
        read -p "请输入新的端口号: " PORT
    done
    echo "$PORT" > "$PORT_FILE"
}

# ================== 加载端口配置 ==================
load_port() {
    if [ -f "$PORT_FILE" ]; then
        PORT=$(cat "$PORT_FILE")
    else
        read -p "请输入 WebSSH 映射端口 (默认 8888): " PORT
        PORT=${PORT:-8888}
        check_port
    fi
}

# ================== 菜单函数 ==================
show_menu() {
    clear
    echo -e "${CYAN}================== WebSSH Docker 管理 ==================${RESET}"
    echo -e "${GREEN}01. 安装 WebSSH${RESET}"
    echo -e "${GREEN}02. 停止 WebSSH${RESET}"
    echo -e "${GREEN}03. 启动 WebSSH容器${RESET}"
    echo -e "${GREEN}04. 重启 WebSSH容器${RESET}"
    echo -e "${GREEN}05. 查看 WebSSH容器状态${RESET}"
    echo -e "${GREEN}06. 查看 WebSSH日志${RESET}"
    echo -e "${GREEN}07. 更新 WebSSH${RESET}"
    echo -e "${GREEN}08. 卸载 WebSSH${RESET}"
    echo -e "${GREEN}0.  退出${RESET}"
    echo -e "${CYAN}=======================================================${RESET}"
    read -p "请输入操作编号: " choice
    case "$choice" in
        1) install_run ;;
        2) stop_container ;;
        3) start_container ;;
        4) restart_container ;;
        5) status_container ;;
        6) logs_container ;;
        7) update_container ;;
        8) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误，请重新选择！${RESET}"; sleep 2; show_menu ;;
    esac
}

# ================== 功能函数 ==================
install_run() {
    load_port
    check_port

    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}检测到 Docker 未安装，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker
        systemctl start docker
    fi

    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=$PORT/tcp
        firewall-cmd --reload
    fi

    if docker ps -a | grep -q $CONTAINER_NAME; then
        docker rm -f $CONTAINER_NAME
    fi

    docker pull $IMAGE_NAME
    docker run -d --name $CONTAINER_NAME --restart always -p $PORT:8888 $IMAGE_NAME

    IP=$(get_ip)
    echo -e "${GREEN}WebSSH 已启动，访问: http://$IP:$PORT${RESET}"
    pause
}

stop_container() {
    docker stop $CONTAINER_NAME
    echo -e "${GREEN}WebSSH 已停止${RESET}"
    pause
}

start_container() {
    docker start $CONTAINER_NAME
    echo -e "${GREEN}WebSSH 已启动${RESET}"
    pause
}

restart_container() {
    docker restart $CONTAINER_NAME
    echo -e "${GREEN}WebSSH 已重启${RESET}"
    pause
}

status_container() {
    docker ps -a | grep $CONTAINER_NAME
    pause
}

logs_container() {
    docker logs -f $CONTAINER_NAME
    pause
}

update_container() {
    load_port
    echo -e "${YELLOW}正在拉取最新镜像...${RESET}"
    docker pull $IMAGE_NAME
    if docker ps -a | grep -q $CONTAINER_NAME; then
        docker rm -f $CONTAINER_NAME
    fi
    docker run -d --name $CONTAINER_NAME --restart always -p $PORT:8888 $IMAGE_NAME

    IP=$(get_ip)
    echo -e "${GREEN}WebSSH 已更新并重新启动，访问: http://$IP:$PORT${RESET}"
    pause
}


uninstall_all() {
    docker rm -f $CONTAINER_NAME &>/dev/null
    rm -rf "$WORKDIR"
    echo -e "${GREEN}WebSSH 已彻底卸载，所有数据已删除${RESET}"
    pause
}

# ================== 脚本入口 ==================
while true
do
    show_menu
done
```
