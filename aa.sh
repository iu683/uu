#!/bin/bash
# ========================================
# 多项目 Docker Compose 管理脚本
# ========================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

PROJECTS_DIR="/opt"

# ---------------------------
# 确认操作
# ---------------------------
function confirm_action() {
    read -p "确认执行此操作吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        return 0
    else
        echo -e "${RED}操作已取消${RESET}"
        sleep 1
        return 1
    fi
}

# ---------------------------
# 操作完成提示
# ---------------------------
function action_done() {
    read -p "$(echo -e ${GREEN}操作完成！按回车返回菜单...${RESET})" temp
}

# ---------------------------
# 状态汉化核心引擎
# ---------------------------
function translate_status() {
    local raw_status="$1"
    echo "$raw_status" | \
        sed 's/Up /运行 /' | \
        sed 's/Exited/已停止/' | \
        sed 's/(healthy)/(健康)/' | \
        sed 's/(unhealthy)/(非健康)/' | \
        sed 's/(starting)/(启动中)/' | \
        sed 's/seconds/秒/' | \
        sed 's/second/秒/' | \
        sed 's/minutes/分钟/' | \
        sed 's/minute/分钟/' | \
        sed 's/hours/小时/' | \
        sed 's/hour/小时/' | \
        sed 's/days/天/' | \
        sed 's/day/天/' | \
        sed 's/weeks/周/' | \
        sed 's/week/周/' | \
        sed 's/months/月/' | \
        sed 's/month/月/' | \
        sed 's/about //' | \
        sed 's/ago/前/'
}

# ---------------------------
# 查看所有项目容器运行状态（主菜单功能） 
# ---------------------------
monitor_docker_containers() {
    clear
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}      🐳 Docker 项目容器状态监控        ${RESET}"
    echo -e "${GREEN}========================================${RESET}"

    projects=($(find "$PROJECTS_DIR" -maxdepth 1 -type d -exec test -f '{}/docker-compose.yml' \; -print | sort))
    
    if [ ${#projects[@]} -eq 0 ]; then
        echo -e "${RED}未找到任何含 docker-compose.yml 的项目${RESET}"
    else
        local all_stats
        all_stats=$(docker stats --no-stream --format "{{.ID}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" 2>/dev/null)

        for proj in "${projects[@]}"; do
            local project_name=$(basename "$proj")
            echo -e "${YELLOW}📁 项目群组: $project_name${RESET}"
            echo -e "${YELLOW}----------------------------------------${RESET}"
            
            local l_compose="$proj/docker-compose.yml"
            local services=$(docker compose -f "$l_compose" ps --services 2>/dev/null)
            
            if [ -z "$services" ]; then
                echo -e "  ${YELLOW}暂无服务配置${RESET}"
                echo -e "${YELLOW}----------------------------------------${RESET}"
                continue
            fi

            local stats_list=()
            for service in $services; do
                local container_id=$(docker compose -f "$l_compose" ps -q "$service" 2>/dev/null)
                local cpu="0.00%" mem="0B / 0B" net="0B / 0B" ports="无端口映射"
                local raw_status="Exited (0) 0 seconds ago"

                if [ -n "$container_id" ]; then
                    local match_stats=$(echo "$all_stats" | grep "^${container_id:0:12}")
                    if [ -n "$match_stats" ]; then
                        cpu=$(echo "$match_stats" | cut -f2)
                        mem=$(echo "$match_stats" | cut -f3)
                        net=$(echo "$match_stats" | cut -f4)
                    fi
                    raw_status=$(docker ps -a --filter "id=$container_id" --format "{{.Status}}")
                    local port_info=$(docker ps -a --filter "id=$container_id" --format "{{.Ports}}")
                    [ -n "$port_info" ] && ports=$port_info
                fi
                stats_list+=("$service	$cpu	$mem	$net	$ports	$raw_status")
            done
            
            printf "%s\n" "${stats_list[@]}" | sort -k3 -hr | while IFS=$'\t' read -r service cpu mem net ports raw_status; do
                local uptime=$(translate_status "$raw_status")
                local status_icon="${RED}❌${RESET}"
                [[ "$raw_status" == *"Up"* ]] && status_icon="${GREEN}✅${RESET}"

                echo -e "${YELLOW}◈ 服务: ${RESET}${YELLOW}${service}${RESET} ${status_icon}"
                echo -e "  ├─ ${YELLOW}运行状态: ${RESET}${uptime}"
                echo -e "  ├─ ${YELLOW}端口映射: ${RESET}${GREEN}${ports}${RESET}"
                echo -e "  ├─ ${YELLOW}CPU 占用: ${RESET}${cpu}"
                echo -e "  ├─ ${YELLOW}内存使用: ${RESET}${mem}"
                echo -e "  └─ ${YELLOW}网络 I/O: ${RESET}${net}"
                echo -e "${YELLOW}----------------------------------------${RESET}"
            done
            echo
        done
    fi
    read -p "按回车返回主菜单..." temp
}

# ---------------------------
# 选择项目
# ---------------------------
function select_project() {
    clear
    echo -e "${GREEN}=== 请选择要管理的项目 ===${RESET}"
    projects=($(find "$PROJECTS_DIR" -maxdepth 1 -type d -exec test -f '{}/docker-compose.yml' \; -print | sort))
    if [ ${#projects[@]} -eq 0 ]; then
        echo -e "${RED}未找到任何含 docker-compose.yml 的项目${RESET}"
        sleep 1
        return
    fi
    for i in "${!projects[@]}"; do
        project_name=$(basename "${projects[$i]}")
        echo -e "${GREEN}$((i+1))) $project_name${RESET}"
    done
    echo -e "${GREEN}0) 返回主菜单${RESET}"

    read -p "$(echo -e ${GREEN}请输入编号: ${RESET})" choice
    if [[ "$choice" == "0" ]]; then
        return
    elif [[ "$choice" =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#projects[@]} ]]; then
        PROJECT_DIR=${projects[$((choice-1))]}
        COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
        project_menu
    else
        echo -e "${RED}无效选择${RESET}"
        sleep 1
        select_project
    fi
}

# ---------------------------
# 进入容器
# ---------------------------
function select_container() {
    local containers=$(docker compose -f "$COMPOSE_FILE" ps --services)
    if [ -z "$containers" ]; then
        echo -e "${RED}没有正在运行的容器${RESET}"
        sleep 1
        return
    fi
    echo -e "${GREEN}可进入的容器：${RESET}"
    echo -e "${GREEN}$containers${RESET}"
    read -p "请输入容器名: " cname
    if [[ "$containers" == *"$cname"* ]]; then
        docker compose -f "$COMPOSE_FILE" exec "$cname" /bin/sh || docker compose -f "$COMPOSE_FILE" exec "$cname" /bin/bash
        action_done
    else
        echo -e "${RED}容器不存在${RESET}"
        sleep 1
    fi
}

# ---------------------------
# 删除整个项目
# ---------------------------
function delete_project() {
    echo -e "${RED}注意！这将删除整个项目，包括容器、镜像、数据卷和项目文件夹${RESET}"
    if confirm_action; then
        docker compose -f "$COMPOSE_FILE" down --rmi all -v
        rm -rf "$PROJECT_DIR"
        echo -e "${GREEN}项目已删除${RESET}"
        sleep 1
        return
    fi
}

# ---------------------------
# 多选删除项目（主菜单）
# ---------------------------
function delete_multiple_projects() {
    clear
    echo -e "${RED}=== 多选删除项目 ===${RESET}"
    projects=($(find "$PROJECTS_DIR" -maxdepth 1 -type d -exec test -f '{}/docker-compose.yml' \; -print | sort))
    if [ ${#projects[@]} -eq 0 ]; then
        echo -e "${RED}未找到任何项目${RESET}"
        sleep 1
        return
    fi

    for i in "${!projects[@]}"; do
        project_name=$(basename "${projects[$i]}")
        echo -e "${GREEN}$((i+1))) $project_name${RESET}"
    done
    echo -e "${GREEN}输入要删除的项目编号，用空格分隔（例如: 1 3 5），0 返回主菜单${RESET}"
    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choices

    if [[ "$choices" == "0" ]]; then
        return
    fi

    for c in $choices; do
        if [[ "$c" =~ ^[0-9]+$ && $c -ge 1 && $c -le ${#projects[@]} ]]; then
            local proj="${projects[$((c-1))]}"
            local l_compose="$proj/docker-compose.yml"
            local p_name=$(basename "$proj")
            echo -e "${RED}准备删除项目: $p_name${RESET}"
            if confirm_action; then
                docker compose -f "$l_compose" down --rmi all -v
                rm -rf "$proj"
                echo -e "${GREEN}已删除 $p_name${RESET}"
            fi
        else
            echo -e "${RED}无效编号: $c${RESET}"
        fi
    done
    action_done
}

# ---------------------------
# 一键删除所有未运行的项目（主菜单）
# ---------------------------
function delete_all_stopped_projects() {
    clear
    echo -e "${RED}=== 一键删除所有未运行项目 ===${RESET}"
    projects=($(find "$PROJECTS_DIR" -maxdepth 1 -type d -exec test -f '{}/docker-compose.yml' \; -print | sort))
    if [ ${#projects[@]} -eq 0 ]; then
        echo -e "${RED}未找到任何项目${RESET}"
        sleep 1
        return
    fi

    local deleted_any=false
    for proj in "${projects[@]}"; do
        local l_compose="$proj/docker-compose.yml"
        local services=$(docker compose -f "$l_compose" ps --services 2>/dev/null)
        local all_stopped=true
        
        for service in $services; do
            local cid=$(docker compose -f "$l_compose" ps -q "$service" 2>/dev/null)
            if [ -n "$cid" ]; then
                local status=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)
                if [[ "$status" == "true" ]]; then
                    all_stopped=false
                    break
                fi
            fi
        done

        if [ -n "$services" ] && $all_stopped; then
            local p_name=$(basename "$proj")
            echo -e "${RED}准备删除未运行的项目: $p_name${RESET}"
            if confirm_action; then
                docker compose -f "$l_compose" down --rmi all -v
                rm -rf "$proj"
                echo -e "${GREEN}已删除 $p_name${RESET}"
                deleted_any=true
            fi
        fi
    done

    if ! $deleted_any; then
        echo -e "${GREEN}没有未运行的项目需要删除${RESET}"
    fi
    action_done
}

# ---------------------------
# 项目管理菜单（已集成置顶状态与端口显示）
# ---------------------------
function project_menu() {
    while true; do
        clear
        local project_name=$(basename "$PROJECT_DIR")
        echo -e "${GREEN}=== 管理项目: $project_name ===${RESET}"
        
        # ----------- 新增：动态显示当前项目的容器状态与端口 -----------
        echo -e "${YELLOW}[ 当前容器实时状态 ]${RESET}"
        local services=$(docker compose -f "$COMPOSE_FILE" ps --services 2>/dev/null)
        if [ -z "$services" ]; then
            echo -e "  ${YELLOW}暂无服务配置${RESET}"
        else
            for service in $services; do
                local container_id=$(docker compose -f "$COMPOSE_FILE" ps -q "$service" 2>/dev/null)
                local ports="无端口映射"
                local raw_status="Exited (0) 0 seconds ago"
                
                if [ -n "$container_id" ]; then
                    raw_status=$(docker ps -a --filter "id=$container_id" --format "{{.Status}}")
                    local port_info=$(docker ps -a --filter "id=$container_id" --format "{{.Ports}}")
                    [ -n "$port_info" ] && ports=$port_info
                fi
                
                local uptime=$(translate_status "$raw_status")
                local status_icon="${RED}❌${RESET}"
                [[ "$raw_status" == *"Up"* ]] && status_icon="${GREEN}✅${RESET}"
                
                # 紧凑单行/双行输出，适合菜单顶部预览
                echo -e "  ${YELLOW}◈ $service${RESET} $status_icon -> $uptime"
                echo -e "    ${YELLOW}└─ 端口:${RESET} ${GREEN}$ports${RESET}"
            done
        fi
        echo -e "${YELLOW}----------------------------------------${RESET}"
        # -----------------------------------------------------------

        echo -e "${GREEN} 1) 启动服务${RESET}"
        echo -e "${GREEN} 2) 停止服务${RESET}"
        echo -e "${GREEN} 3) 重启服务${RESET}"
        echo -e "${GREEN} 4) 查看日志${RESET}"
        echo -e "${GREEN} 5) 查看容器状态${RESET}"
        echo -e "${GREEN} 6) 更新容器(pull & up)${RESET}"
        echo -e "${GREEN} 7) 进入容器${RESET}"
        echo -e "${GREEN} 8) 删除容器(含数据卷)${RESET}"
        echo -e "${GREEN} 9) 删除容器+镜像+数据卷${RESET}"
        echo -e "${GREEN}10) 删除整个项目(含文件）${RESET}"
        echo -e "${GREEN}11) 切换项目${RESET}"
        echo -e "${GREEN} 0) 返回主菜单${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
        case "$choice" in
            1) docker compose -f "$COMPOSE_FILE" up -d && action_done ;;
            2) docker compose -f "$COMPOSE_FILE" stop && action_done ;;
            3) docker compose -f "$COMPOSE_FILE" down && docker compose -f "$COMPOSE_FILE" up -d && action_done ;;
            4) docker compose -f "$COMPOSE_FILE" logs -f ; action_done ;;
            5) docker compose -f "$COMPOSE_FILE" ps ; action_done ;;
            6) docker compose -f "$COMPOSE_FILE" pull && docker compose -f "$COMPOSE_FILE" up -d && action_done ;;
            7) select_container ;;
            8) 
                if confirm_action; then
                    docker compose -f "$COMPOSE_FILE" down -v && action_done
                fi
                ;;
            9) 
                if confirm_action; then
                    docker compose -f "$COMPOSE_FILE" down --rmi all -v && action_done
                fi
                ;;
            10) delete_project; return ;;
            11) select_project; return ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" && sleep 1 ;;
        esac
    done
}

# ---------------------------
# Docker 网络管理
# ---------------------------
function network_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Docker 网络管理 ===${RESET}"
        echo -e "${GREEN}1) 查看所有网络${RESET}"
        echo -e "${GREEN}2) 创建网络${RESET}"
        echo -e "${GREEN}3) 删除网络${RESET}"
        echo -e "${GREEN}4) 将容器加入网络（支持多选）${RESET}"
        echo -e "${GREEN}5) 将容器退出网络（支持多选）${RESET}"
        echo -e "${GREEN}0) 返回主菜单${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
        case "$choice" in
            1)
                docker network ls
                read -p "按回车返回网络菜单..." temp
                ;;
            2)
                read -p "请输入网络名称: " netname
                read -p "请输入驱动 (bridge/overlay/macvlan，默认 bridge): " netdriver
                netdriver=${netdriver:-bridge}
                docker network create -d "$netdriver" "$netname" && echo -e "${GREEN}网络 $netname 创建成功${RESET}"
                read -p "按回车返回网络菜单..." temp
                ;;
            3)
                docker network ls --format "{{.Name}}" | nl
                read -p "请输入要删除的网络编号: " num
                netname=$(docker network ls --format "{{.Name}}" | sed -n "${num}p")
                if [ -n "$netname" ]; then
                    docker network rm "$netname" && echo -e "${GREEN}网络 $netname 删除成功${RESET}"
                else
                    echo -e "${RED}无效编号${RESET}"
                fi
                read -p "按回车返回网络菜单..." temp
                ;;
            4)
                echo -e "${GREEN}可用网络：${RESET}"
                docker network ls --format "{{.Name}}" | nl
                read -p "请输入要加入的网络编号: " netnum
                netname=$(docker network ls --format "{{.Name}}" | sed -n "${netnum}p")
                if [ -z "$netname" ]; then
                    echo -e "${RED}无效网络编号${RESET}"
                    read -p "按回车返回网络菜单..." temp
                    continue
                fi

                echo -e "${GREEN}正在运行的容器：${RESET}"
                docker ps --format "{{.Names}}" | nl
                read -p "请输入要加入网络的容器编号（支持多选，用空格分隔）: " cnumbers

                for cnum in $cnumbers; do
                    cname=$(docker ps --format "{{.Names}}" | sed -n "${cnum}p")
                    if [ -n "$cname" ]; then
                        docker network connect "$netname" "$cname" && echo -e "${GREEN}容器 $cname 已加入网络 $netname${RESET}"
                    else
                        echo -e "${RED}无效容器编号: $cnum${RESET}"
                    fi
                done
                read -p "按回车返回网络菜单..." temp
                ;;
            5)
                echo -e "${GREEN}可用网络：${RESET}"
                docker network ls --format "{{.Name}}" | nl
                read -p "请输入要退出的网络编号: " netnum
                netname=$(docker network ls --format "{{.Name}}" | sed -n "${netnum}p")
                if [ -z "$netname" ]; then
                    echo -e "${RED}无效网络编号${RESET}"
                    read -p "按回车返回网络菜单..." temp
                    continue
                fi

                echo -e "${GREEN}已连接到 $netname 的容器：${RESET}"
                docker network inspect "$netname" --format '{{range .Containers}}{{.Name}} {{end}}' | tr ' ' '\n' | nl
                read -p "请输入要退出网络的容器编号（支持多选，用空格分隔）: " cnumbers

                containers=($(docker network inspect "$netname" --format '{{range .Containers}}{{.Name}} {{end}}' | tr ' ' '\n'))
                for cnum in $cnumbers; do
                    cname=${containers[$((cnum-1))]}
                    if [ -n "$cname" ]; then
                        docker network disconnect "$netname" "$cname" && echo -e "${GREEN}容器 $cname 已退出网络 $netname${RESET}"
                    else
                        echo -e "${RED}无效容器编号: $cnum${RESET}"
                    fi
                done
                read -p "按回车返回网络菜单..." temp
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选择${RESET}" && sleep 1
                ;;
        esac
    done
}

# ---------------------------
# 主菜单
# ---------------------------
function main_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Docker Compose 管理 ===${RESET}"
        echo -e "${GREEN}1) 管理项目${RESET}"
        echo -e "${GREEN}2) 网络管理${RESET}"
        echo -e "${GREEN}3) 查看容器运行状态${RESET}"
        echo -e "${GREEN}4) 多选删除项目${RESET}"
        echo -e "${GREEN}5) 删除所有未运行的项目${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
        case "$choice" in
            1) select_project ;;
            2) network_menu ;;
            3) monitor_docker_containers ;;
            4) delete_multiple_projects ;;
            5) delete_all_stopped_projects ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}" && sleep 1 ;;
        esac
    done
}

# 启动
main_menu
