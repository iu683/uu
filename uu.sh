#!/bin/bash
# ========================================
# 1Panel 风格多路径 Docker Compose 管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
ORANGE='\033[38;5;208m'
RESET="\033[0m"

# ---------------------------
# 配置：需要扫描的项目根目录列表
# ---------------------------
SEARCH_DIRS=(

    "/opt/1panel/apps"
    "/data"
    "/date"
    "/app"
    "/root"
    "/opt"
)

# ---------------------------
# 动态搜索所有项目并存入数组（精准匹配直连或子目录文件）
# ---------------------------

function scan_projects() {
    PROJECT_NAMES=()
    PROJECT_PATHS=()
    
    for s_dir in "${SEARCH_DIRS[@]}"; do
        if [ -d "$s_dir" ]; then
            # 转换为绝对规范路径，消除末尾斜杠差异
            local base_search_dir=$(readlink -f "$s_dir")
            
            while IFS= read -r compose_file; do
                [ -z "$compose_file" ] && continue
                
                local full_compose_path=$(readlink -f "$compose_file")
                local app_path=$(dirname "$full_compose_path")
                local app_name=""
                
                # 精准判断：如果 compose 文件的父目录就是配置的扫描根目录
                if [ "$app_path" == "$base_search_dir" ]; then
                    app_name=$(basename "$base_search_dir")
                else
                    # 如果在深层子目录下（如 1Panel 风格）
                    app_name=$(basename "$app_path")
                fi
                
                PROJECT_NAMES+=("$app_name")
                PROJECT_PATHS+=("$app_path")
            done < <(find "$base_search_dir" -maxdepth 5 \( -name "docker-compose.yml" -o -name "docker-compose.yaml" \) 2>/dev/null | sort -u)
        fi
    done
}

# ---------------------------
# 确认操作
# ---------------------------
function confirm_action() {
    read -p "$(echo -e "${GREEN}确认执行此操作吗？(y/N): ${RESET}")" confirm
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
# 核心功能：绑定/解绑 127.0.0.1
# ---------------------------
function toggle_ip_binding() {
    local action="$1"
    local backup_file="${COMPOSE_FILE}.bak_ip"

    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${RED}错误: 找不到配置文件！${RESET}"
        sleep 1
        return
    fi

    cp "$COMPOSE_FILE" "$backup_file"

    if [ "$action" == "bind" ]; then
        echo -e "${YELLOW}正在尝试将外部端口绑定到 127.0.0.1...${RESET}"
        sed -i -E 's/- ("|'\''?)([0-9]+):([0-9]+)("|'\''?)/- \1127.0.0.1:\2:\3\4/g' "$COMPOSE_FILE"
        sed -i -E 's/- ("|'\''?)0.0.0.0:([0-9]+):([0-9]+)("|'\''?)/- \1127.0.0.1:\2:\3\4/g' "$COMPOSE_FILE"
        sed -i 's/0.0.0.0:/127.0.0.1:/g' "$COMPOSE_FILE"
    else
        echo -e "${YELLOW}正在尝试解绑 127.0.0.1 (恢复为全网公开)...${RESET}"
        sed -i -E 's/- ("|'\''?)127.0.0.1:([0-9]+):([0-9]+)("|'\''?)/- \1\2:\3\4/g' "$COMPOSE_FILE"
        sed -i 's/127.0.0.1:/0.0.0.0:/g' "$COMPOSE_FILE"
    fi

    if diff "$COMPOSE_FILE" "$backup_file" >/dev/null 2>&1; then
        echo -e "${ORANGE}提示: 端口规则没有发生变化。${RESET}"
        rm -f "$backup_file"
    else
        echo -e "${GREEN}配置已调整，正在重启容器生效...${RESET}"
        docker compose -f "$COMPOSE_FILE" down && docker compose -f "$COMPOSE_FILE" up -d
        rm -f "$backup_file"
        echo -e "${GREEN}网络边界调整成功！${RESET}"
    fi
    action_done
}

# ---------------------------
# 查看所有项目容器运行状态
# ---------------------------
monitor_docker_containers() {
    clear
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}      🐳 Docker 项目容器状态监控        ${RESET}"
    echo -e "${GREEN}========================================${RESET}"

    scan_projects
    
    if [ ${#PROJECT_NAMES[@]} -eq 0 ]; then
        echo -e "${RED}未在指定目录下找到任何 Docker Compose 项目！${RESET}"
    else
        local all_stats
        all_stats=$(docker stats --no-stream --format "{{.ID}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" 2>/dev/null)

        for i in "${!PROJECT_PATHS[@]}"; do
            local proj="${PROJECT_PATHS[$i]}"
            local project_name="${PROJECT_NAMES[$i]}"
            
            echo -e "${YELLOW}📁 项目名称: $project_name${RESET}"
            echo -e "${YELLOW}----------------------------------------${RESET}"
            
            local l_compose=""
            [ -f "$proj/docker-compose.yml" ] && l_compose="$proj/docker-compose.yml"
            [ -f "$proj/docker-compose.yaml" ] && l_compose="$proj/docker-compose.yaml"
            
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
    read -p "$(echo -e "${GREEN}按回车返回主菜单...${RESET}")" temp
}

# ---------------------------
# 选择项目
# ---------------------------
function select_project() {
    clear
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}        ◈    请选择要管理的项目    ◈     ${RESET}"
    echo -e "${GREEN}========================================${RESET}"
    
    scan_projects

    if [ ${#PROJECT_NAMES[@]} -eq 0 ]; then
        echo -e "${RED}未找到任何 Docker Compose 项目！${RESET}"
        read -p "$(echo -e "${GREEN}按回车返回主菜单...${RESET}")" temp
        return
    fi
    
    for i in "${!PROJECT_NAMES[@]}"; do
        local p_name="${PROJECT_NAMES[$i]}"
        local p_path="${PROJECT_PATHS[$i]}"
        echo -e "${YELLOW}$((i+1))) $p_name${RESET}"
    done
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}0) 返回主菜单${RESET}"
    echo -e "${GREEN}========================================${RESET}"
    read -p "$(echo -e ${GREEN}请输入编号: ${RESET})" choice
    if [[ "$choice" == "0" ]]; then
        return
    elif [[ "$choice" =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#PROJECT_NAMES[@]} ]]; then
        PROJECT_DIR=${PROJECT_PATHS[$((choice-1))]}
        if [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
            COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
        else
            COMPOSE_FILE="$PROJECT_DIR/docker-compose.yaml"
        fi
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
# 多选删除项目
# ---------------------------
function delete_multiple_projects() {
    clear
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}        ◈      多选删除项目     ◈          ${RESET}"
    echo -e "${GREEN}========================================${RESET}"
    
    scan_projects

    if [ ${#PROJECT_NAMES[@]} -eq 0 ]; then
        echo -e "${RED}未找到任何项目${RESET}"
        sleep 1
        return
    fi

    for i in "${!PROJECT_NAMES[@]}"; do
        echo -e "${GREEN}$((i+1))) ${PROJECT_NAMES[$i]}${RESET}"
    done
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}输入要删除的项目编号，用空格分隔（例如: 1 3 5），0 返回主菜单${RESET}"
    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choices

    if [[ "$choices" == "0" ]]; then
        return
    fi

    for c in $choices; do
        if [[ "$c" =~ ^[0-9]+$ && $c -ge 1 && $c -le ${#PROJECT_NAMES[@]} ]]; then
            local proj="${PROJECT_PATHS[$((c-1))]}"
            local l_compose=""
            [ -f "$proj/docker-compose.yml" ] && l_compose="$proj/docker-compose.yml"
            [ -f "$proj/docker-compose.yaml" ] && l_compose="$proj/docker-compose.yaml"
            
            local p_name="${PROJECT_NAMES[$((c-1))]}"
            echo -e "${RED}准备删除项目: $p_name ($proj)${RESET}"
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
# 一键删除所有未运行的项目
# ---------------------------
function delete_all_stopped_projects() {
    clear
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}   ◈    一键删除所有未运行项目    ◈     ${RESET}"
    echo -e "${GREEN}========================================${RESET}"
    
    scan_projects

    if [ ${#PROJECT_NAMES[@]} -eq 0 ]; then
        echo -e "${RED}未找到任何项目${RESET}"
        sleep 1
        return
    fi

    local deleted_any=false
    for i in "${!PROJECT_PATHS[@]}"; do
        local proj="${PROJECT_PATHS[$i]}"
        local p_name="${PROJECT_NAMES[$i]}"
        local l_compose=""
        [ -f "$proj/docker-compose.yml" ] && l_compose="$proj/docker-compose.yml"
        [ -f "$proj/docker-compose.yaml" ] && l_compose="$proj/docker-compose.yaml"
        
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
            echo -e "${RED}准备删除未运行的项目: $p_name ($proj)${RESET}"
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
# 项目管理菜单
# ---------------------------
function project_menu() {
    while true; do
        clear
        local project_name=$(basename "$PROJECT_DIR")
        echo -e "${GREEN}=============================================${RESET}"
        echo -e "${GREEN}        ◈  管理项目:${RESET} ${YELLOW}$project_name${RESET} ${GREEN} ◈      ${RESET}"
        echo -e "${GREEN}=============================================${RESET}"

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
                
                echo -e "  ${YELLOW}◈ $service${RESET} $status_icon ${YELLOW}-> $uptime${RESET}"
                echo -e "    ${YELLOW}└─ 端口:${RESET} ${GREEN}$ports${RESET}"
            done
        fi
        echo -e "${GREEN}---------------------------------------------${RESET}"

        echo -e "${GREEN} 1) 启动服务     |     2) 停止服务${RESET}"
        echo -e "${GREEN} 3) 重启服务     |     4) 查看日志${RESET}"
        echo -e "${GREEN} 5) 容器状态     |     6) 更新容器(pull&up)${RESET}"
        echo -e "${GREEN} 7) 进入容器     |     8) 删除容器+镜像+卷${RESET}"
        echo -e "${GREEN} 9) 删除容器     |    10) 删除整个项目${RESET}"
        echo -e "${GREEN}11) 禁止公网     |    12) 允许公网${RESET}"
        echo -e "${GREEN}=============================================${RESET}"
        echo -e "${YELLOW}13) 切换项目     |     0) 返回主菜单${RESET}"
        echo -e "${GREEN}=============================================${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
        case "$choice" in
            1) docker compose -f "$COMPOSE_FILE" up -d && action_done ;;
            2) docker compose -f "$COMPOSE_FILE" stop && action_done ;;
            3) docker compose -f "$COMPOSE_FILE" down && docker compose -f "$COMPOSE_FILE" up -d && action_done ;;
            4) docker compose -f "$COMPOSE_FILE" logs -f ; action_done ;;
            5) docker compose -f "$COMPOSE_FILE" ps ; action_done ;;
            6) docker compose -f "$COMPOSE_FILE" pull && docker compose -f "$COMPOSE_FILE" up -d && action_done ;;
            7) select_container ;;
            8) if confirm_action; then docker compose -f "$COMPOSE_FILE" down --rmi all -v && action_done; fi ;;
            9) if confirm_action; then docker compose -f "$COMPOSE_FILE" down && action_done; fi ;;
            10) delete_project; return ;;
            11) toggle_ip_binding "bind" ;;
            12) toggle_ip_binding "unbind" ;;
            13) select_project; return ;;
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
        # 实时抓取系统中的所有网络状态数据
        local total_nets=$(docker network ls -q | wc -l)
        local net_list=$(docker network ls --format "{{.Name}} ({{.Driver}})" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')

        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}    ◈    Docker 网络管理    ◈   ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${YELLOW}当前总计: $total_nets 个独立网络${RESET}"
        echo -e "${YELLOW}[网络列表] $net_list${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}1) 查看所有网络${RESET}"
        echo -e "${GREEN}2) 创建网络${RESET}"
        echo -e "${GREEN}3) 删除网络${RESET}"
        echo -e "${GREEN}4) 将容器加入网络（支持多选）${RESET}"
        echo -e "${GREEN}5) 将容器退出网络（支持多选）${RESET}"
        echo -e "${GREEN}0) 返回主菜单${RESET}"
        echo -e "${GREEN}================================${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
        case "$choice" in
            1) docker network ls; read -p "$(echo -e "${GREEN}按回车返回...${RESET}")" temp ;;
            2)
                read -p "请输入网络名称: " netname
                read -p "请输入驱动 (bridge/overlay/macvlan，默认 bridge): " netdriver
                netdriver=${netdriver:-bridge}
                docker network create -d "$netdriver" "$netname" && echo -e "${GREEN}网络 $netname 创建成功${RESET}"
                read -p "$(echo -e "${GREEN}按回车返回...${RESET}")" temp
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
                read -p "$(echo -e "${GREEN}按回车返回...${RESET}")" temp
                ;;
            4)
                echo -e "${GREEN}可用网络：${RESET}"
                docker network ls --format "{{.Name}}" | nl
                read -p "请输入要加入的网络编号: " netnum
                netname=$(docker network ls --format "{{.Name}}" | sed -n "${netnum}p")
                if [ -z "$netname" ]; then read -p "无效编号，按回车返回..." temp; continue; fi

                echo -e "${GREEN}正在运行的容器：${RESET}"
                docker ps --format "{{.Names}}" | nl
                read -p "请输入容器编号（空格分隔支持多选）: " cnumbers
                for cnum in $cnumbers; do
                    cname=$(docker ps --format "{{.Names}}" | sed -n "${cnum}p")
                    [ -n "$cname" ] && docker network connect "$netname" "$cname" && echo -e "${GREEN}容器 $cname 已加入${RESET}"
                done
                read -p "$(echo -e "${GREEN}按回车返回...${RESET}")" temp
                ;;
            5)
                echo -e "${GREEN}可用网络：${RESET}"
                docker network ls --format "{{.Name}}" | nl
                read -p "请输入网络编号: " netnum
                netname=$(docker network ls --format "{{.Name}}" | sed -n "${netnum}p")
                if [ -z "$netname" ]; then read -p "无效编号，按回车返回..." temp; continue; fi

                echo -e "${GREEN}已连接容器：${RESET}"
                docker network inspect "$netname" --format '{{range .Containers}}{{.Name}} {{end}}' | tr ' ' '\n' | nl
                read -p "请输入容器编号（空格分隔支持多选）: " cnumbers
                containers=($(docker network inspect "$netname" --format '{{range .Containers}}{{.Name}} {{end}}' | tr ' ' '\n'))
                for cnum in $cnumbers; do
                    cname=${containers[$((cnum-1))]}
                    [ -n "$cname" ] && docker network disconnect "$netname" "$cname" && echo -e "${GREEN}容器 $cname 已退出${RESET}"
                done
                read -p "$(echo -e "${GREEN}按回车返回...${RESET}")" temp
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" && sleep 1 ;;
        esac
    done
}

# ---------------------------
# 主菜单
# ---------------------------
function main_menu() {
    while true; do
        clear
        local docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "未知")
        local compose_ver=$(docker compose version --short 2>/dev/null || echo "未知")
        local running_containers=$(docker ps -q | wc -l)
        local total_images=$(docker images -q | sort -u | wc -l)

        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} ◈  Docker Compose 项目管理  ◈ ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}Docker  :${RESET} ${YELLOW}v $docker_ver${RESET}" 
        echo -e "${GREEN}Compose :${RESET} ${YELLOW}v $compose_ver ${RESET}"
        echo -e "${GREEN}运行容器:${RESET} ${YELLOW}$running_containers 个${RESET}"
        echo -e "${GREEN}系统镜像:${RESET} ${YELLOW}$total_images 个${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}1) 管理项目${RESET}"
        echo -e "${GREEN}2) 网络管理${RESET}"
        echo -e "${GREEN}3) 查看容器运行状态${RESET}"
        echo -e "${GREEN}4) 多选删除项目${RESET}"
        echo -e "${GREEN}5) 删除未运行的项目${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"
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
