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
# 选择项目
# ---------------------------
function select_project() {
    clear
    echo -e "${GREEN}=== 请选择要管理的项目 ===${RESET}"
    projects=($(find "$PROJECTS_DIR" -maxdepth 1 -type d -exec test -f '{}/docker-compose.yml' \; -print | sort))

    if [ ${#projects[@]} -eq 0 ]; then
        echo -e "${RED}未在 $PROJECTS_DIR 下找到任何含 docker-compose.yml 的项目${RESET}"
        exit 1
    fi

    for i in "${!projects[@]}"; do
        echo -e "${GREEN}$((i+1))) ${projects[$i]}${RESET}"
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
# 项目管理菜单
# ---------------------------
function project_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== 管理项目: $PROJECT_DIR ===${RESET}"
        echo -e "${GREEN}1) 启动服务${RESET}"
        echo -e "${GREEN}2) 停止服务${RESET}"
        echo -e "${GREEN}3) 重启服务${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看容器状态${RESET}"
        echo -e "${GREEN}6) 更新容器 (拉取新镜像并重启)${RESET}"
        echo -e "${GREEN}7) 进入容器${RESET}"
        echo -e "${GREEN}8) 删除容器 (含数据卷)${RESET}"
        echo -e "${GREEN}9) 删除容器+镜像+数据卷${RESET}"
        echo -e "${GREEN}10) 切换项目${RESET}"
        echo -e "${GREEN}0) 返回主菜单${RESET}"
        echo
        read -p "请选择操作 [0-10]: " choice
        case "$choice" in
            1) docker compose -f "$COMPOSE_FILE" up -d ;;
            2) docker compose -f "$COMPOSE_FILE" stop ;;
            3) docker compose -f "$COMPOSE_FILE" down && docker compose -f "$COMPOSE_FILE" up -d ;;
            4) docker compose -f "$COMPOSE_FILE" logs -f ;;
            5) docker compose -f "$COMPOSE_FILE" ps ;;
            6) docker compose -f "$COMPOSE_FILE" pull && docker compose -f "$COMPOSE_FILE" up -d ;;
            7) select_container ;;
            8) 
                if confirm_action; then
                    docker compose -f "$COMPOSE_FILE" down -v
                fi
                ;;
            9) 
                if confirm_action; then
                    docker compose -f "$COMPOSE_FILE" down --rmi all -v
                fi
                ;;
            10) select_project ;;
            0) main_menu ;;
            *) echo -e "${RED}无效选择${RESET}" && sleep 1 ;;
        esac
    done
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
    else
        echo -e "${RED}容器不存在${RESET}"
        sleep 1
    fi
}

# ---------------------------
# 主菜单
# ---------------------------
function main_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Docker Compose 管理器 ===${RESET}"
        echo -e "${GREEN}1) 管理项目${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        echo
        read -p "请选择操作 [0-1]: " choice
        case "$choice" in
            1) select_project ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}" && sleep 1 ;;
        esac
    done
}

# ---------------------------
# 启动
# ---------------------------
main_menu
