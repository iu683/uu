#!/bin/bash
# ==============================================
# Docker 服务管理菜单
# 支持: 启动 | 停止 | 重启 | 查看日志 | 查看状态 | 更新容器
# ==============================================

# 定义项目列表
declare -A PROJECTS=(
    ["Moviepilot"]="/opt/1panel/apps/local/moviepilot/moviepilot"
    ["Jellyfin"]="/opt/1panel/apps/jellyfin/jellyfin"
    ["emby-amilys"]="/opt/1panel/apps/local/emby-amilys/emby-amilys"
    ["Vertex"]="/opt/1panel/apps/local/vertex/localvertex"
    ["Autobangumi"]="/opt/1panel/apps/local/autobangumi/autobangumi"
)

# 颜色
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
ORANGE='\033[38;5;208m'
PLAIN="\033[0m"

# 显示菜单
show_menu() {
    echo -e "${GREEN}==== 1panel/apps 项目管理 ====${PLAIN}"
    local i=1
    for key in "${!PROJECTS[@]}"; do
        echo -e "${GREEN}$i) $key${PLAIN}"
        ((i++))
    done
    echo -e "${GREEN}0) 退出${PLAIN}"
    read -p $'\033[32m请选择项目编号: \033[0m' proj_choice

    if [[ "$proj_choice" == "0" ]]; then
        exit 0
    fi

    # 获取选择的项目名称
    local index=1
    for key in "${!PROJECTS[@]}"; do
        if [[ "$index" == "$proj_choice" ]]; then
            selected_project="$key"
            selected_path="${PROJECTS[$key]}"
            break
        fi
        ((index++))
    done

    if [[ -z "$selected_project" ]]; then
        echo -e "${RED}无效选择！${PLAIN}"
        show_menu
    else
        show_actions
    fi
}

# 显示操作菜单
show_actions() {
    echo -e "${ORANGE}=== 管理 [$selected_project] ===${PLAIN}"
    echo -e "${YELLOW}1) 启动服务${PLAIN}"
    echo -e "${YELLOW}2) 停止服务${PLAIN}"
    echo -e "${YELLOW}3) 重启服务${PLAIN}"
    echo -e "${YELLOW}4) 查看日志${PLAIN}"
    echo -e "${YELLOW}5) 更新容器${PLAIN}"
    echo -e "${YELLOW}0) 返回菜单${PLAIN}"
    read -p $'\033[32m请选择操作: \033[0m' action_choice

    case "$action_choice" in
        1) docker-compose -f "$selected_path/docker-compose.yml" up -d ;;
        2) docker-compose -f "$selected_path/docker-compose.yml" down ;;
        3) docker-compose -f "$selected_path/docker-compose.yml" down && docker-compose -f "$selected_path/docker-compose.yml" up -d ;;
        4) docker-compose -f "$selected_path/docker-compose.yml" logs -f ;;
        5) 
           docker-compose -f "$selected_path/docker-compose.yml" pull
           docker-compose -f "$selected_path/docker-compose.yml" up -d
           ;;
        0) show_menu ;;
        *) echo -e "${RED}无效选择${PLAIN}" ;;
    esac

    read -p $'\033[32m按回车返回操作菜单...\033[0m'
    show_actions
}

# 启动
while true; do
    show_menu
done
