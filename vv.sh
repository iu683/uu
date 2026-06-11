#!/bin/bash
# ==============================================
# Docker 服务管理菜单 (自动搜索+状态显示版)
# 支持: 启动 | 停止 | 重启 | 查看日志 | 查看状态 | 更新容器
# ==============================================

# 定义 1Panel 应用的根目录
SEARCH_DIR="/opt/1panel/apps"

# 颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
ORANGE='\033[38;5;208m'
PLAIN="\033[0m"

# 获取容器运行状态的函数
get_project_status() {
    local compose_file="$1/docker-compose.yml"
    
    # 检查新版 docker compose 或旧版 docker-compose
    local compose_cmd="docker compose"
    if ! command -v docker compose &> /dev/null; then
        compose_cmd="docker-compose"
    fi

    # 获取容器状态数量
    # running: 运行中, exited: 已停止, paused: 已暂停
    local running_count=$($compose_cmd -f "$compose_file" ps --format json 2>/dev/null | grep -c '"Status":"running"')
    
    # 如果 json 格式不支持（老版本 docker-compose），尝试用传统文本解析
    if [ "$running_count" -eq 0 ]; then
        running_count=$($compose_cmd -f "$compose_file" ps 2>/dev/null | tail -n +3 | grep -E "Up|running" | wc -l)
    fi

    local total_count=$($compose_cmd -f "$compose_file" ps -q 2>/dev/null | wc -l)

    if [ "$total_count" -eq 0 ]; then
        echo -e "${RED}[已停止 / 未创建]${PLAIN}"
    elif [ "$running_count" -eq "$total_count" ]; then
        echo -e "${GREEN}[运行中 ($running_count/$total_count)]${PLAIN}"
    elif [ "$running_count" -gt 0 ]; then
        echo -e "${YELLOW}[部分运行 ($running_count/$total_count)]${PLAIN}"
    else
        echo -e "${RED}[已停止 ($running_count/$total_count)]${PLAIN}"
    fi
}

# 动态搜索项目并存入数组
scan_projects() {
    echo -e "${YELLOW}正在扫描 1Panel 容器项目...${PLAIN}"
    
    PROJECT_NAMES=()
    PROJECT_PATHS=()
    
    while IFS= read -r compose_file; do
        local app_path=$(dirname "$compose_file")
        local app_name=$(basename "$app_path")
        
        PROJECT_NAMES+=("$app_name")
        PROJECT_PATHS+=("$app_path")
    done < <(find "$SEARCH_DIR" -maxdepth 5 -name "docker-compose.yml" 2>/dev/null)

    if [ ${#PROJECT_NAMES[@]} -eq 0 ]; then
        echo -e "${RED}未在 $SEARCH_DIR 下找到任何包含 docker-compose.yml 的项目！${PLAIN}"
        exit 1
    fi
}

# 显示主菜单
show_menu() {
    scan_projects
    clear
    echo -e "${GREEN}=====================================${PLAIN}"
    echo -e "${GREEN}    ◈   1panelapps 项目管理   ◈     ${PLAIN}"
    echo -e "${GREEN}=====================================${PLAIN}"
    
    # 遍历数组并异步/同步获取状态显示
    for i in "${!PROJECT_NAMES[@]}"; do
        local status=$(get_project_status "${PROJECT_PATHS[$i]}")
        # 使用 printf 让排版更整齐
        printf "${YELLOW}%2d)${PLAIN} %-20s %b\n" "$((i+1))" "${PROJECT_NAMES[$i]}" "$status"
    done
    echo -e "${GREEN}=====================================${PLAIN}"
    echo -e "${GREEN}0) 退出${PLAIN}"
    echo -e "${GREEN}=====================================${PLAIN}"
    read -p $'\033[32m请选择项目编号: \033[0m' proj_choice

    if [[ "$proj_choice" == "0" ]]; then
        exit 0
    fi

    if [[ "$proj_choice" =~ ^[0-9]+$ ]] && [ "$proj_choice" -le "${#PROJECT_NAMES[@]}" ] && [ "$proj_choice" -gt 0 ]; then
        local index=$((proj_choice - 1))
        selected_project="${PROJECT_NAMES[$index]}"
        selected_path="${PROJECT_PATHS[$index]}"
        show_actions
    else
        echo -e "${RED}无效选择！${PLAIN}"
        sleep 1
        show_menu
    fi
}

# 显示操作菜单
show_actions() {
    clear
    # 实时获取当前选定项目的状态
    local current_status=$(get_project_status "$selected_path")

    echo -e "${GREEN}=====================================${PLAIN}"
    echo -e "${GREEN}  ◈   管理 [$selected_project]   ◈   ${PLAIN}"
    echo -e "${GREEN}=====================================${PLAIN}"
    echo -e "${ORANGE}路径: $selected_path${PLAIN}"
    echo -e "${ORANGE}状态: $current_status${PLAIN}"
    echo -e "${GREEN}=====================================${PLAIN}"
    echo -e "${YELLOW}1) 启动服务${PLAIN}"
    echo -e "${YELLOW}2) 停止服务${PLAIN}"
    echo -e "${YELLOW}3) 重启服务${PLAIN}"
    echo -e "${YELLOW}4) 查看日志${PLAIN}"
    echo -e "${YELLOW}5) 更新容器${PLAIN}"
    echo -e "${YELLOW}0) 返回菜单${PLAIN}"
    echo -e "${GREEN}=====================================${PLAIN}"
    read -p $'\033[32m请选择操作: \033[0m' action_choice

    # 兼容新旧版命令
    local compose_cmd="docker-compose"
    if command -v docker compose &> /dev/null; then
        compose_cmd="docker compose"
    fi

    case "$action_choice" in
        1) $compose_cmd -f "$selected_path/docker-compose.yml" up -d ;;
        2) $compose_cmd -f "$selected_path/docker-compose.yml" down ;;
        3) $compose_cmd -f "$selected_path/docker-compose.yml" down && $compose_cmd -f "$selected_path/docker-compose.yml" up -d ;;
        4) $compose_cmd -f "$selected_path/docker-compose.yml" logs -f --tail=100 ;;
        5) 
           $compose_cmd -f "$selected_path/docker-compose.yml" pull
           $compose_cmd -f "$selected_path/docker-compose.yml" up -d
           ;;
        0) show_menu ;;
        *) echo -e "${RED}无效选择${PLAIN}"; sleep 1; show_actions ;;
    esac

    read -p $'\033[32m按回车返回操作菜单...\033[0m'
    show_actions
}

# 运行主循环
while true; do
    show_menu
done
