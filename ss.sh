#!/bin/bash
# ========================================
# 🐳 Alpine Linux 专用一键 VPS Docker 管理工具
# ========================================

# -----------------------------
# 颜色
# -----------------------------
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
BOLD="\033[1m"
RESET="\033[0m"
BLUE="\033[34m"

# -----------------------------
# 检查 root
# -----------------------------
root_use() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}请使用 root 用户运行脚本${RESET}"
        exit 1
    fi
}

# -----------------------------
# 重启 Docker 并恢复容器端口映射
# -----------------------------
restart_docker() {
    root_use
    echo -e "${YELLOW}正在重启 Docker...${RESET}"

    if [ -f /etc/init.d/docker ]; then
        rc-service docker restart
    else
        pkill dockerd 2>/dev/null
        nohup dockerd >/dev/null 2>&1 &
        sleep 5
    fi

    if docker info &>/dev/null; then
        echo -e "${GREEN}✅ Docker 已成功重启${RESET}"
        containers=$(docker ps -a -q)
        if [ -n "$containers" ]; then
            echo -e "${CYAN}正在重启所有容器以恢复端口映射...${RESET}"
            docker restart $containers
            echo -e "${GREEN}✅ 所有容器已重启并恢复端口映射${RESET}"
        else
            echo -e "${YELLOW}没有容器需要重启${RESET}"
        fi
    else
        echo -e "${RED}❌ Docker 重启失败，请检查日志${RESET}"
    fi
}

# -----------------------------
# 检测 Docker 是否安装并运行
# -----------------------------
check_docker_running() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}❌ Docker 未安装，请先安装 Docker${RESET}"
        return 1
    fi
    if ! docker info &>/dev/null; then
        echo -e "${YELLOW} Docker 未运行，尝试启动...${RESET}"
        if [ -f /etc/init.d/docker ]; then
            rc-service docker start
        else
            nohup dockerd >/dev/null 2>&1 &
            sleep 5
        fi
    fi
    if ! docker info &>/dev/null; then
        echo -e "${RED}❌ Docker 启动失败，请检查日志${RESET}"
        return 1
    fi
    return 0
}

# -----------------------------
# 自动检测国内/国外
# -----------------------------
detect_country() {
    local country=$(curl -s --max-time 5 ipinfo.io/country)
    if [[ "$country" == "CN" ]]; then
        echo "CN"
    else
        echo "OTHER"
    fi
}

# -----------------------------
# 安装/更新 Docker (Alpine 专用)
# -----------------------------
docker_install_update() {
    root_use
    echo -e "${CYAN}正在为 Alpine Linux 安装/更新 Docker...${RESET}"
    
    # 确保启用 community 仓库（Docker 在该仓库中）
    if ! grep -q "community" /etc/apk/repositories; then
        local alpine_ver=$(cut -d. -f1,2 /etc/alpine-release)
        echo "http://dl-cdn.alpinelinux.org/alpine/v${alpine_ver}/community" >> /etc/apk/repositories
    fi

    apk update
    # Alpine 下的 docker 需要同时安装 docker-cli
    apk add docker docker-cli docker-cli-compose bash curl jq grep

    local country=$(detect_country)
    echo -e "${CYAN}检测到国家: $country${RESET}"
    if [ "$country" = "CN" ]; then
        echo -e "${YELLOW}配置国内加速镜像源...${RESET}"
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json << EOF
{
  "registry-mirrors": [
    "https://docker.0.unsee.tech",
    "https://docker.1panel.live",
    "https://registry.dockermirror.com",
    "https://docker.m.daocloud.io"
  ]
}
EOF
    fi

    # 注册 OpenRC 开机自启
    rc-update add docker default
    rc-service docker start
    echo -e "${GREEN}Docker 安装/更新完成并已启动（已设置开机自启）${RESET}"
}

# -----------------------------
# 卸载 Docker
# -----------------------------
docker_uninstall() {
    root_use
    echo -e "${RED}正在卸载 Docker 和 Docker Compose...${RESET}"
    
    rc-service docker stop 2>/dev/null
    rc-update del docker default 2>/dev/null
    pkill dockerd 2>/dev/null

    apk del docker docker-cli docker-compose 2>/dev/null || true
    rm -f /usr/local/bin/docker-compose

    rm -rf /var/lib/docker /etc/docker /var/run/docker.sock
    echo -e "${GREEN}Docker 和 Docker Compose 已卸载干净${RESET}"
}

# -----------------------------
# Docker Compose 安装/更新
# -----------------------------
docker_compose_install_update() {
    root_use
    echo -e "${CYAN}正在安装/更新 Docker Compose...${RESET}"
    
    # 优先尝试通过 apk 安装官方最新的 docker-compose 插件/包
    if ! grep -q "community" /etc/apk/repositories; then
        local alpine_ver=$(cut -d. -f1,2 /etc/alpine-release)
        echo "http://dl-cdn.alpinelinux.org/alpine/v${alpine_ver}/community" >> /etc/apk/repositories
        apk update
    fi
    apk add jq curl
    
    local latest=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    latest=${latest:-"v2.30.0"}
    
    # 转换为 Alpine (musl) 兼容的架构名
    local arch=$(uname -m)
    curl -L "https://github.com/docker/compose/releases/download/$latest/docker-compose-$(uname -s)-$arch" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    
    echo -e "${GREEN}Docker Compose 已安装/更新到版本 $latest${RESET}"
}

# -----------------------------
# Docker IPv6
# -----------------------------
docker_ipv6_on() {
    root_use
    mkdir -p /etc/docker
    if [ -f /etc/docker/daemon.json ]; then
        jq '. + {ipv6:true,"fixed-cidr-v6":"fd00::/64"}' /etc/docker/daemon.json 2>/dev/null \
            >/etc/docker/daemon.json.tmp || \
            echo '{"ipv6":true,"fixed-cidr-v6":"fd00::/64"}' > /etc/docker/daemon.json.tmp
    else
        echo '{"ipv6":true,"fixed-cidr-v6":"fd00::/64"}' > /etc/docker/daemon.json.tmp
    fi
    mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
    restart_docker
    echo -e "${GREEN}✅ Docker IPv6 已开启${RESET}"
}

docker_ipv6_off() {
    root_use
    if [ -f /etc/docker/daemon.json ]; then
        jq 'del(.ipv6) | del(.["fixed-cidr-v6"])' /etc/docker/daemon.json \
            >/etc/docker/daemon.json.tmp 2>/dev/null || \
            cp /etc/docker/daemon.json /etc/docker/daemon.json.tmp
        mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
        restart_docker
        echo -e "${GREEN}✅ Docker IPv6 已关闭${RESET}"
    else
        echo -e "${YELLOW} Docker 配置文件不存在，无法关闭 IPv6${RESET}"
    fi
}

# -----------------------------
# 开放所有端口（支持 Alpine iptables/nftables）
# -----------------------------
open_all_ports() {
    root_use
    read -p "确认要开放所有端口吗？(Y/N): " confirm
    [[ $confirm =~ [Yy] ]] || { echo -e "${YELLOW}操作已取消${RESET}"; return; }
    echo -e "${YELLOW}正在清理防火墙规则...${RESET}"

    if command -v iptables &>/dev/null; then
        iptables -P INPUT ACCEPT 2>/dev/null
        iptables -P FORWARD ACCEPT 2>/dev/null
        iptables -P OUTPUT ACCEPT 2>/dev/null
        iptables -F 2>/dev/null
    fi
    if command -v ip6tables &>/dev/null; then
        ip6tables -P INPUT ACCEPT 2>/dev/null
        ip6tables -P FORWARD ACCEPT 2>/dev/null
        ip6tables -P OUTPUT ACCEPT 2>/dev/null
        ip6tables -F 2>/dev/null
    fi
    if command -v nft &>/dev/null; then
        nft flush ruleset 2>/dev/null || true
    fi
    # 如果装了 Alpine ufw 或 awall
    rc-service ufw stop 2>/dev/null
    rc-service ip tables stop 2>/dev/null
    
    echo -e "${GREEN}✅ 已关闭可能冲突的独立防火墙服务并开放基本端口${RESET}"
    restart_docker
}

# -----------------------------
# Alpine iptables 软链接切换逻辑
# -----------------------------
switch_iptables_legacy() {
    root_use
    if [ -f /sbin/iptables-legacy ] || [ -f /usr/sbin/iptables-legacy ]; then
        # 备份规则
        command -v iptables-save &>/dev/null && iptables-save > /tmp/iptables_v4.bak
        
        # Alpine 修改软链接
        ln -sf /sbin/iptables-legacy /sbin/iptables 2>/dev/null || ln -sf /usr/sbin/iptables-legacy /usr/sbin/iptables
        ln -sf /sbin/ip6tables-legacy /sbin/ip6tables 2>/dev/null || ln -sf /usr/sbin/ip6tables-legacy /usr/sbin/ip6tables
        
        restart_docker
        [ -f /tmp/iptables_v4.bak ] && command -v iptables-restore &>/dev/null && iptables-restore < /tmp/iptables_v4.bak
        echo -e "${GREEN}✅ Alpine 已成功切换到 iptables-legacy${RESET}"
    else
        # 如果未安装，帮用户安装
        echo -e "${YELLOW}未检测到 legacy 组件，正在安装 iptables 传统包...${RESET}"
        apk add iptables
        switch_iptables_legacy
    fi
}

switch_iptables_nft() {
    root_use
    if [ -f /sbin/iptables-nft ] || [ -f /usr/sbin/iptables-nft ]; then
        command -v iptables-save &>/dev/null && iptables-save > /tmp/iptables_v4.bak
        
        ln -sf /sbin/iptables-nft /sbin/iptables 2>/dev/null || ln -sf /usr/sbin/iptables-nft /usr/sbin/iptables
        ln -sf /sbin/ip6tables-nft /sbin/ip6tables 2>/dev/null || ln -sf /usr/sbin/ip6tables-nft /usr/sbin/ip6tables
        
        restart_docker
        [ -f /tmp/iptables_v4.bak ] && command -v iptables-restore &>/dev/null && iptables-restore < /tmp/iptables_v4.bak
        echo -e "${GREEN}✅ Alpine 已成功切换到 iptables-nft${RESET}"
    else
        echo -e "${YELLOW}未检测到 nft 组件，正在安装 nftables 包...${RESET}"
        apk add nftables iptables-nft
        switch_iptables_nft
    fi
}

# -----------------------------
# 状态查询
# -----------------------------
docker_status() {
    if docker info &>/dev/null; then
        echo "运行中"
    else
        echo "未运行"
    fi
}

current_iptables() {
    if [ -L /sbin/iptables ]; then
        local link=$(readlink /sbin/iptables)
        if [[ $link == *legacy* ]]; then
            echo "legacy"
        else
            echo "nft"
        fi
    else
        echo "未知 (未设置软链接)"
    fi
}

# -----------------------------
# Docker 容器管理
# -----------------------------
docker_ps() {
    if ! check_docker_running; then return; fi
    while true; do
        clear
        echo -e "${BOLD}${CYAN}===== Docker 容器管理 =====${RESET}"
        docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo -e "${GREEN}01. 创建新容器${RESET}"
        echo -e "${GREEN}02. 启动容器${RESET}"
        echo -e "${GREEN}03. 停止容器${RESET}"
        echo -e "${GREEN}04. 删除容器${RESET}"
        echo -e "${GREEN}05. 重启容器${RESET}"
        echo -e "${GREEN}06. 启动所有容器${RESET}"
        echo -e "${GREEN}07. 停止所有容器${RESET}"
        echo -e "${GREEN}08. 删除所有容器${RESET}"
        echo -e "${GREEN}09. 重启所有容器${RESET}"
        echo -e "${GREEN}10. 进入容器${RESET}"
        echo -e "${GREEN}11. 查看日志${RESET}"
        echo -e "${GREEN} 0. 返回主菜单${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
        case $choice in
            01|1) read -p "请输入创建命令: " cmd; $cmd ;;
            02|2) read -p "请输入容器名: " name; docker start $name ;;
            03|3) read -p "请输入容器名: " name; docker stop $name ;;
            04|4) read -p "请输入容器名: " name; docker rm -f $name ;;
            05|5) read -p "请输入容器名: " name; docker restart $name ;;
            06|6) containers=$(docker ps -a -q); [ -n "$containers" ] && docker start $containers || echo "无容器可启动" ;;
            07|7) containers=$(docker ps -q); [ -n "$containers" ] && docker stop $containers || echo "无容器正在运行" ;;
            08|8) read -p "确定删除所有容器? (Y/N): " c; [[ $c =~ [Yy] ]] && docker rm -f $(docker ps -a -q) ;;
            09|9) containers=$(docker ps -q); [ -n "$containers" ] && docker restart $containers || echo "无容器正在运行" ;;
            10) read -p "请输入容器名: " name; docker exec -it $name /bin/sh ;; # Alpine环境多用sh
            11) read -p "请输入容器名: " name; docker logs -f $name ;;
            0) break ;;
            *) echo -e "${RED}无效选择${RESET}" ;;
        esac
        read -p "$(echo -e ${GREEN}按回车继续...${RESET})"
    done
}

# -----------------------------
# Docker 镜像管理
# -----------------------------
docker_image() {
    if ! check_docker_running; then return; fi
    while true; do
        clear
        echo -e "${BOLD}${CYAN}===== Docker 镜像管理 =====${RESET}"
        docker image ls
        echo -e "${GREEN}01. 拉取镜像${RESET}"
        echo -e "${GREEN}02. 更新镜像${RESET}"
        echo -e "${GREEN}03. 删除镜像${RESET}"
        echo -e "${GREEN}04. 删除所有镜像${RESET}"
        echo -e "${GREEN} 0. 返回主菜单${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
        case $choice in
            01|1) read -p "请输入镜像名: " imgs; for img in $imgs; do docker pull $img; done ;;
            02|2) read -p "请输入镜像名: " imgs; for img in $imgs; do docker pull $img; done ;;
            03|3) read -p "请输入镜像名: " imgs; for img in $imgs; do docker rmi -f $img; done ;;
            04|4) read -p "确定删除所有镜像? (Y/N): " c; [[ $c =~ [Yy] ]] && docker rmi -f $(docker images -q) ;;
            0) break ;;
            *) echo -e "${RED}无效选择${RESET}" ;;
        esac
        read -p "$(echo -e ${GREEN}按回车继续...${RESET})"
    done
}

# -----------------------------
# Docker 卷管理
# -----------------------------
docker_volume() {
    if ! check_docker_running; then return; fi
    while true; do
        clear
        echo -e "${BOLD}${CYAN}===== Docker 卷管理 =====${RESET}"
        docker volume ls
        echo -e "${GREEN}1. 创建卷${RESET}"
        echo -e "${GREEN}2. 删除卷${RESET}"
        echo -e "${GREEN}3. 删除所有无用卷${RESET}"
        echo -e "${GREEN}0. 返回上一级菜单${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
        case $choice in
            1) read -p "请输入卷名: " v; docker volume create $v ;;
            2) read -p "请输入卷名: " v; docker volume rm $v ;;
            3) docker volume prune -f ;;
            0) break ;;
            *) echo -e "${RED}无效选择${RESET}" ;;
        esac
        read -p "$(echo -e ${GREEN}按回车继续...${RESET})"
    done
}

# -----------------------------
# 清理所有未使用资源
# -----------------------------
docker_cleanup() {
    root_use
    echo -e "${YELLOW}清理所有未使用容器、镜像、卷...${RESET}"
    docker system prune -af --volumes
    echo -e "${GREEN}清理完成${RESET}"
}

# -----------------------------
# Docker 网络管理
# -----------------------------
docker_network() {
    if ! check_docker_running; then return; fi
    while true; do
        clear
        echo -e "${BOLD}${CYAN}===== Docker 网络管理 =====${RESET}"
        docker network ls
        echo -e "${GREEN}1. 创建网络${RESET}"
        echo -e "${GREEN}2. 加入网络${RESET}"
        echo -e "${GREEN}3. 退出网络${RESET}"
        echo -e "${GREEN}4. 删除网络${RESET}"
        echo -e "${GREEN}0. 返回上一级菜单${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " sub_choice
        case $sub_choice in
            1) read -p "设置新网络名: " dockernetwork; docker network create $dockernetwork ;;
            2) read -p "加入网络名: " dockernetwork; read -p "容器名: " dockername; docker network connect $dockernetwork $dockername ;;
            3) read -p "退出网络名: " dockernetwork; read -p "容器名: " dockername; docker network disconnect $dockernetwork $dockername ;;
            4) read -p "请输入要删除的网络名: " dockernetwork; docker network rm $dockernetwork || echo -e "${RED}删除失败，网络可能被容器占用${RESET}" ;;
            0) break ;;
            *) echo -e "${RED}无效选择${RESET}" ;;
        esac
        read -p "$(echo -e ${GREEN}按回车继续...${RESET})"
    done
}

# -----------------------------
# Docker 备份/恢复菜单 (Alpine 优化版)
# -----------------------------
docker_backup_menu() {
    root_use

    BACKUP_DIR="/opt/docker_backups"
    LOG_FILE="$BACKUP_DIR/backup.log"
    mkdir -p "$BACKUP_DIR"

    # 用 apk 检查依赖
    if ! command -v jq &>/dev/null || ! command -v tar &>/dev/null; then
        echo -e "${YELLOW}正在 Alpine 下配置基础依赖 (jq, tar)...${RESET}"
        apk add jq tar gzip curl
    fi

    # 检查空间 (Alpine BusyBox 的 df 不支持 --output)
    local avail_space=$(df -k "$BACKUP_DIR" | tail -1 | awk '{print $4}')
    if (( avail_space < 1048576 )); then
        echo -e "${RED}磁盘剩余空间不足 1GB，无法执行备份！${RESET}"
        read -p "$(echo -e ${GREEN}按回车返回菜单...${RESET})"
        return
    fi

    while true; do
        clear
        echo -e "${BOLD}${CYAN}===== Docker Run备份与恢复 =====${RESET}"
        echo -e "${GREEN}1. 备份 Docker${RESET}"
        echo -e "${GREEN}2. 恢复 Docker${RESET}"
        echo -e "${GREEN}3. 删除备份文件${RESET}"
        echo -e "${GREEN}0. 返回上一级菜单${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
        case $choice in
            1)
                while true; do
                    echo -e "${YELLOW}选择备份类型:${RESET}"
                    echo -e "${GREEN}1. 容器${RESET}"
                    echo -e "${GREEN}2. 镜像${RESET}"
                    echo -e "${GREEN}3. 卷${RESET}"
                    echo -e "${GREEN}4. 全量${RESET}"
                    echo -e "${GREEN}0. 返回上一级${RESET}"
                    read -p "$(echo -e ${GREEN}请选择:${RESET}) " btype
                    [[ "$btype" == "0" ]] && break

                    read -p "请输入备份文件名（默认 docker_backup_$(date +%F).tar.gz）: " backup_name
                    backup_name=${backup_name:-docker_backup_$(date +%F).tar.gz}
                    backup_path="$BACKUP_DIR/$backup_name"

                    TMP_BACKUP_DIR=$(mktemp -d /tmp/docker_backup_XXXX)

                    # --- 容器备份 ---
                    if [[ "$btype" == "1" || "$btype" == "4" ]]; then
                        echo "可用容器列表："
                        docker ps -a --format "{{.Names}}"
                        read -p "请输入要备份的容器名（多个用空格，留空则全部）: " selected_containers
                        [[ -z "$selected_containers" ]] && selected_containers=$(docker ps -a --format "{{.Names}}")
                        for cname in $selected_containers; do
                            cid=$(docker ps -a -q -f name="^${cname}$")
                            [[ -z "$cid" ]] && echo "容器 $cname 不存在，跳过" && continue
                            docker inspect $cid > "$TMP_BACKUP_DIR/container_${cname}.json"
                            docker export "$cid" -o "$TMP_BACKUP_DIR/container_${cname}.tar"
                            echo "$(date '+%F %T') 备份容器 $cname 完成" >> "$LOG_FILE"
                        done
                    fi

                    # --- 镜像备份 ---
                    if [[ "$btype" == "2" || "$btype" == "4" ]]; then
                        echo "可用镜像列表："
                        docker images --format "{{.Repository}}:{{.Tag}}"
                        read -p "请输入要备份的镜像（多个用空格，留空则全部）: " selected_images
                        [[ -z "$selected_images" ]] && selected_images=$(docker images --format "{{.Repository}}:{{.Tag}}")
                        for iname in $selected_images; do
                            [[ "$iname" == "<none>:<none>" ]] && continue
                            safe_name=$(echo "$iname" | tr '/:' '_')
                            docker save "$iname" -o "$TMP_BACKUP_DIR/image_${safe_name}.tar"
                            echo "$(date '+%F %T') 备份镜像 $iname 完成" >> "$LOG_FILE"
                        done
                    fi

                    # --- 卷备份 ---
                    if [[ "$btype" == "3" || "$btype" == "4" ]]; then
                        echo "可用卷列表："
                        docker volume ls -q
                        read -p "请输入要备份的卷名（多个用空格，留空则全部）: " selected_volumes
                        [[ -z "$selected_volumes" ]] && selected_volumes=$(docker volume ls -q)
                        for vol in $selected_volumes; do
                            [[ ! -d /var/lib/docker/volumes/"$vol"/_data ]] && echo "卷 $vol 不存在，跳过" && continue
                            tar -czf "$TMP_BACKUP_DIR/volume_${vol}.tar.gz" -C /var/lib/docker/volumes/"$vol"/_data .
                            echo "$(date '+%F %T') 备份卷 $vol 完成" >> "$LOG_FILE"
                        done
                    fi

                    tar -czf "$backup_path" -C "$TMP_BACKUP_DIR" .
                    rm -rf "$TMP_BACKUP_DIR"
                    echo -e "${GREEN}备份完成: $backup_path${RESET}"
                    read -p "$(echo -e ${GREEN}按回车继续...${RESET})"
                    break
                done
                ;;
            2)
                while true; do
                    echo -e "${YELLOW}选择恢复类型:${RESET}"
                    echo -e "${GREEN}1. 容器${RESET}"
                    echo -e "${GREEN}2. 镜像${RESET}"
                    echo -e "${GREEN}3. 卷${RESET}"
                    echo -e "${GREEN}4. 全量${RESET}"
                    echo -e "${GREEN}0. 返回上一级${RESET}"
                    read -p "$(echo -e ${GREEN}请选择:${RESET}) " rtype
                    [[ "$rtype" == "0" ]] && break

                    read -p "请输入备份文件路径: " backup_file
                    [[ ! -f "$backup_file" ]] && echo -e "${RED}备份文件不存在${RESET}" && read -p "按回车继续..." && continue

                    TMP_RESTORE_DIR=$(mktemp -d /tmp/docker_restore_XXXX)
                    tar -xzf "$backup_file" -C "$TMP_RESTORE_DIR"

                    # --- 容器恢复 ---
                    if [[ "$rtype" == "1" || "$rtype" == "4" ]]; then
                        for cjson in "$TMP_RESTORE_DIR"/container_*.json; do
                            [ ! -f "$cjson" ] && continue
                            cname=$(basename "$cjson" | sed 's/container_\(.*\).json/\1/')
                            image=$(jq -r '.[0].Config.Image' "$cjson")
                            envs=$(jq -r '.[0].Config.Env | join(" -e ")' "$cjson")
                            [[ -n "$envs" ]] && envs="-e $envs"
                            ports=$(jq -r '.[0].HostConfig.PortBindings | to_entries | map("\(.value[0].HostPort):\(.key)") | join(" -p ")' "$cjson")
                            [[ -n "$ports" ]] && ports="-p $ports"
                            mounts=$(jq -r '.[0].Mounts | map("-v \(.Source):\(.Destination)") | join(" ")' "$cjson")
                            network=$(jq -r '.[0].HostConfig.NetworkMode' "$cjson")

                            # 如果镜像不存在，尝试从备份加载
                            safe_image_name=$(echo "$image" | tr '/:' '_')
                            img_tar="$TMP_RESTORE_DIR/image_${safe_image_name}.tar"
                            [[ -f "$img_tar" ]] && docker load -i "$img_tar"

                            docker run -d --name "$cname" $envs $ports $mounts --network "$network" "$image"
                            echo "$(date '+%F %T') 恢复容器 $cname 完成" >> "$LOG_FILE"
                        done
                    fi

                    # --- 镜像恢复 ---
                    if [[ "$rtype" == "2" || "$rtype" == "4" ]]; then
                        for img_file in "$TMP_RESTORE_DIR"/image_*.tar; do
                            [[ -f "$img_file" ]] && docker load -i "$img_file"
                        done
                    fi

                    # --- 卷恢复 ---
                    if [[ "$rtype" == "3" || "$rtype" == "4" ]]; then
                        for vol_file in "$TMP_RESTORE_DIR"/volume_*.tar.gz; do
                            [ ! -f "$vol_file" ] && continue
                            vol_name=$(basename "$vol_file" | sed 's/volume_\(.*\).tar.gz/\1/')
                            if docker volume inspect "$vol_name" &>/dev/null; then
                                read -p "卷 $vol_name 已存在，是否覆盖? (y/N): " confirm
                                [[ "$confirm" != "y" ]] && continue
                            fi
                            docker volume create "$vol_name" >/dev/null 2>&1
                            tar -xzf "$vol_file" -C /var/lib/docker/volumes/"$vol_name"/_data
                            echo "$(date '+%F %T') 恢复卷 $vol_name 完成" >> "$LOG_FILE"
                        done
                    fi

                    rm -rf "$TMP_RESTORE_DIR"
                    echo -e "${GREEN}恢复完成${RESET}"
                    read -p "$(echo -e ${GREEN}按回车继续...${RESET})"
                    break
                done
                ;;
            3)
                while true; do
                    echo "当前备份目录：$BACKUP_DIR"
                    ls "$BACKUP_DIR"
                    read -p "请输入要删除的备份文件名（支持空格或*通配符，输入0返回）: " del_files
                    [[ "$del_files" == "0" ]] && break
                    cd "$BACKUP_DIR" && rm -f $del_files
                    echo -e "${GREEN}删除完成${RESET}"
                    read -p "$(echo -e ${GREEN}按回车继续...${RESET})"
                    break
                done
                ;;
            0) break ;;
            *) echo -e "${RED}无效选择${RESET}"; read -p "$(echo -e ${GREEN}按回车继续...${RESET})" ;;
        esac
    done
}

# -----------------------------
# 容器监控 (兼容 Alpine BusyBox)
# -----------------------------
monitor_docker_containers() {
    clear
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}        🐳 Docker 容器监控${RESET}"
    echo -e "${GREEN}========================================${RESET}"

    if ! check_docker_running; then return; fi

    docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" | sort -k3 -hr | while IFS=$'\t' read -r name cpu mem net; do
        local raw_status
        raw_status=$(docker ps -a --filter "name=^/${name}$" --format "{{.Status}}")
        
        # 汉化引擎 (BusyBox 兼容)
        local uptime
        uptime=$(echo "$raw_status" | \
            sed 's/Up /运行 /; s/Exited/已停止/; s/(healthy)/(健康)/; s/(unhealthy)/(非健康)/; s/(starting)/(启动中)/; s/seconds/秒/; s/second/秒/; s/minutes/分钟/; s/minute/分钟/; s/hours/小时/; s/hour/小时/; s/days/天/; s/day/天/; s/weeks/周/; s/week/周/; s/months/月/; s/month/月/; s/about //; s/ago/前/')

        echo -e "${YELLOW}◈ 容器: ${RESET}${YELLOW}${name}${RESET}"
        echo -e "  ├─ ${YELLOW}CPU 占用: ${RESET}${cpu}"
        echo -e "  ├─ ${YELLOW}内存使用: ${RESET}${mem}"
        echo -e "  ├─ ${YELLOW}网络 I/O: ${RESET}${net}"
        echo -e "  └─ ${YELLOW}运行状态: ${RESET}${YELLOW}${uptime}${RESET}"
        echo -e "${YELLOW}----------------------------------------${RESET}"
    done
}

# -----------------------------
# 主菜单
# -----------------------------
main_menu() {
    root_use
    while true; do
        clear
        echo -e "\033[36m"
        echo "  ____                                "
        echo " |  _ \  ___   ___| | _____ _ __ "
        echo " | | |/ _ \ / __| |/ / _ \ '__|"
        echo " | |_| | (_) | (__|   <  __/ |   "
        echo " |____/ \___/ \___|_|\_\___|_|   "
        
        if command -v docker &>/dev/null; then
            local d_status=$(docker info &>/dev/null && echo "运行中" || echo "未运行")
            local total=$(docker ps -a -q 2>/dev/null | wc -l)
            local running=$(docker ps -q 2>/dev/null | wc -l)
            echo -e "${YELLOW}🐳| Docker: $d_status | 总容器: $total | 运行中: $running${RESET}"
        else
            echo -e "${YELLOW}🐳| Docker: 未安装 | 防火墙驱动: $(current_iptables)${RESET}"
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
        echo -e "${GREEN}10. 切换至 iptables-legacy${RESET}"
        echo -e "${GREEN}11. 切换至 iptables-nft${RESET}"
        echo -e "${GREEN}12. Docker备份/恢复${RESET}"
        echo -e "${GREEN}13. 卷管理${RESET}"
        echo -e "${GREEN}14. 一键清理所有未使用容器/镜像/卷${RESET}"
        echo -e "${GREEN}15. 重启Docker服务${RESET}"
        echo -e "${GREEN}16. Docker容器实时监控${RESET}"
        echo -e "${GREEN} 0. 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
        case $choice in
            01|1) docker_install_update ;;
            02|2) docker_compose_install_update ;;
            03|3) docker_uninstall ;;
            04|4) check_docker_running && docker_ps ;;
            05|5) check_docker_running && docker_image ;;
            06|6) check_docker_running && docker_ipv6_on ;;
            07|7) check_docker_running && docker_ipv6_off ;;
            08|8) open_all_ports ;;
            09|9) check_docker_running && docker_network ;;
            10) switch_iptables_legacy ;;
            11) switch_iptables_nft ;;
            12) check_docker_running && docker_backup_menu ;;
            13) check_docker_running && docker_volume ;;
            14) check_docker_running && docker_cleanup ;;
            15) check_docker_running && restart_docker ;;
            16) monitor_docker_containers ;;
             0) exit 0 ;;
             *) echo -e "${RED}无效选择${RESET}" ;;
        esac
        read -p "$(echo -e ${GREEN}按回车继续...${RESET})"
    done
}

# 启动
main_menu
