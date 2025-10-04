#!/bin/bash
# ========================================
# 🐳 一键 VPS Docker 管理工具（完整整合版）
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

    if systemctl list-unit-files | grep -q "^docker.service"; then
        systemctl restart docker
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
        if systemctl list-unit-files | grep -q "^docker.service"; then
            systemctl start docker
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
# 安装/更新 Docker
# -----------------------------
docker_install() {
    root_use
    local country=$(detect_country)
    echo -e "${CYAN}检测到国家: $country${RESET}"
    if [ "$country" = "CN" ]; then
        echo -e "${YELLOW}使用国内源安装 Docker...${RESET}"
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
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
    else
        echo -e "${YELLOW}使用官方源安装 Docker...${RESET}"
        curl -fsSL https://get.docker.com | sh
    fi
    systemctl enable docker
    systemctl start docker
    echo -e "${GREEN}Docker 安装完成并已启动（已设置开机自启）${RESET}"
}

docker_update() {
    root_use
    echo -e "${YELLOW}正在更新 Docker...${RESET}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl enable docker
    systemctl restart docker
    echo -e "${GREEN}Docker 更新完成并已启动（已设置开机自启）${RESET}"
}

docker_install_update() {
    root_use
    if command -v docker &>/dev/null; then
        docker_update
    else
        docker_install
    fi
}

# -----------------------------
# 卸载 Docker
# -----------------------------
docker_uninstall() {
    root_use
    echo -e "${RED}正在卸载 Docker 和 Docker Compose...${RESET}"
    systemctl stop docker 2>/dev/null
    systemctl disable docker 2>/dev/null
    pkill dockerd 2>/dev/null

    if command -v apt &>/dev/null; then
        apt remove -y docker docker-engine docker.io containerd runc docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
        apt purge -y docker docker-engine docker.io containerd runc docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
        apt autoremove -y
    elif command -v yum &>/dev/null; then
        yum remove -y docker docker-engine docker.io containerd runc docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
    fi

    rm -rf /var/lib/docker /etc/docker /var/lib/containerd /var/run/docker.sock /usr/local/bin/docker-compose
    echo -e "${GREEN}Docker 和 Docker Compose 已卸载干净${RESET}"
}

# -----------------------------
# Docker Compose 安装/更新
# -----------------------------
docker_compose_install_update() {
    root_use
    echo -e "${CYAN}正在安装/更新 Docker Compose...${RESET}"
    if ! command -v jq &>/dev/null; then
        if command -v apt &>/dev/null; then
            apt update -y && apt install -y jq
        elif command -v yum &>/dev/null; then
            yum install -y jq
        fi
    fi
    local latest=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    latest=${latest:-"v2.30.0"}
    curl -L "https://github.com/docker/compose/releases/download/$latest/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
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
    docker ps -a -q | xargs -r docker start
    echo -e "${GREEN}✅ Docker IPv6 已开启，所有容器已恢复${RESET}"
}

docker_ipv6_off() {
    root_use
    if [ -f /etc/docker/daemon.json ]; then
        jq 'del(.ipv6) | del(.["fixed-cidr-v6"])' /etc/docker/daemon.json \
            >/etc/docker/daemon.json.tmp 2>/dev/null || \
            cp /etc/docker/daemon.json /etc/docker/daemon.json.tmp
        mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
        restart_docker
        docker ps -a -q | xargs -r docker start
        echo -e "${GREEN}✅ Docker IPv6 已关闭，所有容器已恢复${RESET}"
    else
        echo -e "${YELLOW} Docker 配置文件不存在，无法关闭 IPv6${RESET}"
    fi
}

# -----------------------------
# 开放所有端口（IPv4 + IPv6 + nftables）
# -----------------------------
open_all_ports() {
    root_use
    read -p "确认要开放所有端口吗？(Y/N): " confirm
    [[ $confirm =~ [Yy] ]] || { echo -e "${YELLOW}操作已取消${RESET}"; return; }
    echo -e "${YELLOW}正在检测可用防火墙工具...${RESET}"

    if command -v iptables &>/dev/null; then
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -F
    fi
    if command -v ip6tables &>/dev/null; then
        ip6tables -P INPUT ACCEPT
        ip6tables -P FORWARD ACCEPT
        ip6tables -P OUTPUT ACCEPT
        ip6tables -F
    fi
    if command -v nft &>/dev/null; then
        nft flush ruleset 2>/dev/null || true
    fi
    echo -e "${GREEN}✅ 已开放所有端口${RESET}"
    restart_docker
}

# -----------------------------
# iptables 切换
# -----------------------------
switch_iptables_legacy() {
    root_use
    if [ -x /usr/sbin/iptables-legacy ] && [ -x /usr/sbin/ip6tables-legacy ]; then
        iptables-save > /tmp/iptables_backup_$(date +%F_%H%M%S).v4
        ip6tables-save > /tmp/ip6tables_backup_$(date +%F_%H%M%S).v6
        update-alternatives --set iptables /usr/sbin/iptables-legacy
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
        restart_docker
        iptables-restore < /tmp/iptables_backup_$(ls /tmp | grep iptables_backup_ | sort | tail -n1)
        ip6tables-restore < /tmp/ip6tables_backup_$(ls /tmp | grep ip6tables_backup_ | sort | tail -n1)
        echo -e "${GREEN}✅ 已切换到 iptables-legacy 并恢复规则${RESET}"
    else
        echo -e "${RED}系统未安装 iptables-legacy，无法切换${RESET}"
    fi
}

switch_iptables_nft() {
    root_use
    if [ -x /usr/sbin/iptables-nft ] && [ -x /usr/sbin/ip6tables-nft ]; then
        iptables-save > /tmp/iptables_backup_$(date +%F_%H%M%S).v4
        ip6tables-save > /tmp/ip6tables_backup_$(date +%F_%H%M%S).v6
        update-alternatives --set iptables /usr/sbin/iptables-nft
        update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
        restart_docker
        iptables-restore < /tmp/iptables_backup_$(ls /tmp | grep iptables_backup_ | sort | tail -n1)
        ip6tables-restore < /tmp/ip6tables_backup_$(ls /tmp | grep ip6tables_backup_ | sort | tail -n1)
        echo -e "${GREEN}✅ 已切换到 iptables-nft 并恢复规则${RESET}"
    else
        echo -e "${RED}系统未安装 iptables-nft，无法切换${RESET}"
    fi
}

# -----------------------------
# Docker 状态
# -----------------------------
docker_status() {
    if docker info &>/dev/null; then
        echo "运行中"
    else
        echo "未运行"
    fi
}

current_iptables() {
    ipt=$(update-alternatives --query iptables 2>/dev/null | grep 'Value:' | awk '{print $2}')
    if [[ $ipt == *legacy ]]; then
        echo "legacy"
    else
        echo "nft"
    fi
}

docker_container_info() {
    total=$(docker ps -a -q | wc -l)
    running=$(docker ps -q | wc -l)
    echo "总容器: $total | 运行中: $running"
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
        read -p "请选择: " choice
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
            10) read -p "请输入容器名: " name; docker exec -it $name /bin/bash ;;
            11) read -p "请输入容器名: " name; docker logs -f $name ;;
            0) break ;;
            *) echo "无效选择" ;;
        esac
        read -p "按回车继续..."
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
        read -p "请选择: " choice
        case $choice in
            01|1) read -p "请输入镜像名: " imgs; for img in $imgs; do docker pull $img; done ;;
            02|2) read -p "请输入镜像名: " imgs; for img in $imgs; do docker pull $img; done ;;
            03|3) read -p "请输入镜像名: " imgs; for img in $imgs; do docker rmi -f $img; done ;;
            04|4) read -p "确定删除所有镜像? (Y/N): " c; [[ $c =~ [Yy] ]] && docker rmi -f $(docker images -q) ;;
            0) break ;;
            *) echo "无效选择" ;;
        esac
        read -p "按回车继续..."
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
        read -p "请输入选择: " choice
        case $choice in
            1) read -p "请输入卷名: " v; docker volume create $v ;;
            2) read -p "请输入卷名: " v; docker volume rm $v ;;
            3) docker volume prune -f ;;
            0) break ;;
            *) echo "无效选择" ;;
        esac
        read -p "按回车继续..."
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
        read -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1) read -p "设置新网络名: " dockernetwork; docker network create $dockernetwork ;;
            2) read -p "加入网络名: " dockernetwork; read -p "容器名: " dockername; docker network connect $dockernetwork $dockername ;;
            3) read -p "退出网络名: " dockernetwork; read -p "容器名: " dockername; docker network disconnect $dockernetwork $dockername ;;
            4) read -p "请输入要删除的网络名: " dockernetwork; docker network rm $dockernetwork || echo -e "${RED}删除失败，网络可能被容器占用${RESET}" ;;
            0) break ;;
            *) echo "无效选择" ;;
        esac
        read -p "按回车继续..."
    done
}

# -----------------------------
# Docker 备份/恢复菜单
# -----------------------------
# -----------------------------
# Docker 备份/恢复菜单（增强版）
# -----------------------------
docker_backup_menu() {
    root_use

    BACKUP_DIR="/opt/docker_backups"
    LOG_FILE="$BACKUP_DIR/backup.log"
    mkdir -p "$BACKUP_DIR"

    # -----------------------------
    # 检查 jq
    # -----------------------------
    if ! command -v jq &>/dev/null; then
        echo -e "${YELLOW}未检测到 jq，正在安装...${RESET}"
        if command -v apt &>/dev/null; then
            apt update -y && apt install -y jq
        elif command -v yum &>/dev/null; then
            yum install -y epel-release && yum install -y jq
        elif command -v dnf &>/dev/null; then
            dnf install -y jq
        else
            echo -e "${RED}无法检测到包管理器，请手动安装 jq${RESET}"
            read -p "按回车返回菜单..."
            return
        fi
    fi

    # -----------------------------
    # 检查 Docker
    # -----------------------------
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        if command -v apt &>/dev/null; then
            apt update -y && apt install -y docker.io
        elif command -v yum &>/dev/null; then
            yum install -y docker
        elif command -v dnf &>/dev/null; then
            dnf install -y docker
        else
            echo -e "${RED}无法检测到包管理器，请手动安装 Docker${RESET}"
            read -p "按回车返回菜单..."
            return
        fi
    fi

    # -----------------------------
    # 检查 Docker 服务
    # -----------------------------
    if ! pgrep -x dockerd &>/dev/null; then
        echo -e "${YELLOW}Docker 服务未运行，正在启动...${RESET}"
        if command -v systemctl &>/dev/null; then
            systemctl start docker
            systemctl enable docker
        else
            service docker start
        fi
        sleep 2
        if ! pgrep -x dockerd &>/dev/null; then
            echo -e "${RED}Docker 启动失败，请手动检查服务${RESET}"
            read -p "按回车返回菜单..."
            return
        fi
    fi

    # -----------------------------
    # 检查磁盘空间
    # -----------------------------
    avail_space=$(df --output=avail "$BACKUP_DIR" | tail -1)
    if (( avail_space < 1048576 )); then
        echo -e "${RED}磁盘剩余空间不足 1GB，无法执行备份！${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    while true; do
        clear
        echo -e "${BOLD}${CYAN}===== Docker Run备份与恢复 =====${RESET}"
        echo -e "${GREEN}1. 备份 Docker${RESET}"
        echo -e "${GREEN}2. 恢复 Docker${RESET}"
        echo -e "${GREEN}3. 删除备份文件${RESET}"
        echo -e "${GREEN}0. 返回上一级菜单${RESET}"
        read -p "请选择: " choice
        case $choice in
            1)
                # -----------------------------
                # 备份逻辑
                # -----------------------------
                while true; do
                    echo -e "${YELLOW}选择备份类型:${RESET}"
                    echo -e "${GREEN}1. 容器${RESET}"
                    echo -e "${GREEN}2. 镜像${RESET}"
                    echo -e "${GREEN}3. 卷${RESET}"
                    echo -e "${GREEN}4. 全量${RESET}"
                    echo -e "${GREEN}0. 返回上一级${RESET}"
                    read -p "请输入选择: " btype
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
                            read -p "请确保卷 $vol 未被容器使用，按回车继续..."
                            tar -czf "$TMP_BACKUP_DIR/volume_${vol}.tar.gz" -C /var/lib/docker/volumes/"$vol"/_data .
                            echo "$(date '+%F %T') 备份卷 $vol 完成" >> "$LOG_FILE"
                        done
                    fi

                    tar -czf "$backup_path" -C "$TMP_BACKUP_DIR" .
                    rm -rf "$TMP_BACKUP_DIR"
                    echo -e "${GREEN}备份完成: $backup_path${RESET}"
                    read -p "按回车继续..."
                    break
                done
                ;;
            2)
                # -----------------------------
                # 恢复逻辑（保持原有选择逻辑）并增强安全
                # -----------------------------
                while true; do
                    echo -e "${YELLOW}选择恢复类型:${RESET}"
                    echo -e "${GREEN}1. 容器${RESET}"
                    echo -e "${GREEN}2. 镜像${RESET}"
                    echo -e "${GREEN}3. 卷${RESET}"
                    echo -e "${GREEN}4. 全量${RESET}"
                    echo -e "${GREEN}0. 返回上一级${RESET}"
                    read -p "请输入选择: " rtype
                    [[ "$rtype" == "0" ]] && break

                    read -p "请输入备份文件路径: " backup_file
                    [[ ! -f "$backup_file" ]] && echo -e "${RED}备份文件不存在${RESET}" && read -p "按回车继续..." && continue

                    TMP_RESTORE_DIR=$(mktemp -d /tmp/docker_restore_XXXX)
                    tar -xzf "$backup_file" -C "$TMP_RESTORE_DIR"

                    # --- 容器恢复 ---
                    if [[ "$rtype" == "1" || "$rtype" == "4" ]]; then
                        for cjson in "$TMP_RESTORE_DIR"/container_*.json; do
                            [[ ! -f "$cjson" ]] && continue
                            cname=$(basename "$cjson" | sed 's/container_\(.*\).json/\1/')
                            image=$(jq -r '.[0].Config.Image' "$cjson")
                            envs=$(jq -r '.[0].Config.Env | join(" -e ")' "$cjson")
                            [[ -n "$envs" ]] && envs="-e $envs"
                            ports=$(jq -r '.[0].HostConfig.PortBindings | to_entries | map("\(.value[0].HostPort):\(.key)") | join(" -p ")' "$cjson")
                            [[ -n "$ports" ]] && ports="-p $ports"
                            mounts=$(jq -r '.[0].Mounts | map("-v \(.Source):\(.Destination)") | join(" ")' "$cjson")
                            network=$(jq -r '.[0].HostConfig.NetworkMode' "$cjson")
                            echo "注意：如果端口已被占用，容器 $cname 启动可能失败"

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
                    read -p "按回车继续..."
                    break
                done
                ;;
            3)
                # -----------------------------
                # 删除备份文件（支持多选或通配符）
                # -----------------------------
                while true; do
                    echo "当前备份目录：$BACKUP_DIR"
                    ls "$BACKUP_DIR"
                    read -p "请输入要删除的备份文件名（支持空格或*通配符，输入0返回）: " del_files
                    [[ "$del_files" == "0" ]] && break
                    rm -f $BACKUP_DIR/$del_files
                    echo -e "${GREEN}删除完成${RESET}"
                    read -p "按回车继续..."
                    break
                done
                ;;
            0) break ;;
            *) echo "无效选择"; read -p "按回车继续..." ;;
        esac
    done
}


# -----------------------------
# 主菜单显示状态
# -----------------------------
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
        echo -e "${BLUE}🐳 一键 VPS Docker 管理工具${RESET}"
        # 检测 Docker 状态
        if command -v docker &>/dev/null; then
            docker_status=$(docker info &>/dev/null && echo "运行中" || echo "未运行")
            total=$(docker ps -a -q 2>/dev/null | wc -l)
            running=$(docker ps -q 2>/dev/null | wc -l)
            echo -e "${YELLOW}🐳 iptables: $(current_iptables) | Docker: $docker_status | 总容器: $total | 运行中: $running${RESET}"
        else
            # Docker 未安装时只显示 iptables 状态
            echo -e "${YELLOW}🐳 iptables: $(current_iptables)${RESET}"
        fi

        echo -e "${GREEN}01. 安装/更新 Docker（自动检测国内/国外源）${RESET}"
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
        echo -e "${GREEN}12. Docker 备份/恢复${RESET}"
        echo -e "${GREEN}13. 卷管理 ${RESET}"
        echo -e "${GREEN}14.${RESET} ${YELLOW}一键清理所有未使用容器/镜像/卷${RESET}"
        echo -e "${GREEN}15. 重启 Docker${RESET}"
        echo -e "${GREEN}00. 退出${RESET}"
        read -p "请选择: " choice
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
            13|13) check_docker_running && docker_volume ;;
            14|14) check_docker_running && docker_cleanup ;;
            15|15) check_docker_running && restart_docker ;;
            00) exit 0 ;;
            *) echo -e "${GREEN}无效选择${RESET}" ;;
        esac
        read -p "按回车继续..."
    done
}




# 启动脚本
main_menu
