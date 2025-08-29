#!/bin/sh
# =========================================
# Alpine Linux Docker 管理脚本
# =========================================

set -e

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
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
            if [ -n "$cid" ]; then
                docker start "$cid"
                info "容器 $cid 已启动"
            else
                warn "容器名称或ID不能为空"
            fi
            pause
            ;;
        3)
            read -p "容器名称/ID: " cid
            if [ -n "$cid" ]; then
                docker stop "$cid"
                info "容器 $cid 已停止"
            else
                warn "容器名称或ID不能为空"
            fi
            pause
            ;;
        4)
            read -p "容器名称/ID: " cid
            if [ -n "$cid" ]; then
                # 自动停止运行中的容器
                if [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" = "true" ]; then
                    info "容器正在运行，先停止容器..."
                    docker stop "$cid"
                fi
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
            1)
                echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6
                if ! grep -q "^net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf 2>/dev/null; then
                    echo "net.ipv6.conf.all.disable_ipv6 = 0" >> /etc/sysctl.conf
                else
                    sed -i 's/^net.ipv6.conf.all.disable_ipv6.*/net.ipv6.conf.all.disable_ipv6 = 0/' /etc/sysctl.conf
                fi
                sysctl -p >/dev/null 2>&1 || true
                info "IPv6 已启用（永久生效）"
                pause
                ;;
            2)
                echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
                if ! grep -q "^net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf 2>/dev/null; then
                    echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
                else
                    sed -i 's/^net.ipv6.conf.all.disable_ipv6.*/net.ipv6.conf.all.disable_ipv6 = 1/' /etc/sysctl.conf
                fi
                sysctl -p >/dev/null 2>&1 || true
                info "IPv6 已禁用（永久生效）"
                pause
                ;;
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

# ================== Docker 备份/恢复 ==================
docker_backup_restore() {
    root_use
    while true; do
        clear
        echo -e "${BOLD}${CYAN}===== Docker 备份与恢复 =====${RESET}"
        echo -e "${GREEN}1. 备份 Docker${RESET}"
        echo -e "${GREEN}2. 恢复 Docker${RESET}"
        echo -e "${GREEN}3. 删除备份文件${RESET}"
        echo -e "${GREEN}0. 返回上一级菜单${RESET}"
        read -p "请选择: " choice
        case $choice in
            1)
                # 备份类型选择
                while true; do
                    echo -e "${YELLOW}选择备份类型:${RESET}"
                    echo "1. 容器"
                    echo "2. 镜像"
                    echo "3. 卷"
                    echo "4. 全量"
                    echo "0. 返回上一级"
                    read -p "请输入选择: " btype
                    [[ "$btype" == "0" ]] && break  # 返回上一级备份菜单

                    read -p "请输入备份文件名（默认 docker_backup_$(date +%F).tar.gz）: " backup_name
                    backup_name=${backup_name:-docker_backup_$(date +%F).tar.gz}
                    mkdir -p /tmp/docker_backup

                    [[ "$btype" == "1" || "$btype" == "4" ]] && {
                        docker ps -a -q | while read cid; do
                            cname=$(docker inspect --format '{{.Name}}' $cid | sed 's/\///g')
                            docker inspect $cid > /tmp/docker_backup/container_"$cname".json
                            docker export "$cid" -o /tmp/docker_backup/container_"$cname".tar
                        done
                    }

                    [[ "$btype" == "2" || "$btype" == "4" ]] && {
                        docker images -q | while read img; do
                            iname=$(docker image inspect --format '{{.RepoTags}}' $img | tr -d '[]/:')
                            docker save "$img" -o /tmp/docker_backup/image_"$iname".tar
                        done
                    }

                    [[ "$btype" == "3" || "$btype" == "4" ]] && {
                        docker volume ls -q | while read vol; do
                            tar -czf /tmp/docker_backup/volume_"$vol".tar.gz -C /var/lib/docker/volumes/"$vol"/_data .
                        done
                    }

                    tar -czf "$backup_name" -C /tmp docker_backup
                    rm -rf /tmp/docker_backup
                    echo -e "${GREEN}备份完成: $backup_name${RESET}"
                    read -p "按回车继续..."
                    break
                done
                ;;
            2)
                # 恢复类型选择
                while true; do
                    echo -e "${YELLOW}选择恢复类型:${RESET}"
                    echo "1. 容器"
                    echo "2. 镜像"
                    echo "3. 卷"
                    echo "4. 全量"
                    echo "0. 返回上一级"
                    read -p "请输入选择: " rtype
                    [[ "$rtype" == "0" ]] && break  # 返回上一级恢复菜单

                    read -p "请输入备份文件路径: " backup_file
                    [[ ! -f "$backup_file" ]] && echo -e "${RED}备份文件不存在${RESET}" && read -p "按回车继续..." && continue
                    mkdir -p /tmp/docker_restore
                    tar -xzf "$backup_file" -C /tmp/docker_restore

                    [[ "$rtype" == "1" || "$rtype" == "4" ]] && {
                        for cjson in /tmp/docker_restore/docker_backup/container_*.json; do
                            [[ -f "$cjson" ]] || continue
                            cname=$(basename "$cjson" | sed 's/container_\(.*\).json/\1/')
                            image=$(jq -r '.[0].Config.Image' "$cjson")
                            envs=$(jq -r '.[0].Config.Env | join(" -e ")' "$cjson")
                            ports=$(jq -r '.[0].HostConfig.PortBindings | to_entries | map("\(.value[0].HostPort):\(.key | split("/")[0])") | join(" -p ")' "$cjson")
                            mounts=$(jq -r '.[0].Mounts | map("-v \(.Source):\(.Destination)") | join(" ")' "$cjson")
                            network=$(jq -r '.[0].HostConfig.NetworkMode' "$cjson")
                            cmd="docker run -d --name $cname -e $envs -p $ports $mounts --network $network $image"
                            echo "正在创建容器: $cname"
                            eval $cmd
                        done
                    }

                    [[ "$rtype" == "2" || "$rtype" == "4" ]] && {
                        for img in /tmp/docker_restore/docker_backup/image_*.tar; do
                            [[ -f "$img" ]] || continue
                            docker load -i "$img"
                        done
                    }

                    [[ "$rtype" == "3" || "$rtype" == "4" ]] && {
                        for vol in /tmp/docker_restore/docker_backup/volume_*.tar.gz; do
                            [[ -f "$vol" ]] || continue
                            vol_name=$(basename "$vol" | sed 's/volume_\(.*\).tar.gz/\1/')
                            docker volume create "$vol_name"
                            tar -xzf "$vol" -C /var/lib/docker/volumes/"$vol_name"/_data
                        done
                    }

                    rm -rf /tmp/docker_restore
                    echo -e "${GREEN}恢复完成${RESET}"
                    read -p "按回车继续..."
                    break
                done
                ;;
            3)
                # 删除备份文件
                while true; do
                    read -p "请输入要删除的备份文件路径（输入0返回上一级）: " del_file
                    [[ "$del_file" == "0" ]] && break
                    [[ -f "$del_file" ]] && rm -f "$del_file" && echo -e "${GREEN}备份文件已删除${RESET}" || echo -e "${RED}备份文件不存在${RESET}"
                    read -p "按回车继续..."
                    break
                done
                ;;
            0) break ;;
            *) echo "无效选择"; read -p "按回车继续..." ;;
        esac
    done
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

        echo -e "${GREEN}1)  安装/更新 Docker${RESET}"
        echo -e "${GREEN}2)  安装/更新 Docker Compose${RESET}"
        echo -e "${GREEN}3)  卸载 Docker & Compose${RESET}"
        echo -e "${GREEN}4)  容器管理${RESET}"
        echo -e "${GREEN}5)  镜像管理${RESET}"
        echo -e "${GREEN}6)  卷管理${RESET}"
        echo -e "${GREEN}7)  IPv6 开关${RESET}"
        echo -e "${GREEN}8)  开放所有端口${RESET}"
        echo -e "${GREEN}9)  一键清理 Docker${RESET}"
        echo -e "${GREEN}10) Docker 备份/恢复${RESET}"
        echo -e "${GREEN}11) 重启 Docker${RESET}"
        echo -e "${GREEN}0)  退出${RESET}"
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
            10) docker_backup_restore ;;
            11) restart_docker ;;
            0) exit 0 ;;
            *) warn "无效选项"; pause ;;
        esac
    done
}

main_menu
