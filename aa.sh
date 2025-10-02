#!/bin/bash
# ========================================
# 多项目 Docker Compose 管理脚本
# ========================================

GREEN="\033[32m"
RED="\033[31m"
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
    read -p "操作完成！按回车返回菜单..." temp
}

# ---------------------------
# 查看所有项目容器运行状态（带 ✅） 
# ---------------------------
function show_all_projects_status() {
    clear
    echo -e "${GREEN}=== 所有项目容器运行状态 ===${RESET}"
    projects=($(find "$PROJECTS_DIR" -maxdepth 1 -type d -exec test -f '{}/docker-compose.yml' \; -print | sort))
    if [ ${#projects[@]} -eq 0 ]; then
        echo -e "${RED}未找到任何含 docker-compose.yml 的项目${RESET}"
    else
        for proj in "${projects[@]}"; do
            project_name=$(basename "$proj")
            echo -e "${GREEN}项目: $project_name${RESET}"
            COMPOSE_FILE="$proj/docker-compose.yml"
            services=$(docker compose -f "$COMPOSE_FILE" ps --services)
            for service in $services; do
                status=$(docker compose -f "$COMPOSE_FILE" ps -q "$service" | xargs docker inspect -f '{{.State.Running}}')
                if [[ "$status" == "true" ]]; then
                    echo -e "${GREEN}  ✅ $service 运行中${RESET}"
                else
                    echo -e "${RED}  ❌ $service 未运行${RESET}"
                fi
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
        main_menu
    fi
    for i in "${!projects[@]}"; do
        project_name=$(basename "${projects[$i]}")
        echo -e "${GREEN}$((i+1))) $project_name${RESET}"
    done
    echo -e "${GREEN}0) 返回主菜单${RESET}"

    read -p "请输入编号: " choice
    if [[ "$choice" == "0" ]]; then
        main_menu
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
    containers=$(docker compose -f "$COMPOSE_FILE" ps --services)
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
        main_menu
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
    read -p "请选择: " choices

    if [[ "$choices" == "0" ]]; then
        return
    fi

    for c in $choices; do
        if [[ "$c" =~ ^[0-9]+$ && $c -ge 1 && $c -le ${#projects[@]} ]]; then
            proj="${projects[$((c-1))]}"
            COMPOSE_FILE="$proj/docker-compose.yml"
            project_name=$(basename "$proj")
            echo -e "${RED}准备删除项目: $project_name${RESET}"
            if confirm_action; then
                docker compose -f "$COMPOSE_FILE" down --rmi all -v
                rm -rf "$proj"
                echo -e "${GREEN}已删除 $project_name${RESET}"
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

    deleted_any=false

    for proj in "${projects[@]}"; do
        COMPOSE_FILE="$proj/docker-compose.yml"
        services=$(docker compose -f "$COMPOSE_FILE" ps --services)
        all_stopped=true
        for service in $services; do
            status=$(docker compose -f "$COMPOSE_FILE" ps -q "$service" | xargs docker inspect -f '{{.State.Running}}')
            if [[ "$status" == "true" ]]; then
                all_stopped=false
                break
            fi
        done

        if $all_stopped; then
            project_name=$(basename "$proj")
            echo -e "${RED}准备删除未运行的项目: $project_name${RESET}"
            if confirm_action; then
                docker compose -f "$COMPOSE_FILE" down --rmi all -v
                rm -rf "$proj"
                echo -e "${GREEN}已删除 $project_name${RESET}"
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
        project_name=$(basename "$PROJECT_DIR")
        echo -e "${GREEN}=== 管理项目: $project_name ===${RESET}"
        echo -e "${GREEN} 1) 启动服务${RESET}"
        echo -e "${GREEN} 2) 停止服务${RESET}"
        echo -e "${GREEN} 3) 重启服务${RESET}"
        echo -e "${GREEN} 4) 查看日志${RESET}"
        echo -e "${GREEN} 5) 查看容器状态${RESET}"
        echo -e "${GREEN} 6) 更新容器 (拉取新镜像并重启)${RESET}"
        echo -e "${GREEN} 7) 进入容器${RESET}"
        echo -e "${GREEN} 8) 删除容器 (含数据卷)${RESET}"
        echo -e "${GREEN} 9) 删除容器+镜像+数据卷${RESET}"
        echo -e "${GREEN}10) 删除整个项目（含文件）${RESET}"
        echo -e "${GREEN}11) 切换项目${RESET}"
        echo -e "${GREEN} 0) 返回主菜单${RESET}"
        read -p "请选择操作: " choice
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
            10) delete_project ;;
            11) select_project ;;
            0) main_menu ;;
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
        echo -e "${GREEN}=== Docker Compose 管理器 ===${RESET}"
        echo -e "${GREEN}1) 管理项目${RESET}"
        echo -e "${GREEN}2) 一键查看所有项目容器运行状态${RESET}"
        echo -e "${GREEN}3) 多选删除项目（含容器、镜像、数据卷、文件）${RESET}"
        echo -e "${GREEN}4) 一键删除所有未运行的项目${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "请选择操作: " choice
        case "$choice" in
            1) select_project ;;
            2) show_all_projects_status ;;
            3) delete_multiple_projects ;;
            4) delete_all_stopped_projects ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}" && sleep 1 ;;
        esac
    done
}

# ---------------------------
# 启动
# ---------------------------
main_menu
