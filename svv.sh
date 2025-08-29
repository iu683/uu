#!/bin/sh
# =========================================
# Alpine Linux Docker 管理脚本
# =========================================

set -e

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
BOLD="\033[1m"
RESET="\033[0m"

info() { echo -e "${GREEN}[INFO] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
error() { echo -e "${RED}[ERROR] $1${RESET}"; }

pause() {
    echo
    read -p "按回车键返回菜单..." dummy
}

root_use() {
    if [ "$(id -u)" -ne 0 ]; then
        error "请使用 root 用户运行此脚本"
        exit 1
    fi
}

# ================== Docker 功能 ==================
install_docker() {
    info "更新 apk 源..."
    apk update
    apk upgrade

    info "安装 Docker..."
    apk add docker py3-pip curl

    info "安装 Docker Compose V2..."
    COMPOSE_LATEST=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    curl -L "https://github.com/docker/compose/releases/download/v$COMPOSE_LATEST/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose

    info "设置 Docker 开机自启..."
    rc-update add docker boot

    info "启动 Docker 服务..."
    service docker start

    info "验证安装..."
    docker version
    docker-compose version
    pause
}

update_docker() {
    info "更新 apk 源..."
    apk update
    apk upgrade

    info "更新 Docker..."
    apk add --upgrade docker

    info "更新 Docker Compose V2..."
    COMPOSE_LATEST=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    curl -L "https://github.com/docker/compose/releases/download/v$COMPOSE_LATEST/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose

    info "重启 Docker 服务..."
    service docker restart

    info "更新完成"
    docker version
    docker-compose version
    pause
}

uninstall_docker() {
    info "停止 Docker 服务..."
    service docker stop || true

    info "卸载 Docker 和 Docker Compose..."
    apk del docker py3-pip
    rm -f /usr/local/bin/docker-compose

    info "移除开机自启..."
    rc-update del docker

    info "卸载完成"
    pause
}

restart_docker() {
    info "重启 Docker 服务..."
    service docker restart
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
    read -p "请选择: " c_choice
    case $c_choice in
        1)
            docker ps -a
            pause
            ;;
        2)
            read -p "容器名称/ID: " cid
            [ -n "$cid" ] && docker start "$cid" && info "容器 $cid 已启动" || warn "容器名称或ID不能为空"
            pause
            ;;
        3)
            read -p "容器名称/ID: " cid
            [ -n "$cid" ] && docker stop "$cid" && info "容器 $cid 已停止" || warn "容器名称或ID不能为空"
            pause
            ;;
        4)
            read -p "容器名称/ID: " cid
            if [ -n "$cid" ]; then
                [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" = "true" ] && docker stop "$cid"
                docker rm "$cid"
                info "容器 $cid 已删除"
            else
                warn "容器名称或ID不能为空"
            fi
            pause
            ;;
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
    read -p "请选择: " i_choice
    case $i_choice in
        1) docker images; pause ;;
        2) read -p "镜像名称: " img; docker pull "$img"; pause ;;
        3) read -p "镜像名称/ID: " img; docker rmi "$img"; pause ;;
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
    read -p "请选择: " v_choice
    case $v_choice in
        1) docker volume ls; pause ;;
        2) read -p "卷名称: " vol; docker volume rm "$vol"; pause ;;
        0) return ;;
        *) warn "无效选项"; pause ;;
    esac
    volume_menu
}

# ================== IPv6 开关 ==================
ipv6_menu() {
    while true; do
        IPV6_STATUS=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)
        CURRENT_STATUS=$([ "$IPV6_STATUS" -eq 0 ] && echo "启用" || echo "禁用")
        echo -e "${GREEN}===== IPv6 设置 =====${RESET}"
        echo -e "${YELLOW}当前 IPv6 状态: $CURRENT_STATUS${RESET}"
        echo -e "${GREEN}1) 启用 IPv6${RESET}"
        echo -e "${GREEN}2) 禁用 IPv6${RESET}"
        echo -e "${GREEN}0) 返回主菜单${RESET}"
        read -p "请选择: " ip_choice
        case $ip_choice in
            1) echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6
               grep -q "^net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.all.disable_ipv6 = 0" >> /etc/sysctl.conf
               sysctl -p >/dev/null 2>&1 || true
               info "IPv6 已启用"; pause ;;
            2) echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
               grep -q "^net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
               sysctl -p >/dev/null 2>&1 || true
               info "IPv6 已禁用"; pause ;;
            0) break ;;
            *) warn "无效选项" ;;
        esac
    done
}

# ================== 开放所有端口 ==================
open_all_ports() {
    info "开放所有 TCP/UDP 端口..."
    iptables -F
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    info "已开放所有端口"
    pause
}

# ================== Docker 清理 ==================
cleanup_docker() {
    docker system prune -af --volumes
    info "已清理所有未使用容器/镜像/卷"
    pause
}


# ================== 主菜单 ==================
main_menu() {
    root_use
    while true; do
        clear
        if command -v docker >/dev/null 2>&1; then
            docker_status=$(docker info >/dev/null 2>&1 && echo "运行中" || echo "未运行")
            total_containers=$(docker ps -a -q 2>/dev/null | wc -l)
            running_containers=$(docker ps -q 2>/dev/null | wc -l)
        else
            docker_status="未安装"
            total_containers=0
            running_containers=0
        fi

        IPV6_STATUS=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)
        ipv6_display=$([ "$IPV6_STATUS" -eq 0 ] && echo "启用" || echo "禁用")

        echo -e "${GREEN}====== Alpine Docker 管理 ======${RESET}"
        echo -e "${YELLOW}Docker: $docker_status | 容器: $running_containers/$total_containers | IPv6: $ipv6_display${RESET}\n"

        echo -e "${GREEN} 1) 安装/更新 Docker${RESET}"
        echo -e "${GREEN} 2) 安装/更新 Docker Compose${RESET}"
        echo -e "${GREEN} 3) 卸载 Docker & Compose${RESET}"
        echo -e "${GREEN} 4) 容器管理${RESET}"
        echo -e "${GREEN} 5) 镜像管理${RESET}"
        echo -e "${GREEN} 6) 卷管理${RESET}"
        echo -e "${GREEN} 7) IPv6 开关${RESET}"
        echo -e "${GREEN} 8) 开放所有端口${RESET}"
        echo -e "${GREEN} 9) 一键清理 Docker${RESET}"
        echo -e "${GREEN}10) 重启 Docker${RESET}"
        echo -e "${GREEN} 0) 退出${RESET}"
        read -p "请选择: " choice
        case $choice in
            1) install_docker ;;
            2) update_docker ;;
            3) uninstall_docker ;;
            4) container_menu ;;
            5) image_menu ;;
            6) volume_menu ;;
            7) ipv6_menu ;;
            8) open_all_ports ;;
            9) cleanup_docker ;;
            10) restart_docker ;;
            0) exit 0 ;;
            *) warn "无效选项"; pause ;;
        esac
    done
}

main_menu
