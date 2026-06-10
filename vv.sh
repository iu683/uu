#!/bin/bash
# ==============================================
# Docker 服务管理菜单 (自动搜索版)
# 支持: 启动 | 停止 | 重启 | 查看日志 | 查看状态 | 更新容器
# ==============================================

# 定义 1Panel 应用的根目录（脚本会自动在这个目录下搜索）
SEARCH_DIR="/opt/1panel/apps"

# 颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
ORANGE='\033[38;5;208m'
PLAIN="\033[0m"

# 动态搜索项目并存入数组
scan_projects() {
    echo -e "${YELLOW}正在扫描 1Panel 容器项目...${PLAIN}"
    
    # 清空或初始化项目数组
    PROJECT_NAMES=()
    PROJECT_PATHS=()
    
    # 查找所有包含 docker-compose.yml 的目录
    # -maxdepth 5 控制搜索深度，避免扫描到无用子目录
    while IFS= read -r compose_file; do
        local app_path=$(dirname "$compose_file")
        local app_name=$(basename "$app_path")
        
        # 将项目名和路径分别存入索引数组（保证顺序一致）
        PROJECT_NAMES+=("$app_name")
        PROJECT_PATHS+=("$app_path")
    done < <(find "$SEARCH_DIR" -maxdepth 5 -name "docker-compose.yml" 2>/dev/null)

    # 检查是否找到了项目
    if [ ${#PROJECT_NAMES[@]} -eq 0 ]; then
        echo -e "${RED}未在 $SEARCH_DIR 下找到任何包含 docker-compose.yml 的项目！${PLAIN}"
        exit 1
    fi
}

# 显示主菜单
show_menu() {
    # 每次返回主菜单时重新扫描，确保能实时捕获新增的应用
    scan_projects

    echo -e "\n${GREEN}==== 1panelapps 项目管理 (自动搜索) ====${PLAIN}"
    
    # 遍历数组显示菜单
    for i in "${!PROJECT_NAMES[@]}"; do
        echo -e "${GREEN}$((i+1))) ${PROJECT_NAMES[$i]}${PLAIN}"
    done
    echo -e "${GREEN}0) 退出${PLAIN}"
    
    read -p $'\033[32m请选择项目编号: \033[0m' proj_choice

    if [[ "$proj_choice" == "0" ]]; then
        exit 0
    fi

    # 验证输入是否为有效的数字，且在范围内
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
    echo -e "${ORANGE}=== 管理 [$selected_project] ===${PLAIN}"
    echo -e "路径: $selected_path\n"
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
        4) docker-compose -f "$selected_path/docker-compose.yml" logs -f --tail=100 ;; # 增加 tail 限制，防止日志刷屏
        5) 
           docker-compose -f "$selected_path/docker-compose.yml" pull
           docker-compose -f "$selected_path/docker-compose.yml" up -d
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
