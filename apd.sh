#!/bin/sh
set -e

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

info() { echo -e "${GREEN}[INFO] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
error() { echo -e "${RED}[ERROR] $1${RESET}"; }

# ================== 权限检查 ==================
root_use() {
    if [ "$(id -u)" -ne 0 ]; then
        error "请使用 root 用户运行脚本！"
        exit 1
    fi
}

pause() {
    echo
    read -p "按回车返回菜单..." dummy
}

# ================== 工具 ==================
current_iptables() {
    if command -v iptables >/dev/null 2>&1; then
        iptables --version | awk '{print $2}'
    else
        echo "未安装"
    fi
}

wait_docker_ready() {
    info "等待 Docker daemon 就绪..."
    timeout=15
    while [ ! -S /var/run/docker.sock ] && [ $timeout -gt 0 ]; do
        sleep 1
        timeout=$((timeout-1))
    done
    if [ -S /var/run/docker.sock ]; then
        info "Docker daemon 已就绪"
    else
        warn "Docker daemon 仍未就绪"
    fi
}

# ================== Docker 安装/更新 ==================
install_or_update_docker() {
    info "更新 apk 源..."
    apk update
    apk upgrade

    info "安装 Docker..."
    apk add docker py3-pip curl

    info "设置开机自启..."
    rc-update add docker boot

    info "启动 Docker 服务..."
    service docker start

    wait_docker_ready
    docker version
    pause
}

install_or_update_compose() {
    info "安装/更新 Docker Compose..."
    COMPOSE_LATEST=$(curl -s https://api.github.com/repos/docker/compose/releases/latest \
        | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    curl -L "https://github.com/docker/compose/releases/download/v$COMPOSE_LATEST/docker-compose-linux-x86_64" \
        -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    docker-compose version
    pause
}

uninstall_docker_compose() {
    info "停止 Docker 服务..."
    service docker stop || true
    info "卸载 Docker 与 Compose..."
    apk del docker py3-pip
    rm -f /usr/local/bin/docker-compose
    rc-update del docker
    pause
}

restart_docker() {
    info "重启 Docker 服务..."
    service docker restart
    wait_docker_ready
    pause
}

check_status() {
    if service docker status >/dev/null 2>&1; then
        info "Docker 服务正在运行"
    else
        warn "Docker 服务未运行"
    fi
    pause
}

# ================== 容器管理 ==================
container_menu() {
    echo -e "${GREEN}===== 容器管理 =====${RESET}"
    echo -e "${GREEN}1) 查看所有容器${RESET}"
    echo -e "${GREEN}2) 启动容器${RESET}"
    echo -e "${GREEN}3) 停止容器${RESET}"
    echo -e "${GREEN}4) 删除容器${RESET}"
    echo -e "${GREEN}0) 返回主菜单${RESET}"
    read -rp "请选择: " c_choice
    case $c_choice in
        1) docker ps -a; pause ;;
        2) read -rp "容器名称或ID: " cid; [ -n "$cid" ] && docker start "$cid"; pause ;;
        3) read -rp "容器名称或ID: " cid; [ -n "$cid" ] && docker stop "$cid"; pause ;;
        4) read -rp "容器名称或ID: " cid; [ -n "$cid" ] && docker rm "$cid"; pause ;;
        0) return ;;
        *) warn "无效选项"; pause ;;
    esac
    container_menu
}

# ================== 镜像管理 ==================
image_menu() {
    echo -e "${GREEN}===== 镜像管理 =====${RESET}"
    echo -e "${GREEN}1) 查看镜像列表${RESET}"
    echo -e "${GREEN}2) 拉取镜像${RESET}"
    echo -e "${GREEN}3) 删除镜像${RESET}"
    echo -e "${GREEN}0) 返回主菜单${RESET}"
    read -rp "请选择: " i_choice
    case $i_choice in
        1) docker images; pause ;;
        2) read -rp "镜像名称: " img; [ -n "$img" ] && docker pull "$img"; pause ;;
        3) read -rp "镜像ID或名称: " img; [ -n "$img" ] && docker rmi "$img"; pause ;;
        0) return ;;
        *) warn "无效选项"; pause ;;
    esac
    image_menu
}

# ================== 卷管理 ==================
volume_menu() {
    echo -e "${GREEN}===== 卷管理 =====${RESET}"
    echo -e "${GREEN}1) 查看卷列表${RESET}"
    echo -e "${GREEN}2) 删除卷${RESET}"
    echo -e "${GREEN}0) 返回主菜单${RESET}"
    read -rp "请选择: " v_choice
    case $v_choice in
        1) docker volume ls; pause ;;
        2) read -rp "卷名称: " vol; [ -n "$vol" ] && docker volume rm "$vol"; pause ;;
        0) return ;;
        *) warn "无效选项"; pause ;;
    esac
    volume_menu
}

# ================== IPv6 ==================
enable_ipv6() {
    echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6
    sed -i '/^net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
    echo "net.ipv6.conf.all.disable_ipv6 = 0" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
    info "IPv6 已启用"
    pause
}

disable_ipv6() {
    echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
    sed -i '/^net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
    echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
    info "IPv6 已禁用"
    pause
}

# ================== Docker 清理 ==================
cleanup_docker() {
    echo -e "${GREEN}===== Docker 清理 =====${RESET}"
    echo -e "${YELLOW}1) 删除停止的容器${RESET}"
    echo -e "${YELLOW}2) 删除悬挂镜像${RESET}"
    echo -e "${YELLOW}3) 删除未使用的卷${RESET}"
    echo -e "${YELLOW}4) 一键全部清理${RESET}"
    echo -e "${YELLOW}0) 返回主菜单${RESET}"
    read -rp "请选择: " clean_choice
    case $clean_choice in
        1) docker container prune -f; pause ;;
        2) docker image prune -f; pause ;;
        3) docker volume prune -f; pause ;;
        4) docker system prune -af --volumes; pause ;;
        0) return ;;
        *) warn "无效选项"; pause ;;
    esac
    cleanup_docker
}

# ================== 网络管理 ==================
network_menu() {
    echo -e "${GREEN}===== 网络管理 =====${RESET}"
    echo -e "${GREEN}1) 查看 Docker 网络${RESET}"
    echo -e "${GREEN}2) 删除 Docker 网络${RESET}"
    echo -e "${GREEN}0) 返回主菜单${RESET}"
    read -rp "请选择: " n_choice
    case $n_choice in
        1) docker network ls; pause ;;
        2) read -rp "网络名称: " net; [ -n "$net" ] && docker network rm "$net"; pause ;;
        0) return ;;
        *) warn "无效选项"; pause ;;
    esac
    network_menu
}

# ================== 开放所有端口 ==================
open_all_ports() {
    info "开放所有端口（仅 IPv4）..."
    iptables -F
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    info "所有端口已开放"
    pause
}

# ================== iptables 切换 ==================
switch_iptables_legacy() {
    if apk info | grep -q "iptables"; then
        apk add iptables-legacy --update
        update-alternatives --set iptables /usr/sbin/iptables-legacy
        info "已切换到 iptables-legacy"
    else
        warn "iptables 未安装"
    fi
    pause
}

switch_iptables_nft() {
    if apk info | grep -q "iptables"; then
        apk add iptables-nft --update
        update-alternatives --set iptables /usr/sbin/iptables-nft
        info "已切换到 iptables-nft"
    else
        warn "iptables 未安装"
    fi
    pause
}

# ================== 主菜单 ==================
main_menu() {
    root_use
    while true; do
        clear
        echo -e "\033[36m"
        echo "  ____             _             "
        echo " |  _ \  ___   ___| | _____ _ __ "
        echo " | | |/ _ \ / __| |/ / _ \ '__|"
        echo " | |_| | (_) | (__|   <  __/ |   "
        echo " |____/ \___/ \___|_|\_\___|_|   "
        echo -e "\033[33m🐳 Alpine Docker 管理工具${RESET}"

        if command -v docker &>/dev/null; then
            docker_status=$(docker info &>/dev/null && echo "运行中" || echo "未运行")
            total=$(docker ps -a -q 2>/dev/null | wc -l)
            running=$(docker ps -q 2>/dev/null | wc -l)
            echo -e "🐳${YELLOW}iptables: $(current_iptables) | Docker: $docker_status | 总容器: $total | 运行中: $running${RESET}"
        else
            echo -e "${YELLOW}🐳iptables: $(current_iptables)${RESET}"
        fi

        echo -e "${GREEN}01. 安装/更新 Docker${RESET}"
        echo -e "${GREEN}02. 安装/更新 Docker Compose${RESET}"
        echo -e "${GREEN}03. 卸载 Docker & Compose${RESET}"
        echo -e "${GREEN}04. 容器管理${RESET}"
        echo -e "${GREEN}05. 镜像管理${RESET}"
        echo -e "${GREEN}06. 开启 IPv6${RESET}"
        echo -e "${GREEN}07. 关闭 IPv6${RESET}"
        echo -e "${GREEN}08. 开放所有端口${RESET}"
        echo -e "${GREEN}09. 网络管理${RESET}"
        echo -e "${GREEN}10. 切换 iptables-legacy${RESET}"
        echo -e "${GREEN}11. 切换 iptables-nft${RESET}"
        echo -e "${GREEN}12. Docker 清理${RESET}"
        echo -e "${GREEN}13. 卷管理${RESET}"
        echo -e "${GREEN}15. 重启 Docker${RESET}"
        echo -e "${GREEN}0. 退出${RESET}"

        read -rp "$(echo -e ${GREEN}请选择菜单项 [0-15]: ${RESET})" choice
        case "$choice" in
            1) install_or_update_docker ;;
            2) install_or_update_compose ;;
            3) uninstall_docker_compose ;;
            4) container_menu ;;
            5) image_menu ;;
            6) enable_ipv6 ;;
            7) disable_ipv6 ;;
            8) open_all_ports ;;
            9) network_menu ;;
            10) switch_iptables_legacy ;;
            11) switch_iptables_nft ;;
            12) cleanup_docker ;;
            13) volume_menu ;;
            15) restart_docker ;;
            0) exit 0 ;;
            *) warn "无效选择"; sleep 1 ;;
        esac
    done
}

main_menu
